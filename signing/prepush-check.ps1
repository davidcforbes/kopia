# prepush-check.ps1 — Refuse the push unless the locally-signed kopia.exe
# and helper .ps1 files are up to date with HEAD and all carry Status=Valid.
# Exits 0 (allow push) or 1 (block push).
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repo  = 'C:\dev\kopia'
$stamp = Join-Path $repo 'signing\.last-sign'

if (-not (Test-Path $stamp)) {
    Write-Host "FAIL: no sign stamp at $stamp"
    Write-Host "      run: make release"
    exit 1
}
$stampTime = (Get-Item $stamp).LastWriteTime

# Find tracked .go files newer than the stamp. Stage Go sources only — this
# fork doesn't push scripts/ (gitignored). Use git to enumerate tracked files
# so we don't pick up dist/, vendor caches, etc.
Push-Location $repo
try {
    $tracked = git ls-files '*.go'
    $newer = @()
    foreach ($f in $tracked) {
        $full = Join-Path $repo $f
        if (Test-Path $full) {
            if ((Get-Item $full).LastWriteTime -gt $stampTime) { $newer += $f }
        }
    }
} finally { Pop-Location }

if ($newer.Count -gt 0) {
    Write-Host "FAIL: $($newer.Count) tracked Go file(s) newer than last sign ($stampTime):"
    $newer | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" }
    if ($newer.Count -gt 8) { Write-Host "  ...and $($newer.Count - 8) more" }
    Write-Host "      run: make release"
    exit 1
}

# Verify all signed targets still carry Status=Valid.
& (Join-Path $repo 'signing\sign-all.ps1') -VerifyOnly | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: signature verification failed"
    exit 1
}

Write-Host "OK: signed artifacts current with HEAD (stamp $stampTime)"
exit 0
