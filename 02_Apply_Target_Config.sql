/*==============================================================================
  02_Apply_Target_Config.sql
  ----------------------------------------------------------------------------
  PURPOSE   Run on each NEW SQL Server 2022 target AFTER install + migration
            validation, BEFORE go-live. Applies the instance-level configuration
            and enables Query Store on migrated user databases.

  DESIGN    - Defaults to DRY-RUN: prints every change it *would* make and
              executes nothing. Set @DryRun = 0 to apply.
            - DERIVES MAXDOP and max memory from THIS box, not the source.
            - ENFORCES the security baseline (xp_cmdshell / ad hoc distributed
              queries / CLR) to safe values rather than mirroring the source.
            - Idempotent: only touches a setting when it differs; re-runnable.
            - Leaves a change log grid at the end.

  DOES NOT  - Disable 'sa', drop/disable logins, or do capstone hardening. That
              is the separate hardening script (and 'sa' must not be disabled
              until a confirmed enabled sysadmin exists). This stays in the
              config lane only.

  RESTART   None of these settings require a service restart. (Lock Pages in
            Memory is NOT an sp_configure option — it is a Windows user right,
            handled as guidance below, not executed here.)
  ============================================================================*/

SET NOCOUNT ON;

/*------------------------------------------------------------------------------
  PARAMETERS  —  edit these, then run
------------------------------------------------------------------------------*/
DECLARE
    @DryRun              bit   = 1,      -- 1 = print only (safe). 0 = apply.
    @TargetMaxMemoryMB   int   = 0,      -- 0 = auto-derive (reserve max(4GB,10%) for OS)
    @TargetMaxDop        int   = 0,      -- 0 = auto-derive (cores per NUMA node, cap 8)
    @TargetCTFP          int   = 50,     -- cost threshold for parallelism
    @AllowClr            bit   = 0,      -- forced to 1 automatically if SSISDB is present
    @EnableQueryStore    bit   = 1,      -- enable QS on migrated user DBs
    @QS_MaxStorageMB     int   = 2048,
    @MemoryFloorMB       int   = 2048;   -- guard: never set max memory below this

PRINT '======================================================================';
PRINT ' TARGET CONFIG APPLY   mode = ' + CASE WHEN @DryRun = 1 THEN 'DRY-RUN (no changes)' ELSE '*** APPLYING ***' END;
PRINT ' ' + CONVERT(varchar(30), SYSDATETIME(), 120) + '   on ' + CONVERT(sysname, SERVERPROPERTY('ServerName'));
PRINT '======================================================================';

/*------------------------------------------------------------------------------
  DERIVE hardware-dependent values with guards
------------------------------------------------------------------------------*/
DECLARE @phys_mb int, @sched_per_node int, @reserve_mb int;

SELECT @phys_mb = physical_memory_kb / 1024 FROM sys.dm_os_sys_info;

SELECT TOP 1 @sched_per_node = online_scheduler_count
FROM sys.dm_os_nodes
WHERE node_state_desc = 'ONLINE' AND node_id < 64
ORDER BY online_scheduler_count DESC;

-- MAXDOP: cores per NUMA node capped at 8, unless caller overrode it
IF @TargetMaxDop = 0
    SET @TargetMaxDop = CASE WHEN @sched_per_node > 8 THEN 8 ELSE @sched_per_node END;

-- Max memory: reserve the greater of 4GB or 10% for the OS, with a hard floor
IF @TargetMaxMemoryMB = 0
BEGIN
    SET @reserve_mb = CASE WHEN @phys_mb / 10 > 4096 THEN @phys_mb / 10 ELSE 4096 END;
    SET @TargetMaxMemoryMB = @phys_mb - @reserve_mb;
END
IF @TargetMaxMemoryMB < @MemoryFloorMB
BEGIN
    PRINT '!! Memory guard tripped: derived max (' + CONVERT(varchar(12), @TargetMaxMemoryMB)
        + ' MB) is below the floor (' + CONVERT(varchar(12), @MemoryFloorMB) + ' MB).';
    PRINT '!! Clamping to floor. Check that this VM has enough RAM for SQL Server.';
    SET @TargetMaxMemoryMB = @MemoryFloorMB;
