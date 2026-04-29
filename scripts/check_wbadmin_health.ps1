# check_wbadmin_health.ps1 - Verify the most recent wbadmin backup is fresh,
# post a Windows toast PASS/STALE/FAIL.
#
# Strategy: wbadmin get versions only lists *completed* backups. If the
# newest one is <FreshHours old, we consider the backup healthy. Beyond
# that we degrade to STALE then FAIL. We also peek the Microsoft-Windows-
# Backup event log for failure events since the newest completed version,
# which catches the case where last night's run started but never finished.
#
# Designed for PowerShell 5.1 (powershell.exe) - uses WinRT toast APIs.

param(
    [string]$FlagFile    = 'C:\dev\kopia\logs\WBADMIN_HEALTH_FAIL.flag',
    [string]$AppId       = 'KopiaBackup.HealthCheck',
    [string]$LaunchProto = 'kopiamonitor:open',
    [int]   $FreshHours  = 26,
    [int]   $StaleHours  = 72
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

# Run wbadmin and capture stdout. wbadmin reports versions in human-readable
# blocks separated by blank lines, with a "Backup time: <date>" header.
$wbadmin = Join-Path $env:WINDIR 'System32\wbadmin.exe'
if (-not (Test-Path -LiteralPath $wbadmin)) {
    Show-Toast -Title 'Wbadmin Backup: UNKNOWN' -Body 'wbadmin.exe not found (Windows Server Backup feature missing).' -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | wbadmin.exe missing" | Set-Content -LiteralPath $FlagFile
    exit 2
}

try {
    $output = & $wbadmin get versions 2>&1 | Out-String
} catch {
    Show-Toast -Title 'Wbadmin Backup: UNKNOWN' -Body "wbadmin failed: $($_.Exception.Message)" -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | wbadmin invoke error: $($_.Exception.Message)" | Set-Content -LiteralPath $FlagFile
    exit 2
}

# Parse all "Backup time: ..." lines and pick the newest. The format depends
# on locale; rely on Get-Date which understands the user's culture.
$timeMatches = [regex]::Matches($output, '(?im)^\s*Backup time:\s*(.+)$')
if ($timeMatches.Count -eq 0) {
    Show-Toast -Title 'Wbadmin Backup: NONE' `
               -Body  'No completed wbadmin backups found. Run wbadmin to take an initial backup.' `
               -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | wbadmin reports zero versions" | Set-Content -LiteralPath $FlagFile
    exit 1
}

$newest = [DateTime]::MinValue
foreach ($m in $timeMatches) {
    $raw = $m.Groups[1].Value.Trim()
    try {
        $dt = [DateTime]::Parse($raw)
        if ($dt -gt $newest) { $newest = $dt }
    } catch {
        # Skip unparseable timestamps; do not abort the whole check.
    }
}

if ($newest -eq [DateTime]::MinValue) {
    Show-Toast -Title 'Wbadmin Backup: UNKNOWN' `
               -Body  'wbadmin output had Backup time lines but none were parseable.' `
               -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | wbadmin times unparseable" | Set-Content -LiteralPath $FlagFile
    exit 2
}

$age      = (Get-Date) - $newest
$ageHours = [int][Math]::Round($age.TotalHours)
$newestS  = $newest.ToString('yyyy-MM-dd HH:mm')

# Look for backup-failure events since the newest completed version. If
# wbadmin started another run after $newest and failed, the failure event
# would be more recent than the newest completed version.
$failedSinceNewest = $false
try {
    $failedSinceNewest = $null -ne (
        Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-Backup'
            Level     = 1, 2  # Critical, Error
            StartTime = $newest
        } -MaxEvents 1 -ErrorAction Stop
    )
} catch {
    # Log channel may be empty or inaccessible - not fatal.
    $failedSinceNewest = $false
}

if ($age.TotalHours -le $FreshHours -and -not $failedSinceNewest) {
    if (Test-Path -LiteralPath $FlagFile) { Remove-Item -LiteralPath $FlagFile -Force }
    Show-Toast -Title "Wbadmin Backup: PASS" `
               -Body  "Last backup $newestS ($ageHours h ago)" `
               -AppId $AppId -LaunchProto $LaunchProto
    exit 0
}

if ($failedSinceNewest) {
    Show-Toast -Title "Wbadmin Backup: FAIL" `
               -Body  "Failure event since $newestS - check Event Viewer / Microsoft-Windows-Backup." `
               -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | wbadmin failure event since $newestS" | Set-Content -LiteralPath $FlagFile
    exit 1
}

if ($age.TotalHours -le $StaleHours) {
    Show-Toast -Title "Wbadmin Backup: STALE" `
               -Body  "Last backup $newestS ($ageHours h ago) - exceeded $FreshHours h freshness." `
               -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | wbadmin stale ($ageHours h since $newestS)" | Set-Content -LiteralPath $FlagFile
    exit 1
}

Show-Toast -Title "Wbadmin Backup: FAIL" `
           -Body  "Last backup $newestS ($ageHours h ago) - exceeds $StaleHours h." `
           -AppId $AppId -LaunchProto $LaunchProto
"$(Get-Date -Format s) | wbadmin too old ($ageHours h since $newestS)" | Set-Content -LiteralPath $FlagFile
exit 1
