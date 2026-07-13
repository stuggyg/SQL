/*==============================================================================
  Detect-Fix-OrphanedUsers.sql
  ----------------------------------------------------------------------------
  PURPOSE   Post-restore on the TARGET 2022 instance. Scans every online user
            database for orphaned users (DB principal whose SID matches no
            server login) and classifies the required fix.

  MODES     @DryRun = 1 (DEFAULT)  -> detect + PRINT the remediation T-SQL only.
            @DryRun = 0            -> detect + EXECUTE the safe REMAP fixes
                                      (ALTER USER ... WITH LOGIN). Never creates
                                      logins automatically — those are reported
                                      for sp_help_revlogin.

  REMEDY    REMAP         : a server login of the SAME NAME exists (fresh SID) ->
                            re-point the user with ALTER USER WITH LOGIN. Safe,
                            idempotent.
            LOGIN MISSING : no server login exists at all -> the login was not
                            migrated. Recreate it (SID-preserving via
                            sp_help_revlogin for SQL logins, or add the Windows
                            login/group), then re-run this script.

  ASSUMPTION REMAP maps DB user name -> server login of the identical name
             (the normal case). If a user must map to a differently-named
             login, do that one by hand.

  SAFETY    Detection is read-only. Only @DryRun = 0 issues ALTER USER, and only
            for REMAP rows. No login creation, no drops.
  ============================================================================*/

SET NOCOUNT ON;

DECLARE @DryRun bit = 1;   -- <<< set to 0 to APPLY the REMAP fixes

IF OBJECT_ID('tempdb..#orphans') IS NOT NULL DROP TABLE #orphans;
CREATE TABLE #orphans (
    database_name sysname,
    db_user       sysname,
    user_type     nvarchar(60),
    sid           varbinary(85),
    remedy        varchar(20),
    fix_tsql      nvarchar(600)
);

DECLARE @db sysname, @sql nvarchar(max);
DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE database_id > 4 AND state = 0;   -- online user DBs

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
        INSERT INTO #orphans (database_name, db_user, user_type, sid, remedy, fix_tsql)
        SELECT
            @dbn,
            dp.name,
            dp.type_desc,
            dp.sid,
            CASE WHEN sl.name IS NOT NULL THEN ''REMAP'' ELSE ''LOGIN MISSING'' END,
            CASE WHEN sl.name IS NOT NULL
                 THEN ''USE '' + QUOTENAME(@dbn) + ''; ALTER USER '' + QUOTENAME(dp.name)
                      + '' WITH LOGIN = '' + QUOTENAME(dp.name) + '';''
                 ELSE ''-- LOGIN MISSING: recreate '' + QUOTENAME(dp.name)
                      + '' (sp_help_revlogin for SQL logins), then re-run.''
            END
        FROM ' + QUOTENAME(@db) + N'.sys.database_principals dp
        LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid          -- SID match?
        LEFT JOIN sys.server_principals sl ON sl.name = dp.name        -- same-name login exists?
        WHERE sp.sid IS NULL
          AND dp.type IN (''S'',''U'',''G'')                          -- SQL user / Windows user / Windows group
          AND dp.authentication_type_desc <> ''NONE''                 -- exclude contained / no-login users
          AND dp.name NOT IN (''dbo'',''guest'',''sys'',''INFORMATION_SCHEMA'');';

    BEGIN TRY
        EXEC sp_executesql @sql, N'@dbn sysname', @dbn = @db;
    END TRY
    BEGIN CATCH
        PRINT '  !! Skipped ' + QUOTENAME(@db) + ' — ' + ERROR_MESSAGE();
    END CATCH

    FETCH NEXT FROM db_cur INTO @db;
END
CLOSE db_cur; DEALLOCATE db_cur;

/*------------------------------------------------------------------------------
  Report
------------------------------------------------------------------------------*/
SELECT database_name, db_user, user_type, remedy, fix_tsql
FROM #orphans
ORDER BY CASE remedy WHEN 'LOGIN MISSING' THEN 0 ELSE 1 END, database_name, db_user;

DECLARE @total int, @remap int, @missing int;
SELECT @total   = COUNT(*)                                        FROM #orphans;
SELECT @remap   = COUNT(*) FROM #orphans WHERE remedy = 'REMAP';
SELECT @missing = COUNT(*) FROM #orphans WHERE remedy = 'LOGIN MISSING';

PRINT '======================================================================';
PRINT ' Orphan scan complete.  Total: ' + CONVERT(varchar(10), @total)
      + '   REMAP: ' + CONVERT(varchar(10), @remap)
      + '   LOGIN MISSING: ' + CONVERT(varchar(10), @missing);
PRINT '======================================================================';

/*------------------------------------------------------------------------------
  Dry-run: print the fixes.   Apply: execute only the REMAP rows.
------------------------------------------------------------------------------*/
IF @DryRun = 1
BEGIN
    PRINT '';
    PRINT '-- DRY RUN — remediation T-SQL (review, then set @DryRun = 0 to apply REMAPs):';
    DECLARE @line nvarchar(600);
    DECLARE p_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT fix_tsql FROM #orphans ORDER BY database_name, db_user;
    OPEN p_cur;
    FETCH NEXT FROM p_cur INTO @line;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        PRINT @line;
        FETCH NEXT FROM p_cur INTO @line;
    END
    CLOSE p_cur; DEALLOCATE p_cur;
    IF @missing > 0
        PRINT '-- NOTE: LOGIN MISSING rows are NOT fixed here — recreate those logins first.';
END
ELSE
BEGIN
    PRINT '';
    PRINT '-- APPLY MODE — executing REMAP fixes only:';
    DECLARE @exec nvarchar(600);
    DECLARE x_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT fix_tsql FROM #orphans WHERE remedy = 'REMAP' ORDER BY database_name, db_user;
    OPEN x_cur;
    FETCH NEXT FROM x_cur INTO @exec;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC (@exec);
            PRINT '  OK  ' + @exec;
        END TRY
        BEGIN CATCH
            PRINT '  ERR ' + @exec + '  -> ' + ERROR_MESSAGE();
        END CATCH
        FETCH NEXT FROM x_cur INTO @exec;
    END
    CLOSE x_cur; DEALLOCATE x_cur;
    IF @missing > 0
        PRINT '-- REMINDER: ' + CONVERT(varchar(10), @missing)
              + ' LOGIN MISSING row(s) still outstanding — recreate logins, then re-run.';
END

IF OBJECT_ID('tempdb..#orphans') IS NOT NULL DROP TABLE #orphans;
