/*═══════════════════════════════════════════════════════════════════════════
  SQL Server 2022 — Post-Install Hardening  (capstone script)
  ---------------------------------------------------------------------------
  Companion to:
    • SQL2022_Engine_Config.sql          (engine settings)
    • Copy-SqlEngineSettings.ps1         (settings copy source→target)
    • SQL_GodRights_Login_Audit.sql      (privilege / login audit)

  SAFETY
    • @DryRun = 1 by default: PRINTS every change, executes NOTHING. Review the
      output, then set @DryRun = 0 to apply.
    • Read the sa section carefully — confirm you have another working sysadmin
      BEFORE disabling sa, or you can lock yourself out.
    • Run this AFTER migration validation, not mid-cutover. Tightening security
      before jobs/linked servers/SPNs are proven can mask Kerberos/orphan
      issues as permission errors.
    • Items that need a service RESTART or an OS/AD change are printed as a
      manual checklist at the end — this script does not restart the service.
═══════════════════════════════════════════════════════════════════════════*/

SET NOCOUNT ON;

DECLARE @DryRun            BIT = 1;          -- ►► 1 = preview only, 0 = apply ◄◄
DECLARE @DisableSa         BIT = 1;          -- rename + disable sa
DECLARE @SaNewName    SYSNAME = N'disabled_sa';
DECLARE @AuditPath  NVARCHAR(260) = N'X:\Audit\';   -- must exist, ACL-locked
DECLARE @ErrorLogCount     INT = 20;         -- retained error logs

DECLARE @sql NVARCHAR(MAX);

-- Helper: run-or-print
--   (inline below via IF @DryRun rather than a proc, to keep this single-file)

PRINT '======================================================================';
PRINT ' HARDENING RUN   ' + CONVERT(VARCHAR, SYSDATETIME(), 120)
      + '   MODE: ' + CASE WHEN @DryRun = 1 THEN 'DRY RUN (no changes)' ELSE 'APPLY' END;
PRINT ' Instance: ' + @@SERVERNAME;
PRINT '======================================================================';


/*───────────────────────────────────────────────────────────────────────────
  1) SURFACE AREA — disable risky features (safe defaults)
───────────────────────────────────────────────────────────────────────────*/
PRINT CHAR(10) + '--- 1. Surface area reduction ---';
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;

DECLARE @feat TABLE (name NVARCHAR(64), target_val INT);
INSERT @feat VALUES
    ('xp_cmdshell', 0),
    ('Ole Automation Procedures', 0),
    ('ad hoc distributed queries', 0),
    ('clr strict security', 1),
    ('remote admin connections', 1),   -- remote DAC ON (manageability)
    ('scan for startup procs', 0);

