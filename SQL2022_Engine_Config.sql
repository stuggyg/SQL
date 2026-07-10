/*═══════════════════════════════════════════════════════════════════════════
  SQL Server 2022 — Engine Settings: Capture, Configure & Verify
  ---------------------------------------------------------------------------
  Companion to the Air-Gapped 2016→2022 Migration Runbook.

  USAGE
    PART A  — run on the SOURCE 2016 instance. Record the outputs.
    PART B  — edit the @variables at the top to match Part A, then run on the
              new TARGET 2022 instance.
    PART C  — run on the TARGET after Part B to verify everything took.

  Nothing here restarts the service. Settings marked [RESTART] below only take
  effect after a SQL Server service restart — schedule one before go-live.
═══════════════════════════════════════════════════════════════════════════*/


/*───────────────────────────────────────────────────────────────────────────
  PART A — CAPTURE FROM SOURCE  (run on the 2016 box, save the results)
───────────────────────────────────────────────────────────────────────────*/

-- Core sizing facts you need to compute target values
SELECT  cpu_count                       AS logical_cpus,
        hyperthread_ratio,
        cpu_count / hyperthread_ratio   AS physical_cpus,
        (SELECT COUNT(DISTINCT memory_node_id)
           FROM sys.dm_os_memory_nodes
          WHERE memory_node_id <> 64)   AS numa_nodes,
        CAST(physical_memory_kb/1024.0/1024.0 AS DECIMAL(9,1)) AS total_ram_gb
FROM    sys.dm_os_sys_info;

-- All the sp_configure values in one shot (advanced options included)
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
SELECT  name, value_in_use
FROM    sys.configurations
WHERE   name IN (
          'max server memory (MB)','min server memory (MB)',
          'max degree of parallelism','cost threshold for parallelism',
          'optimize for ad hoc workloads','backup compression default',
          'remote admin connections','remote login timeout (s)',
          'remote query timeout (s)','fill factor (%)','recovery interval (min)',
          'max worker threads','clr enabled','clr strict security',
          'xp_cmdshell','ad hoc distributed queries',
          'contained database authentication','default language')
ORDER BY name;

-- Collation MUST match on target — record this exactly
SELECT SERVERPROPERTY('Collation') AS server_collation;

-- Trace flags active at runtime (startup params live in Configuration Manager)
DBCC TRACESTATUS(-1);
GO


/*───────────────────────────────────────────────────────────────────────────
  PART B — CONFIGURE TARGET  (edit these, then run on the 2022 box)
───────────────────────────────────────────────────────────────────────────*/

-- ►► EDIT to match Part A / your sizing rules ◄◄
DECLARE @MaxServerMemoryMB   INT = 57344;  -- e.g. 64GB VM → reserve ~8GB for OS
DECLARE @MinServerMemoryMB   INT = 0;      -- leave 0 unless SQL is sole service
DECLARE @MaxDop              INT = 8;      -- cores per NUMA node, capped at 8
DECLARE @CostThreshold       INT = 50;     -- 25–75; match source then tune
DECLARE @RemoteLoginTimeout  INT = 30;     -- bump for WAN linked servers

EXEC sp_configure 'show advanced options', 1; RECONFIGURE;

-- Memory
EXEC sp_configure 'max server memory (MB)', @MaxServerMemoryMB;
EXEC sp_configure 'min server memory (MB)', @MinServerMemoryMB;

-- Parallelism (set BOTH — MAXDOP alone is a half-fix)
EXEC sp_configure 'max degree of parallelism',      @MaxDop;
EXEC sp_configure 'cost threshold for parallelism', @CostThreshold;

-- Plan cache / backups / manageability
EXEC sp_configure 'optimize for ad hoc workloads', 1;
EXEC sp_configure 'backup compression default',    1;
EXEC sp_configure 'remote admin connections',      1;   -- remote DAC
EXEC sp_configure 'remote login timeout (s)',      @RemoteLoginTimeout;

-- Security posture (keep these OFF unless a workload explicitly needs them)
EXEC sp_configure 'xp_cmdshell',                0;
EXEC sp_configure 'ad hoc distributed queries', 0;
EXEC sp_configure 'clr strict security',        1;
-- EXEC sp_configure 'clr enabled', 1;   -- ONLY if SSIS catalog / CLR objects needed

RECONFIGURE WITH OVERRIDE;
GO

PRINT '--- sp_configure applied. Items below are MANUAL / [RESTART] ---';
PRINT '[RESTART]  Lock Pages in Memory  : grant "Lock pages in memory" to the SQL service account (secpol.msc / gpedit)';
PRINT 'MANUAL     Instant File Init     : grant "Perform volume maintenance tasks" to the SQL service account';
PRINT 'MANUAL     Power Plan            : set Windows to High Performance (Balanced throttles CPU)';
PRINT 'MANUAL     AV exclusions         : exclude .mdf .ndf .ldf .bak .trn + SQL binary dir';
PRINT 'MANUAL     Named Pipes off / static TCP port in SQL Server Configuration Manager';
PRINT 'MANUAL     Error log retention   : SSMS > Management > SQL Server Logs > Configure > 20+';
PRINT 'MANUAL     tempdb               : 1 file/core (max 8), all EQUAL size, fixed-MB growth';
PRINT 'MANUAL     Trace flags          : re-add source startup params in Configuration Manager';
GO


/*───────────────────────────────────────────────────────────────────────────
  PART C — VERIFY TARGET  (run after Part B; eyeball against Part A)
───────────────────────────────────────────────────────────────────────────*/

SELECT  name,
        value_in_use,
        CASE name
          WHEN 'max server memory (MB)'           THEN 'should NOT be 2147483647'
          WHEN 'max degree of parallelism'        THEN 'should NOT be 0 on multi-core'
          WHEN 'cost threshold for parallelism'   THEN 'should be ~50, not 5'
          WHEN 'optimize for ad hoc workloads'    THEN 'should be 1'
          WHEN 'backup compression default'       THEN 'should be 1'
          WHEN 'remote admin connections'         THEN 'should be 1'
          WHEN 'xp_cmdshell'                      THEN 'should be 0'
          WHEN 'ad hoc distributed queries'       THEN 'should be 0'
          ELSE ''
        END AS sanity_check
FROM    sys.configurations
WHERE   name IN (
          'max server memory (MB)','min server memory (MB)',
          'max degree of parallelism','cost threshold for parallelism',
          'optimize for ad hoc workloads','backup compression default',
          'remote admin connections','remote login timeout (s)',
          'xp_cmdshell','ad hoc distributed queries','clr strict security')
ORDER BY name;

-- Confirm target collation matches what you recorded in Part A
SELECT SERVERPROPERTY('Collation') AS server_collation;

-- Confirm build/CU is the slipstreamed level, not RTM
SELECT SERVERPROPERTY('ProductVersion') AS build,
       SERVERPROPERTY('ProductLevel')   AS level,
       SERVERPROPERTY('ProductUpdateLevel') AS cu;
GO
