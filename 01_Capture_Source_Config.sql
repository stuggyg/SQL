/*==============================================================================
  01_Capture_Source_Config.sql
  ----------------------------------------------------------------------------
  PURPOSE   Run on each SOURCE SQL Server 2016 instance. Captures the settings
            you need to reproduce (or deliberately improve) on the new
            SQL Server 2022 target: collation, sp_configure, trace flags,
            MAXDOP / cost threshold, and Query Store state.

  OUTPUT    Multiple result sets + a printed "APPLY ON TARGET" block in the
            Messages tab. In an air-gapped estate: run this, save the grid
            results (right-click > Save Results As) and copy the Messages
            output, carry both across on approved media.

  PRINCIPLE This script does NOT tell you to mirror the source. It shows the
            source value beside the 2022 best-practice value so you copy what
            should be copied (collation, memory shape, workload-tuned MAXDOP)
            and correct what shouldn't (CTFP=5, insecure toggles, stale flags).

  SAFETY    100% read-only. No sp_configure/RECONFIGURE/ALTER is executed here.
            The apply statements are PRINTED for you to review, not run.
  ============================================================================*/

SET NOCOUNT ON;
PRINT '======================================================================';
PRINT ' SOURCE CONFIG CAPTURE  —  ' + CONVERT(varchar(30), SYSDATETIME(), 120);
PRINT '======================================================================';

/*------------------------------------------------------------------------------
  1) INSTANCE IDENTITY  —  edition & collation MUST match on the target install
------------------------------------------------------------------------------*/
SELECT
    CONVERT(sysname, SERVERPROPERTY('ServerName'))          AS server_name,
    CONVERT(sysname, SERVERPROPERTY('Edition'))             AS edition,           -- target ISO edition MUST match
    CONVERT(sysname, SERVERPROPERTY('ProductVersion'))      AS product_version,
    CONVERT(sysname, SERVERPROPERTY('ProductLevel'))        AS product_level,
    CONVERT(sysname, SERVERPROPERTY('ProductUpdateLevel'))  AS cu_level,
    CONVERT(sysname, SERVERPROPERTY('Collation'))           AS server_collation,  -- feed to SQLCOLLATION in ConfigurationFile.ini
    CONVERT(int,     SERVERPROPERTY('IsClustered'))         AS is_clustered,
    CONVERT(int,     SERVERPROPERTY('IsHadrEnabled'))       AS is_hadr_enabled;

/*------------------------------------------------------------------------------
  2) CPU / NUMA / MEMORY SHAPE  —  drives MAXDOP and max server memory sizing
------------------------------------------------------------------------------*/
SELECT
    cpu_count                                   AS logical_cpus,
    hyperthread_ratio                           AS logical_per_socket,
    physical_memory_kb / 1024                   AS physical_memory_mb,
    (SELECT COUNT(*) FROM sys.dm_os_nodes
       WHERE node_state_desc = 'ONLINE' AND node_id < 64) AS numa_nodes_online
FROM sys.dm_os_sys_info;

-- Per-NUMA scheduler breakdown (the number that actually drives MAXDOP)
SELECT node_id, node_state_desc, online_scheduler_count, memory_node_id
FROM sys.dm_os_nodes
WHERE node_state_desc = 'ONLINE' AND node_id < 64
ORDER BY node_id;