DECLARE @fname NVARCHAR(64), @fval INT, @cur INT;
DECLARE fc CURSOR LOCAL FAST_FORWARD FOR SELECT name, target_val FROM @feat;
OPEN fc; FETCH NEXT FROM fc INTO @fname, @fval;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @cur = CONVERT(INT, value_in_use) FROM sys.configurations WHERE name = @fname;
    IF @cur IS NULL
        PRINT '   (skip) ' + @fname + ' not present on this build';
    ELSE IF @cur = @fval
        PRINT '   ok    ' + @fname + ' already = ' + CONVERT(VARCHAR,@fval);
    ELSE
    BEGIN
        SET @sql = 'EXEC sp_configure ''' + @fname + ''', ' + CONVERT(VARCHAR,@fval) + '; RECONFIGURE;';
        IF @DryRun = 1 PRINT '   WOULD  ' + @sql;
        ELSE BEGIN EXEC (@sql); PRINT '   SET    ' + @fname + ' ' + CONVERT(VARCHAR,@cur) + ' -> ' + CONVERT(VARCHAR,@fval); END
    END
    FETCH NEXT FROM fc INTO @fname, @fval;
END
CLOSE fc; DEALLOCATE fc;


/*───────────────────────────────────────────────────────────────────────────
  2) sa — rename + disable   (guard: confirm another sysadmin exists first)
───────────────────────────────────────────────────────────────────────────*/
PRINT CHAR(10) + '--- 2. sa account ---';
IF @DisableSa = 1
BEGIN
    DECLARE @otherSysadmins INT;
    SELECT @otherSysadmins = COUNT(*)
    FROM   sys.server_role_members rm
    JOIN   sys.server_principals sp ON sp.principal_id = rm.member_principal_id
    JOIN   sys.server_principals r  ON r.principal_id  = rm.role_principal_id
    WHERE  r.name = 'sysadmin' AND sp.sid <> 0x01 AND sp.is_disabled = 0;

    DECLARE @saName SYSNAME = (SELECT name FROM sys.server_principals WHERE sid = 0x01);

    IF @otherSysadmins = 0
        PRINT '   *** ABORT sa change: no OTHER enabled sysadmin exists. '
            + 'Add one first or you will be locked out. ***';
    ELSE
    BEGIN
        PRINT '   guard ok: ' + CONVERT(VARCHAR,@otherSysadmins) + ' other enabled sysadmin(s) present.';

        -- rename (only if not already renamed)
        IF @saName = N'sa'
        BEGIN
            SET @sql = 'ALTER LOGIN [sa] WITH NAME = ' + QUOTENAME(@SaNewName) + ';';
            IF @DryRun = 1 PRINT '   WOULD  ' + @sql;
            ELSE BEGIN EXEC (@sql); PRINT '   SET    sa renamed to ' + @SaNewName; SET @saName = @SaNewName; END
        END
        ELSE PRINT '   ok    sa already renamed to ' + @saName;

        -- disable
        SET @sql = 'ALTER LOGIN ' + QUOTENAME(@saName) + ' DISABLED;';
        IF @DryRun = 1 PRINT '   WOULD  ' + @sql;
        ELSE BEGIN EXEC (@sql); PRINT '   SET    ' + @saName + ' disabled'; END
    END
END
ELSE PRINT '   (skipped: @DisableSa = 0)';


/*───────────────────────────────────────────────────────────────────────────
  3) LOGIN AUDITING — successful + failed, durable via SQL Server Audit
     (default only logs failures; this gives you real login history going fwd)
───────────────────────────────────────────────────────────────────────────*/
PRINT CHAR(10) + '--- 3. Login auditing (SQL Server Audit) ---';
IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = 'Login_Audit')
    PRINT '   ok    Server audit ''Login_Audit'' already exists';
ELSE
BEGIN
    SET @sql =
      'CREATE SERVER AUDIT Login_Audit TO FILE (FILEPATH = ''' + @AuditPath + ''',
         MAXSIZE = 256 MB, MAX_ROLLOVER_FILES = 20) WITH (ON_FAILURE = CONTINUE);
       ALTER SERVER AUDIT Login_Audit WITH (STATE = ON);
       CREATE SERVER AUDIT SPECIFICATION Login_Spec FOR SERVER AUDIT Login_Audit
         ADD (SUCCESSFUL_LOGIN_GROUP), ADD (FAILED_LOGIN_GROUP) WITH (STATE = ON);';
    IF @DryRun = 1 PRINT '   WOULD  create Login_Audit + spec at ' + @AuditPath + ' (ensure path exists & is ACL-locked)';
    ELSE BEGIN EXEC (@sql); PRINT '   SET    Login_Audit created and enabled at ' + @AuditPath; END
END


/*───────────────────────────────────────────────────────────────────────────
  4) ERROR LOG RETENTION — keep more history across restarts
───────────────────────────────────────────────────────────────────────────*/
PRINT CHAR(10) + '--- 4. Error log retention ---';
DECLARE @curLogs INT;
EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',
     N'Software\Microsoft\MSSQLServer\MSSQLServer', N'NumErrorLogs', @curLogs OUTPUT;
IF @curLogs >= @ErrorLogCount
    PRINT '   ok    NumErrorLogs already = ' + CONVERT(VARCHAR, ISNULL(@curLogs,-1));
ELSE
BEGIN
    IF @DryRun = 1
        PRINT '   WOULD  set NumErrorLogs to ' + CONVERT(VARCHAR,@ErrorLogCount)
            + ' (current ' + CONVERT(VARCHAR, ISNULL(@curLogs,6)) + ')';
    ELSE
    BEGIN
        EXEC master.dbo.xp_instance_regwrite N'HKEY_LOCAL_MACHINE',
             N'Software\Microsoft\MSSQLServer\MSSQLServer', N'NumErrorLogs',
             REG_DWORD, @ErrorLogCount;
        PRINT '   SET    NumErrorLogs -> ' + CONVERT(VARCHAR,@ErrorLogCount);
    END
END


/*───────────────────────────────────────────────────────────────────────────
  5) VERIFY — quick posture snapshot
───────────────────────────────────────────────────────────────────────────*/
PRINT CHAR(10) + '--- 5. Verification snapshot ---';
SELECT name, CONVERT(INT, value_in_use) AS value_in_use
FROM   sys.configurations
WHERE  name IN ('xp_cmdshell','Ole Automation Procedures','ad hoc distributed queries',
                'clr strict security','remote admin connections','scan for startup procs')
ORDER BY name;

SELECT name AS sa_login, is_disabled
FROM   sys.server_principals WHERE sid = 0x01;

SELECT a.name AS audit_name, a.is_state_enabled, s.name AS spec_name, s.is_state_enabled AS spec_enabled
FROM   sys.server_audits a
LEFT JOIN sys.server_audit_specifications s ON 1 = 1
WHERE  a.name = 'Login_Audit';


/*───────────────────────────────────────────────────────────────────────────
  MANUAL — cannot be done from T-SQL (OS / AD / Config Manager / restart)
───────────────────────────────────────────────────────────────────────────*/
PRINT CHAR(10) + '=== STILL MANUAL ===';
PRINT ' TLS       : deploy CA-signed cert; set ForceEncryption; push Encrypt=True in conn strings';
PRINT ' TDE       : enable on sensitive DBs, then BACK UP the cert + private key OFF-BOX';
PRINT ' Service acct: dedicated low-priv domain acct / gMSA; never LocalSystem or domain admin';
PRINT ' [RESTART] Lock Pages in Memory  -> grant to service account';
PRINT ' IFI       : grant "Perform volume maintenance tasks" to service account';
PRINT ' Network   : disable Named Pipes, static TCP port, scope firewall to app subnet';
PRINT ' SPNs      : register MSSQLSvc SPNs for new server FQDN + NetBIOS (+ AG listener)';
PRINT ' NTFS ACLs : lock data/log/backup volumes to service acct + DBAs only';
PRINT ' AV excl   : .mdf .ndf .ldf .bak .trn + SQL binary directory';
PRINT ' Power plan: High Performance';
PRINT ' Backups   : encrypted, off-box, restore-tested';
PRINT ' Audit path: confirm ' + @AuditPath + ' exists and is ACL-restricted';
GO
