<#
═══════════════════════════════════════════════════════════════════════════
  SQL Server 2022 — Engine Settings Copy & Verify (dbatools)
  ---------------------------------------------------------------------------
  Reads settings from the SOURCE 2016 instance and applies them to the new
  TARGET 2022 instance, so you don't hand-copy values across all 10 VMs.

  Companion to SQL2022_Engine_Config.sql. Same intent, automated.

  REQUIREMENTS
    - dbatools module (Install-Module dbatools). AIR-GAP: on a connected box
      run  Save-Module dbatools -Path .\  then carry the folder in on media
      and drop it in a $env:PSModulePath location on the target/jump host.
    - Run from a management host that can reach BOTH instances (or run the
      capture on source, carry the CSV in, then run the apply on target).
    - An account with sysadmin on both instances (Windows auth assumed).

  NOTHING here restarts the service. Items that need a restart are called out.
═══════════════════════════════════════════════════════════════════════════
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $Source,          # e.g. SQL-OLD-01
    [Parameter(Mandatory)] [string] $Target,          # e.g. SQL-NEW-01
    [int]    $OverrideMaxMemoryMB,                     # optional: force a value instead of copying source
    [int]    $OverrideMaxDop,                          # optional
    [int]    $OverrideCostThreshold = 50,             # source 2016 default is often 5 — usually override
    [switch] $Apply                                    # omit for a dry run (report only)
)

$ErrorActionPreference = 'Stop'
Import-Module dbatools

# Settings we care about (dbatools config names)
$settings = @(
    'MaxServerMemory','MinServerMemory','MaxDop','CostThresholdForParallelism',
    'OptimizeAdhocWorkloads','DefaultBackupCompression','RemoteDacConnectionsEnabled',
    'RemoteLoginTimeout','RemoteQueryTimeout','XPCmdShellEnabled',
    'AdHocDistributedQueriesEnabled','ClrStrictSecurity','ContainedDatabaseAuthentication'
)

Write-Host "`n== Reading SOURCE ($Source) ==" -ForegroundColor Cyan
$src = Get-DbaSpConfigure -SqlInstance $Source |
       Where-Object { $_.Name -in $settings } |
       Select-Object Name, ConfiguredValue, RunningValue

$src | Format-Table -AutoSize

Write-Host "== Reading TARGET ($Target) ==" -ForegroundColor Cyan
$tgt = Get-DbaSpConfigure -SqlInstance $Target |
       Where-Object { $_.Name -in $settings } |
       Select-Object Name, ConfiguredValue, RunningValue

# Build a diff table so you can see what will change before committing
$plan = foreach ($s in $src) {
    $desired = switch ($s.Name) {
        'MaxServerMemory'             { if ($OverrideMaxMemoryMB)  { $OverrideMaxMemoryMB }  else { $s.ConfiguredValue } }
        'MaxDop'                      { if ($OverrideMaxDop)       { $OverrideMaxDop }       else { $s.ConfiguredValue } }
        'CostThresholdForParallelism' { if ($OverrideCostThreshold){ $OverrideCostThreshold} else { $s.ConfiguredValue } }
        # security posture: enforce safe values regardless of source
        'XPCmdShellEnabled'                 { 0 }
        'AdHocDistributedQueriesEnabled'    { 0 }
        'ClrStrictSecurity'                 { 1 }
        'OptimizeAdhocWorkloads'            { 1 }
        'DefaultBackupCompression'          { 1 }
        'RemoteDacConnectionsEnabled'       { 1 }
        default                             { $s.ConfiguredValue }
    }
    $current = ($tgt | Where-Object Name -eq $s.Name).ConfiguredValue
    [pscustomobject]@{
        Setting = $s.Name
        Source  = $s.ConfiguredValue
        Target  = $current
        Desired = $desired
        Change  = if ($current -ne $desired) { 'YES' } else { '' }
    }
}

Write-Host "`n== PLAN (source → target) ==" -ForegroundColor Yellow
$plan | Format-Table -AutoSize

# Sanity guard: never let MaxServerMemory land on the unlimited default
$mem = $plan | Where-Object Setting -eq 'MaxServerMemory'
if ($mem.Desired -ge 2147483647) {
    throw "MaxServerMemory would be unlimited. Pass -OverrideMaxMemoryMB with a real value (reserve 10% or 4GB for the OS)."
}
if (($plan | Where-Object Setting -eq 'MaxDop').Desired -eq 0) {
    Write-Warning "MaxDop resolves to 0 (unlimited). Confirm this is intended on a multi-core server."
}

if (-not $Apply) {
    Write-Host "`nDry run only. Re-run with -Apply to commit the 'Desired' values." -ForegroundColor Green
    return
}

Write-Host "`n== APPLYING to $Target ==" -ForegroundColor Cyan
foreach ($row in ($plan | Where-Object Change -eq 'YES')) {
    if ($PSCmdlet.ShouldProcess($Target, "Set $($row.Setting) = $($row.Desired)")) {
        Set-DbaSpConfigure -SqlInstance $Target -Name $row.Setting -Value $row.Desired | Out-Null
        Write-Host ("  {0,-32} {1} → {2}" -f $row.Setting, $row.Target, $row.Desired)
    }
}

Write-Host "`n== VERIFY ($Target) ==" -ForegroundColor Cyan
Get-DbaSpConfigure -SqlInstance $Target |
    Where-Object { $_.Name -in $settings } |
    Select-Object Name, ConfiguredValue, RunningValue |
    Format-Table -AutoSize

# Collation + build parity (not sp_configure, but you want them checked)
$sColl = (Connect-DbaInstance $Source).Collation
$tColl = (Connect-DbaInstance $Target).Collation
Write-Host ("Collation  source={0}  target={1}  {2}" -f $sColl, $tColl,
    ($(if ($sColl -eq $tColl){'MATCH'}else{'*** MISMATCH ***'}))) -ForegroundColor $(if($sColl -eq $tColl){'Green'}else{'Red'})

Write-Host @"

--- STILL MANUAL (not sp_configure) -------------------------------------
  [RESTART] Lock Pages in Memory        grant to SQL service account
  Instant File Init                     'Perform volume maintenance tasks'
  Power Plan                            High Performance
  AV exclusions                         .mdf .ndf .ldf .bak .trn + binaries
  tempdb                                1 file/core (max 8), equal size
  Trace flags / startup params          re-add on target
  Named Pipes off / static TCP port     Configuration Manager
-------------------------------------------------------------------------
Note: RunningValue lags ConfiguredValue for restart-only settings until the
service is bounced. Fold that restart into the cutover window.
"@ -ForegroundColor DarkGray