/*------------------------------------------------------------------------------
  3) sp_configure  —  SOURCE value vs 2022 BEST-PRACTICE target value
     Anything with a recommendation different from the source is your action list.
     "run_value" is what's live; "config_value" is pending a RECONFIGURE.
------------------------------------------------------------------------------*/
DECLARE @rec TABLE (name nvarchar(70) PRIMARY KEY, recommended nvarchar(40), rationale nvarchar(400));
INSERT INTO @rec (name, recommended, rationale) VALUES
 ('cost threshold for parallelism','50',   'Default 5 sends nearly every query parallel. 50 is the standard starting point (25-75 depending on OLTP intensity). Do NOT carry the source value blindly.'),
 ('max degree of parallelism',    'calc',  'Set to logical cores per NUMA node, capped at 8. See the MAXDOP calc in section 4 — not a straight copy of source.'),
 ('max server memory (MB)',       'calc',  'Reserve the greater of 4GB or 10% for the OS. Re-derive from the TARGET VM RAM, not the source figure.'),
 ('min server memory (MB)',       '0',     'Leave 0 unless SQL is the only service on the VM.'),
 ('optimize for ad hoc workloads','1',     'Stores a plan stub on first execution — trims single-use plan cache bloat. Safe to enable everywhere.'),
 ('backup compression default',   '1',     'Enable globally. 50-70% smaller, faster backups. No downside on standard hardware.'),
 ('lock pages in memory',         '1',     'Only takes effect once the service account holds the Windows "Lock pages in memory" right. Prevents buffer-pool paging. Restart required.'),
 ('xp_cmdshell',                  '0',     'Keep OFF on production regardless of source. Re-architect any dependency as a SQL Agent CmdExec step.'),
 ('ad hoc distributed queries',   '0',     'Keep OFF unless OPENROWSET/OPENDATASOURCE is a governed, documented requirement.'),
 ('clr enabled',                  '0',     'Enable only if CLR assemblies are actually deployed. clr strict security stays 1.'),
 ('remote admin connections',     '1',     'Enable the DAC listener so you can get in when the scheduler is jammed.'),
 ('remote login timeout (s)',     '30',    'Bump from 10 to 30 for WAN / linked-server latency tolerance.');

SELECT
    c.name,
    c.value_in_use                                   AS source_run_value,
    c.value                                           AS source_config_value,
    ISNULL(r.recommended, '(review — no std change)') AS target_recommended,
    CASE
        WHEN r.recommended IS NULL THEN ''
        WHEN r.recommended IN ('calc') THEN '>> DERIVE ON TARGET'
        WHEN CONVERT(nvarchar(40), c.value_in_use) <> r.recommended THEN '>> CHANGE'
        ELSE 'ok'
    END                                               AS action,
    r.rationale
FROM sys.configurations c
LEFT JOIN @rec r ON r.name = c.name
ORDER BY CASE WHEN r.recommended IS NULL THEN 1 ELSE 0 END, c.name;

/*------------------------------------------------------------------------------
  4) MAXDOP + COST THRESHOLD  —  computed recommendation for THIS hardware
------------------------------------------------------------------------------*/
DECLARE @sched_per_node int, @rec_maxdop int, @src_maxdop int, @src_ctfp int;

SELECT TOP 1 @sched_per_node = online_scheduler_count
FROM sys.dm_os_nodes
WHERE node_state_desc = 'ONLINE' AND node_id < 64
ORDER BY online_scheduler_count DESC;

SET @rec_maxdop = CASE WHEN @sched_per_node > 8 THEN 8 ELSE @sched_per_node END;

SELECT @src_maxdop = CONVERT(int, value_in_use) FROM sys.configurations WHERE name = 'max degree of parallelism';
SELECT @src_ctfp   = CONVERT(int, value_in_use) FROM sys.configurations WHERE name = 'cost threshold for parallelism';

PRINT '';
PRINT '--- MAXDOP / CTFP DERIVATION -----------------------------------------';
PRINT '  Logical schedulers per NUMA node : ' + CONVERT(varchar(10), @sched_per_node);
PRINT '  Source MAXDOP                    : ' + CONVERT(varchar(10), @src_maxdop);
PRINT '  Recommended target MAXDOP        : ' + CONVERT(varchar(10), @rec_maxdop) + '   (cores per NUMA node, capped at 8)';
PRINT '  Source cost threshold            : ' + CONVERT(varchar(10), @src_ctfp);
PRINT '  Recommended target CTFP          : 50  (tune 25-75 for OLTP intensity)';
IF @rec_maxdop <> @src_maxdop PRINT '  NOTE: target MAXDOP differs from source — this is expected if the VM is resized.';

