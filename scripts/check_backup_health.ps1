# check_backup_health.ps1 — Verify last daily Kopia backup run, post toast.
#
# Reads the most recent "Daily Kopia backup start" section of the log and
# evaluates six health checks targeting the fixes deployed 2026-04-25
# (DPAPI password loader, VSS policy, VHDX mount-letter fallback). Posts a
# Windows toast notification with PASS/FAIL summary and writes a flag file
# on FAIL so other tooling can pick it up.
#
# Designed for PowerShell 5.1 (powershell.exe) — uses WinRT toast APIs which
# are not available in PowerShell 7 (pwsh.exe).

param(
    [string]$LogFile      = 'C:\dev\kopia\logs\daily_kopia.log',
    [string]$FlagFile     = 'C:\dev\kopia\logs\BACKUP_HEALTH_FAIL.flag',
    [string]$AppId        = 'KopiaBackup.HealthCheck',
    [string]$LaunchProto  = 'kopiamonitor:open'
)

$ErrorActionPreference = 'Stop'

function Show-Toast {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Body,
        [Parameter(Mandatory)] [string]$AppId,
        [string]$LaunchProto
    )
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,        ContentType=WindowsRuntime]

    # Use ToastGeneric so we can set launch=... activationType=protocol on
    # the root <toast> element AND add an explicit "Open" action button.
    # Encode XML-special chars in body/title.
    $enc = { param($s) [System.Security.SecurityElement]::Escape($s) }
    $titleX = & $enc $Title
    $bodyX  = & $enc $Body
    $launch = & $enc $LaunchProto

    $xml = @"
<toast launch="$launch" activationType="protocol">
  <visual>
    <binding template="ToastGeneric">
      <text>$titleX</text>
      <text>$bodyX</text>
    </binding>
  </visual>
  <actions>
    <action content="Open Backup Monitor" activationType="protocol" arguments="$launch" />
  </actions>
</toast>
"@

    $doc = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $doc.LoadXml($xml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
}

if (-not (Test-Path -LiteralPath $LogFile)) {
    Show-Toast -Title 'Kopia Backup: UNKNOWN' -Body "Log not found: $LogFile" -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | Log not found: $LogFile" | Set-Content -LiteralPath $FlagFile
    exit 2
}

$lines = Get-Content -LiteralPath $LogFile
$startIdx = -1
for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i] -match 'Daily Kopia backup start') { $startIdx = $i; break }
}
if ($startIdx -lt 0) {
    Show-Toast -Title 'Kopia Backup: UNKNOWN' -Body 'No "Daily Kopia backup start" marker in log.' -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | No start marker in log" | Set-Content -LiteralPath $FlagFile
    exit 2
}
$run = $lines[$startIdx..($lines.Count - 1)] -join "`n"

# Pull the timestamp from the start line for the toast body.
$startLine = $lines[$startIdx]
$runWhen = if ($startLine -match '^(.+?)\s+—\s+Daily Kopia backup start') { $matches[1].Trim() } else { '?' }

# Per-fix checks (targeting the four issues fixed 2026-04-25).
$vssShadowCount = ([regex]::Matches($run, 'creating volume shadow copy of')).Count
$checks = [ordered]@{
    'DPAPI password load (no handle-invalid)' = -not ($run -match 'password prompt error: The handle is invalid')
    'No FATAL repo status'                    = -not ($run -match 'FATAL: repo status failed')
    'VSS not blocked by UAC'                  = -not ($run -match 'do not have Administrators group privileges')
    'VSS shadow copy created on both sources' = ($vssShadowCount -ge 2)
    'VHDX indexer mounted (no drive-letter)'  = -not ($run -match 'Mount-DiskImage reported no drive letters')
    'Run completed cleanly'                   = ($run -match 'errors=0' -or $run -match 'No errors detected')
}

$failed = @()
foreach ($k in $checks.Keys) { if (-not $checks[$k]) { $failed += $k } }

if ($failed.Count -eq 0) {
    if (Test-Path -LiteralPath $FlagFile) { Remove-Item -LiteralPath $FlagFile -Force }
    Show-Toast -Title "Kopia Backup: PASS ($runWhen)" `
               -Body  "All $($checks.Count) health checks passed." `
               -AppId $AppId -LaunchProto $LaunchProto
    exit 0
} else {
    $body = "Failed $($failed.Count)/$($checks.Count): " + ($failed -join '; ')
    Show-Toast -Title "Kopia Backup: FAIL ($runWhen)" -Body $body -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | $body" | Set-Content -LiteralPath $FlagFile
    exit 1
}
