# check_backup_health.ps1 - Belt-and-suspenders watchdog: confirm that a
# kopia "snapshot summary" line was written to daily_kopia.log in the last
# 24h. Posts a WARN toast if not.
#
# This used to be the *primary* PASS/FAIL channel: a separate 08:00 task
# that grep-parsed daily_kopia.log for the six failure modes deployed
# 2026-04-25 (DPAPI/VSS/VHDX/etc). Those checks were brittle and ran 5h
# after the backup. Today the primary toast is posted *inline* by
# daily_kopia_backup.cmd via post_summary_toast.ps1; this script remains
# only to catch the case where the daily task didn't run at all (machine
# off, task disabled, scheduler glitch).
#
# Designed for PowerShell 5.1 (powershell.exe) - uses WinRT toast APIs.

param(
    [string]$LogFile      = 'C:\dev\kopia\logs\daily_kopia.log',
    [string]$FlagFile     = 'C:\dev\kopia\logs\BACKUP_HEALTH_FAIL.flag',
    [string]$AppId        = 'KopiaBackup.HealthCheck',
    [string]$LaunchProto  = 'kopiamonitor:open',
    [int]   $StaleHours   = 24
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

    $enc    = { param($s) [System.Security.SecurityElement]::Escape($s) }
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
    Show-Toast -Title 'Kopia Backup: NO LOG' -Body "Log not found: $LogFile - daily task has never run on this host." -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | Log not found: $LogFile" | Set-Content -LiteralPath $FlagFile
    exit 1
}

$summaryFound = Select-String -LiteralPath $LogFile -Pattern '^snapshot summary\s+source=' -Quiet
if (-not $summaryFound) {
    Show-Toast -Title 'Kopia Backup: WATCHDOG' `
               -Body  "No 'snapshot summary' line ever found in $LogFile. Either the daily task is broken or kopia.exe lacks the structured-summary patch." `
               -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | No snapshot summary line ever found" | Set-Content -LiteralPath $FlagFile
    exit 1
}

$mtime = (Get-Item -LiteralPath $LogFile).LastWriteTime
$age   = (Get-Date) - $mtime
if ($age.TotalHours -gt $StaleHours) {
    $ageH = [int][Math]::Round($age.TotalHours)
    Show-Toast -Title 'Kopia Backup: WATCHDOG' `
               -Body  "daily_kopia.log untouched for $ageH h (threshold $StaleHours h). Daily task may have skipped a run." `
               -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | daily_kopia.log stale ($ageH h)" | Set-Content -LiteralPath $FlagFile
    exit 1
}

# Healthy: file was touched recently and contains at least one snapshot
# summary line. The inline toast posted by post_summary_toast.ps1 already
# announced PASS/FAIL of the actual run; this watchdog stays silent on
# success to avoid duplicate notifications.
if (Test-Path -LiteralPath $FlagFile) { Remove-Item -LiteralPath $FlagFile -Force }
exit 0
