/*==============================================================================
  01b_Capture_Source_DB_Settings.sql
  ----------------------------------------------------------------------------
  PURPOSE   Run on each SOURCE SQL Server 2016 instance. Populates the SOURCE-side
            columns of the Database sheet in SQL_Source_to_Target_Mapping.xlsx.
            Companion to 01_Capture_Source_Config.sql (which is instance-level).

  OUTPUT    ONE result grid, columns ordered left-to-right to match the sheet's
            source-side fields. Air-gapped: right-click > Save Results As, carry
            across on approved media, paste into the Database sheet.

  SCOPE     Online user databases only (database_id > 4, state = 0). Offline DBs
            cannot expose per-DB catalog views and must be captured manually.

  SAFETY    Read-only. DBCC DBINFO is a read-only diagnostic (last-known-good
            CHECKDB date only). No ALTER / sp_configure / RECONFIGURE.
  ============================================================================*/

SET NOCOUNT ON;

/*------------------------------------------------------------------------------
  Per-DB values that require a cross-database context switch (assemblies,
  full-text catalogs, Query Store state, DBINFO). Collected via cursor into #db.
------------------------------------------------------------------------------*/
IF OBJECT_ID('tempdb..#db')  IS NOT NULL DROP TABLE #db;
IF OBJECT_ID('tempdb..#dbi') IS NOT NULL DROP TABLE #dbi;

CREATE TABLE #db (
    database_id     int PRIMARY KEY,
    clr_user_objs   int          NULL,   -- user assemblies present?
    fulltext_cats   int          NULL,   -- full-text catalogs present?
    qs_state        nvarchar(60) NULL,   -- Query Store actual state
    last_known_good nvarchar(40) NULL    -- last successful CHECKDB (pre-run baseline)
);
CREATE TABLE #dbi (ParentObject varchar(255), Object varchar(255), Field varchar(255), Value varchar(255));

DECLARE @id int, @nm sysname, @sql nvarchar(max),
        @clr int, @ft int, @qs nvarchar(60), @lkg nvarchar(40);

DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT database_id, name
    FROM sys.databases
    WHERE database_id > 4 AND state = 0;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @id, @nm;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @clr = NULL; SET @ft = NULL; SET @qs = 'NOT_SUPPORTED'; SET @lkg = NULL;

    -- user CLR assemblies
    SET @sql = N'SELECT @o = COUNT(*) FROM ' + QUOTENAME(@nm) + N'.sys.assemblies WHERE is_user_defined = 1;';
    BEGIN TRY EXEC sp_executesql @sql, N'@o int OUTPUT', @o = @clr OUTPUT; END TRY BEGIN CATCH SET @clr = NULL; END CATCH

    -- full-text catalogs
    SET @sql = N'SELECT @o = COUNT(*) FROM ' + QUOTENAME(@nm) + N'.sys.fulltext_catalogs;';
    BEGIN TRY EXEC sp_executesql @sql, N'@o int OUTPUT', @o = @ft OUTPUT; END TRY BEGIN CATCH SET @ft = NULL; END CATCH

    -- Query Store actual state
    SET @sql = N'SELECT @o = actual_state_desc FROM ' + QUOTENAME(@nm) + N'.sys.database_query_store_options;';
    BEGIN TRY EXEC sp_executesql @sql, N'@o nvarchar(60) OUTPUT', @o = @qs OUTPUT; END TRY BEGIN CATCH SET @qs = 'NOT_SUPPORTED'; END CATCH

    -- last known good CHECKDB from DBINFO (read-only diagnostic)
    BEGIN TRY
        TRUNCATE TABLE #dbi;
        SET @sql = N'DBCC DBINFO(''' + @nm + N''') WITH TABLERESULTS, NO_INFOMSGS';
        INSERT INTO #dbi EXEC (@sql);
        SELECT @lkg = Value FROM #dbi WHERE Field = 'dbi_dbccLastKnownGood';
    END TRY BEGIN CATCH SET @lkg = NULL; END CATCH

    INSERT INTO #db (database_id, clr_user_objs, fulltext_cats, qs_state, last_known_good)
    VALUES (@id, @clr, @ft, @qs, @lkg);

    FETCH NEXT FROM db_cur INTO @id, @nm;
END
CLOSE db_cur; DEALLOCATE db_cur;

/*------------------------------------------------------------------------------
  Set-based source: sizes, owner, collation, compat, recovery, security toggles,
  replication topology. Joined to the per-DB #db values for the final grid.
------------------------------------------------------------------------------*/
;WITH mf AS (
    SELECT
        database_id,
        CAST(SUM(CASE WHEN type = 0 THEN size END) * 8 / 1024.0 AS decimal(18,1)) AS data_mb,
        CAST(SUM(CASE WHEN type = 1 THEN size END) * 8 / 1024.0 AS decimal(18,1)) AS log_mb,
        MAX(CASE WHEN type = 2 THEN 1 ELSE 0 END)                                 AS has_filestream
    FROM sys.master_files
    GROUP BY database_id
)
SELECT
    CONVERT(sysname, SERVERPROPERTY('ServerName'))                 AS [Source Instance],
    d.name                                                          AS [Database Name],
    ISNULL(SUSER_SNAME(d.owner_sid), '(orphan SID - set to sa/dbo)')AS [Owner],
    d.collation_name                                               AS [Src DB Collation],
    d.compatibility_level                                          AS [Src Compat Level],
    d.recovery_model_desc                                          AS [Recovery Model],
    mf.data_mb                                                     AS [Src Data Size (MB)],
    mf.log_mb                                                      AS [Src Log Size (MB)],
    d.page_verify_option_desc                                      AS [PAGE_VERIFY],
    db.qs_state                                                    AS [Query Store Enabled],
    CASE WHEN d.is_encrypted = 1 THEN 'Yes' ELSE 'No' END          AS [TDE Enabled],
    CASE WHEN db.clr_user_objs > 0 THEN 'Yes (' + CONVERT(varchar(10), db.clr_user_objs) + ')' ELSE 'No' END AS [CLR],
    CASE WHEN mf.has_filestream = 1 THEN 'Yes' ELSE 'No' END       AS [FILESTREAM],
    CASE WHEN db.fulltext_cats > 0 THEN 'Yes (' + CONVERT(varchar(10), db.fulltext_cats) + ')' ELSE 'No' END AS [Full-Text],
    CASE WHEN d.is_broker_enabled = 1 THEN 'Yes' ELSE 'No' END     AS [Service Broker],
    ISNULL(NULLIF(STUFF(
        CASE WHEN d.is_published = 1 OR d.is_merge_published = 1 THEN ',Repl(Pub)' ELSE '' END +
        CASE WHEN d.is_subscribed = 1                           THEN ',Repl(Sub)' ELSE '' END +
        CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_primary_databases   lp WHERE lp.primary_database   = d.name)
               OR EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_secondary_databases ls WHERE ls.secondary_database = d.name)
                                                                 THEN ',LogShip'   ELSE '' END +
        CASE WHEN dm.mirroring_guid IS NOT NULL                 THEN ',Mirror'     ELSE '' END
        , 1, 1, ''), ''), 'None')                                 AS [Repl/LogShip/Mirroring],
    ISNULL(db.last_known_good, '(none recorded)')                 AS [Src DBCC CHECKDB (last known good)]
FROM sys.databases d
JOIN #db db            ON db.database_id = d.database_id
LEFT JOIN mf           ON mf.database_id = d.database_id
LEFT JOIN sys.database_mirroring dm ON dm.database_id = d.database_id
WHERE d.database_id > 4 AND d.state = 0
ORDER BY d.name;

IF OBJECT_ID('tempdb..#dbi') IS NOT NULL DROP TABLE #dbi;
IF OBJECT_ID('tempdb..#db')  IS NOT NULL DROP TABLE #db;
