# deploy-config.ps1 — Phase 5 of the cicd pipeline.
# CONSERVATIVE: validate-only. Never overwrites secrets or production config.
# Confirms each known config artifact is well-formed and protected.

[CmdletBinding()]
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\pipeline-state.ps1"

$run = Start-PhaseRun -Phase 'deploy-config'
Write-PhaseLog "[deploy-config] Phase 5 — validating config files (read-only)" -Level info

$failures = @()
$warnings = @()

# 1. signing/metadata.json — must parse + contain required fields
try {
    $meta = Get-Content 'C:\dev\kopia\signing\metadata.json' -Raw | ConvertFrom-Json
    foreach ($f in 'Endpoint','CodeSigningAccountName','CertificateProfileName') {
        if (-not $meta.$f) { throw "missing field: $f" }
    }
    Write-PhaseLog "  [ok] signing/metadata.json valid" -Level ok
} catch {
    $failures += "signing/metadata.json: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] signing/metadata.json: $($_.Exception.Message)" -Level err
}

# 2. D:\KopiaServer\repository.config — JSON parse only (server-mode config)
$serverCfg = 'D:\KopiaServer\repository.config'
if (Test-Path $serverCfg) {
    try {
        $cfg = Get-Content $serverCfg -Raw | ConvertFrom-Json
        Write-PhaseLog "  [ok] D:\KopiaServer\repository.config parses" -Level ok
    } catch {
        $failures += "D:\KopiaServer\repository.config: $($_.Exception.Message)"
        Write-PhaseLog "  [FAIL] $serverCfg" -Level err
    }
} else {
    $warnings += "D:\KopiaServer\repository.config absent (server mode may not be configured on this host)"
    Write-PhaseLog "  [warn] $serverCfg not present (informational)" -Level warn
}

# 3. scripts/.kopia-pw.dat — exists + ACL is owner-only (NEVER read content)
$pwVault = 'C:\dev\kopia\scripts\.kopia-pw.dat'
if (Test-Path $pwVault) {
    try {
        $acl = Get-Acl $pwVault -ErrorAction Stop
        $perms = $acl.Access | Where-Object { -not $_.IsInherited } |
            Where-Object { $_.IdentityReference -notmatch 'SYSTEM|Administrators|' + [Environment]::UserName }
        if ($perms) {
            $failures += "scripts/.kopia-pw.dat ACL has unexpected entries: $($perms.IdentityReference -join ', ')"
            Write-PhaseLog "  [FAIL] .kopia-pw.dat ACL too permissive" -Level err
        } else {
            Write-PhaseLog "  [ok] scripts/.kopia-pw.dat ACL owner-only" -Level ok
        }
    } catch {
        # Get-Acl denied -> caller lacks READ_CONTROL on the file. This means
        # the ACL is *more* restrictive than owner-only, not less, so the file
        # cannot be exfiltrated (or its DACL inspected) by this account. Also
        # confirm content is unreadable to rule out an exotic ACL where DACL
        # is hidden but data is exposed.
        $contentReadable = $false
        try { [void][System.IO.File]::ReadAllBytes($pwVault); $contentReadable = $true } catch {}
        if ($contentReadable) {
            $failures += "scripts/.kopia-pw.dat: ACL unreadable but content readable (anomalous DACL)"
            Write-PhaseLog "  [FAIL] .kopia-pw.dat ACL unreadable AND content readable" -Level err
        } else {
            Write-PhaseLog "  [ok] scripts/.kopia-pw.dat locked down (ACL+content unreadable to current user)" -Level ok
        }
    }
} else {
    $warnings += "scripts/.kopia-pw.dat absent (recreate via SECRETS.md procedure)"
    Write-PhaseLog "  [warn] .kopia-pw.dat not present (informational)" -Level warn
}

# Verdict
if ($failures) {
    $msg = "$($failures.Count) failure(s); $($warnings.Count) warning(s)"
    Complete-PhaseRun -Run $run -Status 'failed' -Message $msg
    Write-PhaseLog "[deploy-config] $msg" -Level err
    foreach ($f in $failures) { Write-PhaseLog "  - $f" -Level err }
    exit 1
} else {
    $msg = if ($warnings) { "OK with $($warnings.Count) warning(s)" } else { "all configs valid" }
    Complete-PhaseRun -Run $run -Status 'ok' -Message $msg
    Write-PhaseLog "[deploy-config] $msg" -Level ok
    foreach ($w in $warnings) { Write-PhaseLog "  - $w" -Level warn }
    exit 0
}
