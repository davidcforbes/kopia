# zombie_reaper.ps1 -- Detect a prior backup run that never wrote a
# "Daily Kopia backup complete" line and append a synthetic FATAL so
# the Backup Monitor parser does not show a dangling "Running" row.
#
# Usage: zombie_reaper.ps1 -LogFile <path>

param(
    [Parameter(Mandatory=$true)] [string]$LogFile
)

if (-not (Test-Path -LiteralPath $LogFile)) { exit 0 }

$lines = Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue
if (-not $lines -or $lines.Count -eq 0) { exit 0 }

# Find the last "backup start" and last "backup complete"
$lastStart = -1
$lastComplete = -1
for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lastStart -lt 0 -and $lines[$i] -match 'Daily Kopia backup start') { $lastStart = $i }
    if ($lastComplete -lt 0 -and $lines[$i] -match 'Daily Kopia backup complete') { $lastComplete = $i }
    if ($lastStart -ge 0 -and $lastComplete -ge 0) { break }
}

# Also treat any FATAL closure as a valid end, since those are delimited by "========"
$lastFatal = -1
for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i] -match 'FATAL:') { $lastFatal = $i; break }
}

# A zombie = last start exists, and no complete/FATAL after it
$endMarker = [Math]::Max($lastComplete, $lastFatal)
if ($lastStart -ge 0 -and $lastStart -gt $endMarker) {
    $ts = Get-Date -Format 'ddd MM/dd/yyyy  HH:mm:ss.ff'
    Add-Content -LiteralPath $LogFile -Value "$ts - FATAL: previous run at line $($lastStart+1) never completed (zombie reaped)"
    Add-Content -LiteralPath $LogFile -Value "========================================"
    Write-Output "reaped"
    exit 0
}

Write-Output "clean"
exit 0
