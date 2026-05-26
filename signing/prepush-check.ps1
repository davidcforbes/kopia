# prepush-check.ps1 — Refuse the push unless the locally-signed kopia.exe,
# every rustback binary, and helper .ps1 files are up to date with HEAD,
# and all signed targets carry Status=Valid.
#
# Exits 0 (allow push) or 1 (block push).
#
# kopia-cjwb (2026-05-26): extended to also walk the rustback workspace's
# tracked .rs files so a push containing un-rebuilt-and-resigned Rust source
# is refused. Mirrors the existing .go-mtime check; same stamp,
# same fail-fast message.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repo            = 'C:\dev\kopia'
$rustbackRepo    = 'C:\dev\rustback'
$stamp           = Join-Path $repo 'signing\.last-sign'

if (-not (Test-Path $stamp)) {
    Write-Host "FAIL: no sign stamp at $stamp"
    Write-Host "      run: make release"
    exit 1
}
$stampTime = (Get-Item $stamp).LastWriteTime

# ── Tracked .go files (existing behaviour) ─────────────────────────────
# Find tracked .go files in the kopia repo newer than the stamp. Stage
# Go sources only — this fork doesn't push scripts/ (gitignored). Use
# git to enumerate tracked files so we don't pick up dist/, vendor
# caches, etc.
Push-Location $repo
try {
    $trackedGo = git ls-files '*.go'
    $newerGo = @()
    foreach ($f in $trackedGo) {
        $full = Join-Path $repo $f
        if (Test-Path $full) {
            if ((Get-Item $full).LastWriteTime -gt $stampTime) { $newerGo += $f }
        }
    }
} finally { Pop-Location }

# ── Tracked .rs files (kopia-cjwb extension) ───────────────────────────
# Same shape as the .go walk but rooted at C:\dev\rustback. Skipped
# silently if the rustback repo isn't cloned next to kopia (a non-mixed
# operator's host wouldn't have it — let prepush-check still gate on
# .go alone in that case).
$newerRs = @()
if (Test-Path $rustbackRepo) {
    Push-Location $rustbackRepo
    try {
        $trackedRs = git ls-files '*.rs'
        foreach ($f in $trackedRs) {
            $full = Join-Path $rustbackRepo $f
            if (Test-Path $full) {
                if ((Get-Item $full).LastWriteTime -gt $stampTime) { $newerRs += $f }
            }
        }
    } finally { Pop-Location }
}

# ── Combined report ────────────────────────────────────────────────────
if ($newerGo.Count -gt 0 -or $newerRs.Count -gt 0) {
    $total = $newerGo.Count + $newerRs.Count
    Write-Host "FAIL: $total tracked source file(s) newer than last sign ($stampTime):"
    if ($newerGo.Count -gt 0) {
        Write-Host "  ── Go ($($newerGo.Count) file(s)) ──"
        $newerGo | Select-Object -First 6 | ForEach-Object { Write-Host "    $_" }
        if ($newerGo.Count -gt 6) { Write-Host "    ...and $($newerGo.Count - 6) more" }
    }
    if ($newerRs.Count -gt 0) {
        Write-Host "  ── Rust ($($newerRs.Count) file(s) under $rustbackRepo) ──"
        $newerRs | Select-Object -First 6 | ForEach-Object { Write-Host "    $_" }
        if ($newerRs.Count -gt 6) { Write-Host "    ...and $($newerRs.Count - 6) more" }
    }
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
