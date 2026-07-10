<#
================================================================================
 Install-Sql2022-AirGapped.ps1
--------------------------------------------------------------------------------
 PURPOSE  Drive the unattended, air-gapped SQL Server 2022 install from your
          ConfigurationFile.ini. Validates the environment first, then runs
          setup.exe silently and interprets the result.

 WHY A WRAPPER  A fresh target VM won't have dbatools yet, and this runs before
          anything else. It also enforces the air-gap gotchas as hard pre-flight
          gates: AZUREEXTENSION must be absent, the CU slipstream folder must
          exist, .NET must be present, and the target won't hang waiting on the
          internet.

 SAFETY   -WhatIf prints the resolved command (passwords masked) and runs
          nothing. Passwords are NEVER written to the .ini or the transcript —
          they're collected as SecureString and passed only at runtime. Prefer
          gMSA service accounts (names ending in "$") and you'll get no password
          prompt at all.

 USAGE
   # See what it would do:
   .\Install-Sql2022-AirGapped.ps1 -Media 'D:\SQL2022.iso' `
        -ConfigFile 'C:\Staging\ConfigurationFile.ini' -WhatIf

   # Do it:
   .\Install-Sql2022-AirGapped.ps1 -Media 'D:\SQL2022.iso' `
        -ConfigFile 'C:\Staging\ConfigurationFile.ini'

 PARAMS
   -Media       Path to the SQL 2022 .iso (auto-mounted) OR a folder/setup.exe.
   -ConfigFile  Path to your ConfigurationFile.ini.
   -WhatIf      Validate + print only. No install.
   -SkipChecks  Escape hatch to bypass pre-flight (not recommended).
================================================================================
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Media,
    [Parameter(Mandatory)][string]$ConfigFile,
    [switch]$WhatIf,
    [switch]$SkipChecks
)