END

-- CLR: if the SSIS catalog is present it legitimately needs CLR on
IF DB_ID('SSISDB') IS NOT NULL AND @AllowClr = 0
BEGIN
    PRINT '** SSISDB detected — forcing clr enabled = 1 (the SSIS catalog requires it).';
    SET @AllowClr = 1;
END

PRINT '';
PRINT 'Derived: MAXDOP=' + CONVERT(varchar(6), @TargetMaxDop)
    + '  CTFP=' + CONVERT(varchar(6), @TargetCTFP)
    + '  MaxMem=' + CONVERT(varchar(12), @TargetMaxMemoryMB) + ' MB'
    + '  (physical ' + CONVERT(varchar(12), @phys_mb) + ' MB)';
PRINT '';

/*------------------------------------------------------------------------------
  BUILD the desired-state plan
    role: 'perf' = tuning, 'security' = enforced-safe, 'ops' = operability
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#plan') IS NOT NULL DROP TABLE #plan;
CREATE TABLE #plan (
    seq          int IDENTITY(1,1),
    name         nvarchar(70),
    desired      int,
    role         varchar(10),
    note         nvarchar(200)
);

INSERT INTO #plan (name, desired, role, note) VALUES
 ('cost threshold for parallelism', @TargetCTFP,        'perf',     'Lift off the default 5 so only genuinely expensive queries go parallel.'),
 ('max degree of parallelism',      @TargetMaxDop,      'perf',     'Cores per NUMA node, capped at 8 — derived from this VM.'),
 ('max server memory (MB)',         @TargetMaxMemoryMB, 'perf',     'Leave the OS the greater of 4GB or 10%.'),
 ('min server memory (MB)',         0,                  'perf',     'Leave at 0 unless SQL is the sole service on the VM.'),
 ('optimize for ad hoc workloads',  1,                  'perf',     'Plan stub on first execution — trims single-use plan cache bloat.'),
 ('backup compression default',     1,                  'ops',      'Smaller, faster backups. No downside on standard hardware.'),
 ('remote admin connections',       1,                  'ops',      'Enable the DAC listener for emergency access.'),
 ('remote login timeout (s)',       30,                 'ops',      'Tolerate WAN / linked-server latency.'),
 ('xp_cmdshell',                    0,                  'security', 'ENFORCED OFF regardless of source. Use SQL Agent CmdExec instead.'),
 ('ad hoc distributed queries',     0,                  'security', 'ENFORCED OFF unless OPENROWSET is a governed requirement.'),
 ('clr strict security',            1,                  'security', 'Enforce assembly code-signing (SQL 2017+ default).'),
 ('clr enabled',      CONVERT(int,@AllowClr),           'security', 'OFF unless CLR is genuinely deployed (auto-on if SSISDB present).');

/*------------------------------------------------------------------------------
  APPLY loop  —  compare, then print (dry-run) or execute
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#log') IS NOT NULL DROP TABLE #log;
CREATE TABLE #log (name nvarchar(70), role varchar(10), old_value sql_variant, new_value int, action varchar(20), note nvarchar(200));

-- advanced options must be on to set most of the above
IF @DryRun = 0
BEGIN
    EXEC sys.sp_configure 'show advanced options', 1; RECONFIGURE;
END

DECLARE @i int = 1, @max int, @nm nvarchar(70), @want int, @role varchar(10), @note nvarchar(200), @cur int;
SELECT @max = MAX(seq) FROM #plan;

WHILE @i <= @max
BEGIN
    SELECT @nm = name, @want = desired, @role = role, @note = note FROM #plan WHERE seq = @i;
    SELECT @cur = CONVERT(int, value_in_use) FROM sys.configurations WHERE name = @nm;

    IF @cur IS NULL
        INSERT INTO #log VALUES (@nm, @role, NULL, @want, 'NOT FOUND', @note);
    ELSE IF @cur = @want
        INSERT INTO #log VALUES (@nm, @role, @cur, @want, 'already ok', @note);
    ELSE
    BEGIN
        IF @DryRun = 1
            INSERT INTO #log VALUES (@nm, @role, @cur, @want, 'WOULD CHANGE', @note);
        ELSE
        BEGIN
            BEGIN TRY
                EXEC sys.sp_configure @nm, @want;
                RECONFIGURE;
                INSERT INTO #log VALUES (@nm, @role, @cur, @want, 'CHANGED', @note);
            END TRY
            BEGIN CATCH
                INSERT INTO #log VALUES (@nm, @role, @cur, @want, 'ERROR: ' + LEFT(ERROR_MESSAGE(),8), @note);
            END CATCH
        END
    END
    SET @i += 1;
END

/*------------------------------------------------------------------------------
  LOCK PAGES IN MEMORY  —  guidance only (not an sp_configure setting)
------------------------------------------------------------------------------*/
DECLARE @lpim_kb bigint;
SELECT @lpim_kb = SUM(locked_page_allocations_kb) FROM sys.dm_os_process_memory;
PRINT '';
IF ISNULL(@lpim_kb,0) > 0
    PRINT 'Lock Pages in Memory: ACTIVE (' + CONVERT(varchar(20), @lpim_kb/1024) + ' MB locked). Nothing to do.';
