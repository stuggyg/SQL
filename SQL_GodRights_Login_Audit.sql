/*═══════════════════════════════════════════════════════════════════════════
  SQL Server — "Who Has God Rights" Audit  +  Login History
  ---------------------------------------------------------------------------
  Run per instance. Read-only: nothing is changed. Section 1–4 = privilege
  audit; Section 5 = login history (with honest caveats on what SQL keeps).

  Group expansion (Section 3) uses xp_logininfo, which queries Active
  Directory — the account running this needs AD read rights, and the SQL
  service account needs 'Read servicePrincipalName'. On an air-gapped box with
  no DC reachable it will error; that's expected, skip Section 3 there.
═══════════════════════════════════════════════════════════════════════════*/

SET NOCOUNT ON;

/*───────────────────────────────────────────────────────────────────────────
  1) DIRECT sysadmin members
───────────────────────────────────────────────────────────────────────────*/
PRINT '=== 1. sysadmin role members ===';
SELECT sp.name,
       sp.type_desc,                    -- SQL_LOGIN / WINDOWS_LOGIN / WINDOWS_GROUP
       sp.is_disabled,
       sp.create_date,
       LOGINPROPERTY(sp.name,'PasswordLastSetTime') AS pwd_last_set
FROM   sys.server_role_members rm
JOIN   sys.server_principals sp ON sp.principal_id = rm.member_principal_id
JOIN   sys.server_principals r  ON r.principal_id  = rm.role_principal_id
WHERE  r.name = 'sysadmin'
ORDER BY sp.type_desc, sp.name;

/*───────────────────────────────────────────────────────────────────────────
  2) sysadmin-EQUIVALENT rights (the back doors people forget)
     - CONTROL SERVER  = effectively sysadmin
     - securityadmin   = can grant itself sysadmin, so treat as equivalent
───────────────────────────────────────────────────────────────────────────*/
PRINT '=== 2. sysadmin-equivalent (CONTROL SERVER / securityadmin) ===';
SELECT pr.name, pr.type_desc, 'CONTROL SERVER' AS how, pr.is_disabled
FROM   sys.server_permissions pe
JOIN   sys.server_principals  pr ON pr.principal_id = pe.grantee_principal_id
WHERE  pe.permission_name = 'CONTROL SERVER'
       AND pe.state_desc = 'GRANT'
UNION ALL
SELECT sp.name, sp.type_desc, 'securityadmin' AS how, sp.is_disabled
FROM   sys.server_role_members rm
JOIN   sys.server_principals sp ON sp.principal_id = rm.member_principal_id
JOIN   sys.server_principals r  ON r.principal_id  = rm.role_principal_id
WHERE  r.name = 'securityadmin'
ORDER BY how, name;

/*───────────────────────────────────────────────────────────────────────────
  3) EXPAND Windows GROUPS that hold sysadmin — the real human count
     A group in sysadmin means every member is a de facto sysadmin.
───────────────────────────────────────────────────────────────────────────*/
PRINT '=== 3. Expanded members of Windows groups in sysadmin ===';
IF OBJECT_ID('tempdb..#grp') IS NOT NULL DROP TABLE #grp;
CREATE TABLE #grp (grp SYSNAME);

INSERT #grp (grp)
SELECT sp.name
FROM   sys.server_role_members rm
JOIN   sys.server_principals sp ON sp.principal_id = rm.member_principal_id
JOIN   sys.server_principals r  ON r.principal_id  = rm.role_principal_id
WHERE  r.name = 'sysadmin' AND sp.type_desc = 'WINDOWS_GROUP';