/*------------------------------------------------------------------------------
  5) TRACE FLAGS  —  what's live now + what's set at startup
     Don't blindly re-add these on 2022. Several 2016-era flags are now default
     engine behaviour or have moved to database-scoped configuration:
       1117/1118 -> tempdb autogrow/allocation is default per-DB behaviour now
       2371      -> dynamic stats threshold is default under compat 130+
       4199      -> largely governed by compat level + DB-scoped QUERY_OPTIMIZER_HOTFIXES
       7412      -> lightweight query profiling is on by default in 2019+
     Keep the ones that still earn their place (e.g. 3226 suppress backup-success
     log spam, 1204/1222 deadlock capture) and retire the rest.
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#tf') IS NOT NULL DROP TABLE #tf;
CREATE TABLE #tf (TraceFlag int, Status int, Global int, Session int);
INSERT INTO #tf EXEC('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');
SELECT TraceFlag AS global_trace_flag_live_now
FROM #tf WHERE Global = 1
ORDER BY TraceFlag;

-- Startup (-T) parameters as stored in the registry — the durable definition
SELECT value_name, value_data AS startup_parameter
FROM sys.dm_server_registry
WHERE value_name LIKE N'SQLArg%'
ORDER BY value_name;

/*------------------------------------------------------------------------------
  6) QUERY STORE  —  current per-database state on the source
     (You'll also want QS enabled on the target's migrated DBs — see below.)
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#qs') IS NOT NULL DROP TABLE #qs;
CREATE TABLE #qs (
    database_name        sysname,
    desired_state        nvarchar(60),
    actual_state         nvarchar(60),
    max_storage_mb       bigint,
    capture_mode         nvarchar(60),
    cleanup_days         bigint,
    flush_secs           bigint
);

DECLARE @db sysname, @sql nvarchar(max);
DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE database_id > 4 AND state = 0 AND is_read_only = 0;   -- online user DBs only
OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
        SELECT @dbn,
               desired_state_desc, actual_state_desc,
               max_storage_size_mb, query_capture_mode_desc,
               stale_query_threshold_days, flush_interval_seconds
        FROM ' + QUOTENAME(@db) + N'.sys.database_query_store_options;';
    BEGIN TRY
        INSERT INTO #qs EXEC sp_executesql @sql, N'@dbn sysname', @dbn = @db;
    END TRY
    BEGIN CATCH
        -- older/edge DBs may not expose the DMV; skip quietly
    END CATCH
    FETCH NEXT FROM db_cur INTO @db;
END
CLOSE db_cur; DEALLOCATE db_cur;

SELECT * FROM #qs ORDER BY database_name;

/*==============================================================================
  APPLY-ON-TARGET SNIPPETS  (printed to Messages — review before running on 2022)
  ============================================================================*/
PRINT '';
PRINT '======================================================================';
PRINT ' APPLY ON TARGET 2022 — instance-level essentials (review first)';
PRINT '======================================================================';
PRINT 'EXEC sys.sp_configure ''show advanced options'', 1; RECONFIGURE;';
PRINT 'EXEC sys.sp_configure ''cost threshold for parallelism'', 50; RECONFIGURE;';
PRINT 'EXEC sys.sp_configure ''max degree of parallelism'', ' + CONVERT(varchar(10), @rec_maxdop) + '; RECONFIGURE;';
PRINT 'EXEC sys.sp_configure ''optimize for ad hoc workloads'', 1; RECONFIGURE;';
PRINT 'EXEC sys.sp_configure ''backup compression default'', 1; RECONFIGURE;';
PRINT 'EXEC sys.sp_configure ''remote admin connections'', 1; RECONFIGURE;';
PRINT '-- max server memory: derive from TARGET VM RAM (reserve max(4GB,10%) for OS).';
PRINT '-- lock pages in memory: grant the Windows right to the service account first, then set = 1 and restart.';
PRINT '';
PRINT '-- Query Store, per migrated user DB (best-practice baseline):';
PRINT 'ALTER DATABASE [<DbName>] SET QUERY_STORE = ON';
PRINT '  (OPERATION_MODE = READ_WRITE,';
PRINT '   MAX_STORAGE_SIZE_MB = 2048,';
PRINT '   DATA_FLUSH_INTERVAL_SECONDS = 900,';
PRINT '   INTERVAL_LENGTH_MINUTES = 60,';
PRINT '   CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),';
PRINT '   SIZE_BASED_CLEANUP_MODE = AUTO,        -- stops QS flipping to READ_ONLY when full';
PRINT '   QUERY_CAPTURE_MODE = AUTO,             -- ignores trivial/one-off queries';
PRINT '   MAX_PLANS_PER_QUERY = 200,';
PRINT '   WAIT_STATS_CAPTURE_MODE = ON);';
PRINT '-- SQL 2022 only: also ALTER DATABASE ... SET QUERY_STORE = ON for readable AG secondaries.';

PRINT '';
PRINT 'Capture complete.';
