# kopia_errors.ps1 — Parse Kopia snapshot log for file errors
param([string]$LogFile)

$lines = Select-String -Path $LogFile -Pattern '"error":"(?!null)' |
    Where-Object { $_.Line -match '"path":"(.+?)"' }

$paths = $lines | ForEach-Object {
    if ($_.Line -match '"path":"(.+?)"') { $Matches[1] }
}

Write-Host "Total errors: $($paths.Count)"
Write-Host ""

Write-Host "--- Errors by folder ---"
$paths | ForEach-Object {
    $parts = $_ -split '/'
    $depth = [Math]::Min(2, $parts.Length - 2)
    if ($depth -ge 0) { $parts[0..$depth] -join '/' } else { $_ }
} | Group-Object |
    Sort-Object Count -Descending |
    ForEach-Object { '{0,4}  {1}' -f $_.Count, $_.Name }

Write-Host ""
Write-Host "--- Unique error paths ---"
$paths | Sort-Object -Unique
