# post_summary_toast.ps1 - Post a Windows toast right after a backup run.
#
# Reads the most recent "Daily Kopia backup start" section of the log,
# pulls out every "snapshot summary ..." line emitted by `kopia snapshot
# create` (added on master in commit 1f5c6604), aggregates totals across
# sources, and posts one PASS/FAIL toast.
#
# This replaces the old freeform-grep error counter in
# daily_kopia_backup.cmd. It runs *inline* at the end of the daily task,
# so the toast appears within seconds of the backup finishing instead of
# 5 hours later via a separate health-check task.
#
# Designed for PowerShell 5.1 (powershell.exe) - uses WinRT toast APIs.

param(
    [string]$LogFile     = 'C:\dev\kopia\logs\daily_kopia.log',
    [string]$FlagFile    = 'C:\dev\kopia\logs\BACKUP_ERRORS.flag',
    [string]$AppId       = 'KopiaBackup.HealthCheck',
    [string]$LaunchProto = 'kopiamonitor:open'
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

# Parse a single "snapshot summary key=value key2=value2" line into a hashtable.
# Accepts both bare values (foo=bar) and quoted values (foo="bar baz"). The
# inner-content regex skips over backslash-escaped chars so an embedded \"
# does not terminate the value, but we keep the escapes verbatim in the
# returned string - they read fine in a toast and avoid a fragile unescape
# step that previously stripped backslashes from Windows paths.
function Parse-SummaryLine {
    param([Parameter(Mandatory)] [string]$Line)

    $h = @{}
    $entries = [regex]::Matches($Line, '(\w+)=(?:"((?:[^"\\]|\\.)*)"|(\S+))')
    foreach ($m in $entries) {
        $k = $m.Groups[1].Value
        $v = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
        $h[$k] = $v
    }
    return $h
}

function Format-Bytes {
    param([Parameter(Mandatory)] [int64]$N)

    if ($N -ge 1TB) { return ('{0:N1} TB' -f ($N / 1TB)) }
    if ($N -ge 1GB) { return ('{0:N1} GB' -f ($N / 1GB)) }
    if ($N -ge 1MB) { return ('{0:N1} MB' -f ($N / 1MB)) }
    if ($N -ge 1KB) { return ('{0:N1} KB' -f ($N / 1KB)) }
    return "$N B"
}

if (-not (Test-Path -LiteralPath $LogFile)) {
    Show-Toast -Title 'Kopia Backup: UNKNOWN' -Body "Log not found: $LogFile" -AppId $AppId -LaunchProto $LaunchProto
    exit 2
}

$lines = Get-Content -LiteralPath $LogFile

# Locate the most recent "Daily Kopia backup start" marker.
$startIdx = -1
for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i] -match 'Daily Kopia backup start') { $startIdx = $i; break }
}
if ($startIdx -lt 0) {
    Show-Toast -Title 'Kopia Backup: UNKNOWN' -Body 'No "Daily Kopia backup start" marker in log.' -AppId $AppId -LaunchProto $LaunchProto
    exit 2
}

# Pull timestamp from the start line for the toast body. The marker uses
# either an em-dash (legacy log format) or an ASCII hyphen as the separator;
# build the pattern from a char literal so the source file stays ASCII-safe
# under PowerShell 5.1's default codepage.
$startLine = $lines[$startIdx]
$emDash = [char]0x2014
$markerPattern = "^(.+?)\s+($emDash|-)\s+Daily Kopia backup start"
$runWhen = if ($startLine -match $markerPattern) { $matches[1].Trim() } else { '?' }

# Find every structured "snapshot summary" line in this run.
$runLines = $lines[$startIdx..($lines.Count - 1)]
$summaryLines = $runLines | Where-Object { $_ -match 'snapshot summary\s+source=' }

if ($summaryLines.Count -eq 0) {
    # Either kopia ran without the summary patch, or no source completed.
    Show-Toast -Title "Kopia Backup: UNKNOWN ($runWhen)" `
               -Body  'No "snapshot summary" lines found. Either kopia.exe lacks the summary patch (commit 1f5c6604) or no source completed.' `
               -AppId $AppId -LaunchProto $LaunchProto
    "$(Get-Date -Format s) | No snapshot summary lines in last run" | Set-Content -LiteralPath $FlagFile
    exit 2
}

# Aggregate.
$totalErrors        = 0
$totalIgnored       = 0
$totalFiles         = 0L
$totalBytes         = 0L
$failedSources      = New-Object System.Collections.Generic.List[string]
$incompleteSources  = New-Object System.Collections.Generic.List[string]

foreach ($line in $summaryLines) {
    $s = Parse-SummaryLine -Line $line
    $errors  = [int]($s['errors']         | ForEach-Object { if ($_) { $_ } else { 0 } })
    $ignored = [int]($s['ignored_errors'] | ForEach-Object { if ($_) { $_ } else { 0 } })
    $files   = [int64]($s['files']        | ForEach-Object { if ($_) { $_ } else { 0 } })
    $bytes   = [int64]($s['bytes']        | ForEach-Object { if ($_) { $_ } else { 0 } })

    $totalErrors  += $errors
    $totalIgnored += $ignored
    $totalFiles   += $files
    $totalBytes   += $bytes

    if ($errors -gt 0)            { $failedSources.Add("$($s['source']) ($errors)") | Out-Null }
    if ($s['incomplete'] -ne '')  { $incompleteSources.Add($s['source'])             | Out-Null }
}

$sourceCount = $summaryLines.Count
$bytesPretty = Format-Bytes -N $totalBytes

if ($totalErrors -eq 0 -and $incompleteSources.Count -eq 0) {
    if (Test-Path -LiteralPath $FlagFile) { Remove-Item -LiteralPath $FlagFile -Force }
    $body = "$sourceCount source(s), $totalFiles files, $bytesPretty"
    if ($totalIgnored -gt 0) { $body += " ($totalIgnored ignored)" }
    Show-Toast -Title "Kopia Backup: PASS ($runWhen)" -Body $body -AppId $AppId -LaunchProto $LaunchProto
    exit 0
}

$reasons = @()
if ($totalErrors -gt 0)              { $reasons += "$totalErrors error(s) on: $($failedSources -join '; ')" }
if ($incompleteSources.Count -gt 0)  { $reasons += "incomplete: $($incompleteSources -join '; ')" }
$body = $reasons -join ' | '

Show-Toast -Title "Kopia Backup: FAIL ($runWhen)" -Body $body -AppId $AppId -LaunchProto $LaunchProto
"$(Get-Date -Format s) | $body" | Set-Content -LiteralPath $FlagFile
exit 1