IF NOT EXISTS (SELECT 1 FROM #grp)
    PRINT '   (no Windows groups directly in sysadmin)';
ELSE
BEGIN
    IF OBJECT_ID('tempdb..#members') IS NOT NULL DROP TABLE #members;
    CREATE TABLE #members (
        account_name SYSNAME NULL, acct_type SYSNAME NULL,
        privilege SYSNAME NULL, mapped_login SYSNAME NULL,
        permission_path SYSNAME NULL, via_group SYSNAME NULL);

    DECLARE @g SYSNAME;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT grp FROM #grp;
    OPEN c; FETCH NEXT FROM c INTO @g;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            INSERT #members (account_name, acct_type, privilege, mapped_login, permission_path)
            EXEC xp_logininfo @g, 'members';
            UPDATE #members SET via_group = @g WHERE via_group IS NULL;
        END TRY
        BEGIN CATCH
            PRINT '   xp_logininfo failed for ' + @g + ' : ' + ERROR_MESSAGE();
        END CATCH
        FETCH NEXT FROM c INTO @g;
    END
    CLOSE c; DEALLOCATE c;

    SELECT via_group, account_name, acct_type, privilege, permission_path
    FROM   #members ORDER BY via_group, account_name;
END

/*───────────────────────────────────────────────────────────────────────────
  4) Is 'sa' still enabled? (and is it still named 'sa'?)
───────────────────────────────────────────────────────────────────────────*/
PRINT '=== 4. sa account status ===';
SELECT name AS login_name,          -- name may differ if already renamed
       is_disabled,
       LOGINPROPERTY(name,'PasswordLastSetTime') AS pwd_last_set,
       LOGINPROPERTY(name,'IsExpired')  AS is_expired,
       LOGINPROPERTY(name,'IsLocked')   AS is_locked
FROM   sys.server_principals
WHERE  sid = 0x01;                  -- sa always has sid 0x01 regardless of name

/*───────────────────────────────────────────────────────────────────────────
  5) LOGIN HISTORY
     Reality check: SQL Server does NOT keep durable per-login "last login"
     natively. Three angles below, weakest-but-live to strongest-but-must-be-
     set-up-in-advance.
───────────────────────────────────────────────────────────────────────────*/

-- 5a) LIVE sessions only — who is connected right now (not history)
PRINT '=== 5a. Currently-connected logins (live, not history) ===';
SELECT s.login_name,
       s.host_name,
       s.program_name,
       COUNT(*)          AS sessions,
       MIN(s.login_time) AS earliest_login,
       MAX(s.login_time) AS latest_login
FROM   sys.dm_exec_sessions s
WHERE  s.is_user_process = 1
GROUP BY s.login_name, s.host_name, s.program_name
ORDER BY latest_login DESC;

-- 5b) ERROR LOG scrape — actual login events over time.
--     ONLY populated if Login Auditing = "Both failed and successful logins"
--     (SSMS > Server > Properties > Security). Default logs FAILED only.
--     Reads current log (0). Bump the first arg for archived logs (1,2,...).
PRINT '=== 5b. Login events from the error log ===';
IF OBJECT_ID('tempdb..#errlog') IS NOT NULL DROP TABLE #errlog;
CREATE TABLE #errlog (LogDate DATETIME, ProcessInfo NVARCHAR(50), Text NVARCHAR(4000));
BEGIN TRY
    INSERT #errlog EXEC xp_readerrorlog 0, 1, N'Login';   -- current SQL error log, filter 'Login'
    SELECT LogDate, ProcessInfo, Text
    FROM   #errlog
    WHERE  Text LIKE '%Login succeeded%' OR Text LIKE '%Login failed%'
    ORDER BY LogDate DESC;
END TRY
BEGIN CATCH
    PRINT '   Could not read error log: ' + ERROR_MESSAGE();
END CATCH

/*
-- 5c) DURABLE history — the RIGHT way, but must be enabled BEFORE the fact.
--     Pick ONE and stand it up now so future audits have real data:
--
--   Option A — SQL Server Audit (recommended, low overhead):
--     CREATE SERVER AUDIT Login_Audit TO FILE (FILEPATH = 'X:\Audit\');
--     ALTER SERVER AUDIT Login_Audit WITH (STATE = ON);
--     CREATE SERVER AUDIT SPECIFICATION Login_Spec
--       FOR SERVER AUDIT Login_Audit
--       ADD (SUCCESSFUL_LOGIN_GROUP), ADD (FAILED_LOGIN_GROUP)
--       WITH (STATE = ON);
--     -- read back with sys.fn_get_audit_file('X:\Audit\*',NULL,NULL)
--
--   Option B — Logon trigger writing to a table (more control, more risk;
--     a bad trigger can lock everyone out — test carefully).
*/
