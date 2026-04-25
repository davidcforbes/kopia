# check_backup_errors.ps1 - Check current Kopia run for real errors
param([string]$LogFile)

$lines = Get-Content -Path $LogFile
$startIdx = 0
for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if ($lines[$i] -match 'Daily Kopia backup start') {
        $startIdx = $i
        break
    }
}

$runLines = $lines[$startIdx..($lines.Count - 1)]
$errors = $runLines | Where-Object { $_ -match 'error' } |
    Where-Object { $_ -notmatch 'Ignored error|Ignored \d+ error|errors[=:.]|possible stall|WARNING:|0 errors|ERROR:|error handling' }

Write-Output $errors.Count