$ErrorActionPreference = 'Stop'
$fail = $false
function Ok  ($m){ Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Bad ($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:fail = $true }
function Warn($m){ Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Head($m){ Write-Host "`n$m" -ForegroundColor Cyan }

# --- tiny INI parser (returns hashtable of [OPTIONS] key=value, cleaned) ------
function Read-IniOptions([string]$path){
    $h = @{}
    foreach($line in Get-Content -LiteralPath $path){
        $t = $line.Trim()
        if($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('[')){ continue }
        $kv = $t -split '=', 2
        if($kv.Count -eq 2){
            $k = $kv[0].Trim()
            $v = ($kv[1].Trim()) -replace '^"','' -replace '"$',''
            $h[$k] = $v
        }
    }
    return $h
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " SQL Server 2022 air-gapped install driver" -ForegroundColor Cyan
Write-Host " $(Get-Date -Format s)  on  $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# ============================================================================
#  RESOLVE MEDIA  (mount .iso if needed, find setup.exe)
# ============================================================================
$mountedImage = $null
$setupExe = $null
try {
    if($Media -match '\.iso$'){
        Head "Mounting media"
        $mountedImage = Mount-DiskImage -ImagePath $Media -PassThru
        $drive = ($mountedImage | Get-Volume).DriveLetter
        $setupExe = "$drive`:\setup.exe"
        Ok "Mounted $Media at $drive:"
    }
    elseif($Media -match 'setup\.exe$'){ $setupExe = $Media }
    else { $setupExe = Join-Path $Media 'setup.exe' }
}
catch { Bad "Could not mount / resolve media: $($_.Exception.Message)" }

# ============================================================================
#  PRE-FLIGHT
# ============================================================================
Head "Pre-flight checks"

# elevation
$admin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if($admin){ Ok "Running elevated (Administrator)" } else { Bad "Not elevated — re-run PowerShell as Administrator" }

# setup.exe
if($setupExe -and (Test-Path $setupExe)){ Ok "setup.exe found: $setupExe" } else { Bad "setup.exe not found at: $setupExe" }

# config file
if(Test-Path $ConfigFile){ Ok "ConfigurationFile.ini found: $ConfigFile" } else { Bad "ConfigurationFile.ini not found: $ConfigFile" }

$ini = @{}
if(Test-Path $ConfigFile){ $ini = Read-IniOptions $ConfigFile }

# ACTION
if($ini['ACTION'] -eq 'Install'){ Ok "ACTION = Install" } else { Bad "ACTION is '$($ini['ACTION'])' (expected Install)" }

# --- THE air-gap gate: AZUREEXTENSION must NOT be in FEATURES ---
$features = $ini['FEATURES']
if($features -and $features -notmatch 'AZUREEXTENSION'){ Ok "FEATURES excludes AZUREEXTENSION ($features)" }
else { Bad "AZUREEXTENSION present in FEATURES — this WILL hang with no internet. Remove it." }

# --- CU slipstream folder (if UpdateEnabled) ---
if($ini['UpdateEnabled'] -match 'True'){
    $src = $ini['UpdateSource']
    # resolve relative UpdateSource against the config file's own folder
    if($src -and -not [System.IO.Path]::IsPathRooted($src)){
        $src = Join-Path (Split-Path $ConfigFile -Parent) ($src -replace '^\.\\','')
    }
    if($src -and (Test-Path $src) -and (Get-ChildItem $src -Filter *.exe -ErrorAction SilentlyContinue)){
        Ok "CU slipstream folder present with an .exe: $src"
    } else {
        Bad "UpdateEnabled=True but no CU .exe found under UpdateSource: $src"
    }
} else { Warn "UpdateEnabled not True — installing RTM with no CU slipstream. Confirm that's intended." }

# --- .NET 4.7.2+ (Release >= 461808) ---
try {
    $rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release
    if($rel -ge 461808){ Ok ".NET Framework 4.7.2+ present (Release $rel)" } else { Bad ".NET too old (Release $rel) — install 4.7.2+ offline first" }
} catch { Bad ".NET 4.x not detected — install 4.7.2+ offline first" }

# --- instance not already installed ---
$inst = if($ini['INSTANCENAME']){ $ini['INSTANCENAME'] } else { 'MSSQLSERVER' }
$svc  = if($inst -eq 'MSSQLSERVER'){ 'MSSQLSERVER' } else { "MSSQL`$$inst" }
if(Get-Service -Name $svc -ErrorAction SilentlyContinue){ Bad "Instance '$inst' already installed (service $svc exists)" }
else { Ok "Instance '$inst' not yet present — clear to install" }

# --- target directories exist ---
foreach($d in 'INSTALLSQLDATADIR','SQLUSERDBDIR','SQLUSERDBLOGDIR','SQLTEMPDBDIR','SQLBACKUPDIR'){
    if($ini[$d]){
        if(Test-Path $ini[$d]){ Ok "$d exists: $($ini[$d])" }
        else { Warn "$d does not exist yet: $($ini[$d]) — setup can create it, but confirm the volume is mounted" }
    }
}

# --- collation sanity (must match source; we can only confirm it's set) ---
if($ini['SQLCOLLATION']){ Ok "SQLCOLLATION set: $($ini['SQLCOLLATION']) — confirm it matches SOURCE exactly" }
else { Bad "SQLCOLLATION not set — you'll get the OS default, risking collation conflicts on restore" }

if($fail -and -not $SkipChecks){
    Head "Pre-flight FAILED. Fix the items above (or -SkipChecks to override). Nothing installed."
    if($mountedImage){ Dismount-DiskImage -ImagePath $Media | Out-Null }
    return
}

# ============================================================================
#  SERVICE-ACCOUNT PASSWORDS  (runtime only — never stored)
# ============================================================================
$secretArgs = @()
function Add-PwdArg($acctKey, $argName){
    $acct = $ini[$acctKey]
    if(-not $acct){ return }
    if($acct.TrimEnd().EndsWith('$')){ Ok "$acctKey looks like a gMSA ($acct) — no password needed"; return }
    if($WhatIf){ Warn "$acctKey ($acct) would prompt for a password at real run"; return }
    $sec = Read-Host "Password for $acctKey ($acct)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $script:secretArgs += "/$argName=`"$plain`""
}
Head "Service account credentials"
Add-PwdArg 'SQLSVCACCOUNT' 'SQLSVCPASSWORD'
Add-PwdArg 'AGTSVCACCOUNT' 'AGTSVCPASSWORD'
if($ini['SECURITYMODE'] -eq 'SQL' -and -not $WhatIf){
    $sa = Read-Host "SA password (mixed mode)" -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sa)
    $secretArgs += "/SAPWD=`"$([Runtime.InteropServices.Marshal]::PtrToStringAuto($b))`""
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
}

# ============================================================================
#  BUILD + RUN
# ============================================================================
$baseArgs = @("/ConfigurationFile=`"$ConfigFile`"", "/IACCEPTSQLSERVERLICENSETERMS")
$allArgs  = $baseArgs + $secretArgs

Head "Install command (passwords masked)"
$masked = ($baseArgs + ($secretArgs | ForEach-Object { ($_ -split '=')[0] + '=********' }))
Write-Host "  `"$setupExe`" $($masked -join ' ')" -ForegroundColor Gray

if($WhatIf){
    Head "WhatIf: validation passed, nothing installed. Remove -WhatIf to run for real."
    if($mountedImage){ Dismount-DiskImage -ImagePath $Media | Out-Null }
    return
}

Head "Launching setup (silent — this takes several minutes)..."
$proc = Start-Process -FilePath $setupExe -ArgumentList $allArgs -Wait -PassThru -NoNewWindow
$code = $proc.ExitCode

# ============================================================================
#  RESULT
# ============================================================================
$logDir = "$env:ProgramFiles\Microsoft SQL Server\160\Setup Bootstrap\Log"
$summary = Join-Path $logDir 'Summary.txt'

Head "Result"
switch($code){
    0     { Ok    "Install SUCCEEDED (exit 0)" }
    3010  { Warn  "Install succeeded but a REBOOT is required (exit 3010)" }
    default { Bad "Install FAILED (exit $code)" }
}
if(Test-Path $summary){ Write-Host "  Setup summary log: $summary" -ForegroundColor Gray }

if($code -in 0,3010){
    Write-Host "`n  Next: run 02_Apply_Target_Config.sql (dry-run first) once you've validated" -ForegroundColor Gray
    Write-Host "  the build with SELECT @@VERSION;  Expect the slipstreamed CU level." -ForegroundColor Gray
}

if($mountedImage){ Dismount-DiskImage -ImagePath $Media | Out-Null; Ok "Media dismounted" }
exit $code
