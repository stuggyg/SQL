$Config = "C:\SQL2022\Config.ini"
$Setup  = "D:\Setup.exe"

Write-Host "=== Pre-Check ==="

# Enable Instant File Initialization
$EngineAccount = "DOMAIN\SQL_Engine"
secedit /export /cfg C:\secpol.cfg
(Get-Content C:\secpol.cfg).Replace("SeManageVolumePrivilege =","SeManageVolumePrivilege = *$EngineAccount") | Set-Content C:\secpol.cfg
secedit /configure /db secedit.sdb /cfg C:\secpol.cfg /areas USER_RIGHTS

Write-Host "=== Installing SQL Server 2022 ==="
Start-Process -FilePath $Setup -ArgumentList "/ConfigurationFile=$Config" -Wait -NoNewWindow

Write-Host "=== Post-Install Configuration ==="

# Enable TCP + Named Pipes
Import-Module SQLPS -DisableNameChecking
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQLSERVER\MSSQLServer\SuperSocketNetLib\Tcp" Enabled 1
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQLSERVER\MSSQLServer\SuperSocketNetLib\Np" Enabled 1

# Start Browser + Agent
Set-Service SQLBrowser -StartupType Automatic
Start-Service SQLBrowser
Set-Service SQLSERVERAGENT -StartupType Automatic
Start-Service SQLSERVERAGENT

# Apply instance settings
Invoke-Sqlcmd -Query "
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'max degree of parallelism', 4;
EXEC sp_configure 'cost threshold for parallelism', 40;
EXEC sp_configure 'optimize for ad hoc workloads', 1;
EXEC sp_configure 'backup compression default', 1;
EXEC sp_configure 'max server memory', 12288;
RECONFIGURE;
"

Write-Host "=== Post-Check Complete ==="
