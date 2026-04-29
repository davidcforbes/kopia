# check_branch_drift.ps1 - Detect drift between on-disk scripts/ and the
# personal/automation branch.
#
# scripts/ is gitignored on master (.git/info/exclude line /scripts/),
# so the user can edit on-disk without 'git status' noticing. The
# personal/automation branch tracks these files via 'git add -f' but
# silently lags whenever an on-disk edit is not committed back. On
# 2026-04-29 this caused a deploy to overwrite v2 (190+ lines) with v1
# (80 lines) of daily_kopia_backup.cmd, only recovered via kopia
# snapshot restore.
#
# Run this BEFORE any 'cp -r personal/automation/scripts/. /c/dev/kopia/scripts/'
# style deploy. Exits non-zero if drift exists so a deploy script can gate.

param(
    [string]$RepoRoot     = 'C:\dev\kopia',
    [string]$Branch       = 'personal/automation',
    [string]$ScriptsDir   = 'C:\dev\kopia\scripts'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RepoRoot)) {
    Write-Error "RepoRoot not found: $RepoRoot"
    exit 2
}
if (-not (Test-Path -LiteralPath $ScriptsDir)) {
    Write-Error "ScriptsDir not found: $ScriptsDir"
    exit 2
}

# Pull the branch's view of scripts/ into memory: file -> blob hash.
$branchFiles = & git -C $RepoRoot ls-tree -r --name-only "$Branch" -- scripts/ 2>$null
if (-not $branchFiles) {
    Write-Error "git ls-tree returned nothing for $Branch -- scripts/"
    exit 2
}

$drift = New-Object System.Collections.Generic.List[string]
$missing = New-Object System.Collections.Generic.List[string]

foreach ($entry in $branchFiles) {
    $relPath  = $entry -replace '^scripts/', ''
    $diskPath = Join-Path $ScriptsDir $relPath

    if (-not (Test-Path -LiteralPath $diskPath)) {
        $missing.Add($relPath) | Out-Null
        continue
    }

    $branchHash = (& git -C $RepoRoot rev-parse "${Branch}:${entry}" 2>$null).Trim()
    $diskHash   = (& git -C $RepoRoot hash-object -- $diskPath 2>$null).Trim()

    if ($branchHash -ne $diskHash) {
        $drift.Add($relPath) | Out-Null
    }
}

# Files on disk that the branch does not track (excluding gitignored
# secrets/flags). We do not consider these drift; they're informational.
$diskOnly = New-Object System.Collections.Generic.List[string]
$branchSet = $branchFiles | ForEach-Object { ($_ -replace '^scripts/', '') }
Get-ChildItem -LiteralPath $ScriptsDir -File | ForEach-Object {
    $name = $_.Name
    if ($name -in $branchSet) { return }
    if ($name -eq '.kopia-pw.dat')   { return }
    if ($name -like 'BACKUP_*.flag') { return }
    $diskOnly.Add($name) | Out-Null
}

$exitCode = 0
if ($drift.Count -gt 0) {
    Write-Host "DRIFT (on-disk differs from ${Branch}):" -ForegroundColor Red
    $drift | ForEach-Object { Write-Host "  $_" }
    $exitCode = 1
}
if ($missing.Count -gt 0) {
    Write-Host "MISSING from on-disk (branch has, disk does not):" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host "  $_" }
    $exitCode = 1
}
if ($diskOnly.Count -gt 0) {
    Write-Host "ON-DISK ONLY (not tracked on ${Branch}):" -ForegroundColor Yellow
    $diskOnly | ForEach-Object { Write-Host "  $_" }
}
if ($exitCode -eq 0 -and $diskOnly.Count -eq 0) {
    Write-Host "OK: scripts/ matches ${Branch} exactly." -ForegroundColor Green
}

exit $exitCode