ELSE
    PRINT 'Lock Pages in Memory: NOT active. Grant the SQL service account the Windows '
        + '"Lock pages in memory" user right, then restart the service. (Standard edition also needs TF 845.)';

/*------------------------------------------------------------------------------
  QUERY STORE  —  enable with best-practice baseline on writable user DBs
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#qslog') IS NOT NULL DROP TABLE #qslog;
CREATE TABLE #qslog (database_name sysname, action varchar(30));

IF @EnableQueryStore = 1
BEGIN
    DECLARE @db sysname, @qs nvarchar(max);
    DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE database_id > 4 AND state = 0 AND is_read_only = 0
          AND DATABASEPROPERTYEX(name, 'Updateability') = 'READ_WRITE';   -- skip AG secondaries
    OPEN db_cur;
    FETCH NEXT FROM db_cur INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @qs = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET QUERY_STORE = ON
            (OPERATION_MODE = READ_WRITE,
             MAX_STORAGE_SIZE_MB = ' + CONVERT(nvarchar(12), @QS_MaxStorageMB) + N',
             DATA_FLUSH_INTERVAL_SECONDS = 900,
             INTERVAL_LENGTH_MINUTES = 60,
             CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
             SIZE_BASED_CLEANUP_MODE = AUTO,
             QUERY_CAPTURE_MODE = AUTO,
             MAX_PLANS_PER_QUERY = 200,
             WAIT_STATS_CAPTURE_MODE = ON);';

        IF @DryRun = 1
            INSERT INTO #qslog VALUES (@db, 'WOULD ENABLE QS');
        ELSE
        BEGIN
            BEGIN TRY
                EXEC sys.sp_executesql @qs;
                INSERT INTO #qslog VALUES (@db, 'QS ENABLED');
            END TRY
            BEGIN CATCH
                INSERT INTO #qslog VALUES (@db, 'ERROR: ' + LEFT(ERROR_MESSAGE(),12));
            END CATCH
        END
        FETCH NEXT FROM db_cur INTO @db;
    END
    CLOSE db_cur; DEALLOCATE db_cur;
END

/*------------------------------------------------------------------------------
  RESULTS
------------------------------------------------------------------------------*/
SELECT name, role, old_value, new_value, action, note
FROM #log
ORDER BY CASE role WHEN 'security' THEN 0 WHEN 'perf' THEN 1 ELSE 2 END, name;

SELECT database_name, action FROM #qslog ORDER BY database_name;

PRINT '';
IF @DryRun = 1
    PRINT 'DRY-RUN complete. Review the grids above, then set @DryRun = 0 to apply.';
ELSE
    PRINT 'APPLY complete. Re-run in dry-run to confirm everything now reads "already ok".';
