#Requires -Version 5.1
<#
.SYNOPSIS
    Prong A of kopia-0dr.49 — one-time clean-slate ACL repair of the E:\
    backup volume root so the RustBack replica can create and overwrite
    files on the destination.

.DESCRIPTION
    `wbadmin` stamps Deny ACEs on the E:\ volume root as a backup-target
    protection mechanism. Those Deny ACEs inherit downward and block
    `rustback-mirror` from creating/overwriting files (observed as
    "Access is denied (os error 5)" on E:\Recovery during the 2026-05-18
    cutover-validation run).

    This script kills the inheritance at its source: it takes ownership
    of the volume root, removes the explicit Deny ACEs there for the
    backup account and for CREATOR OWNER, and grants the backup account
    an inheritable Full-Control ACE. Because the grant is inheritable
    (OI)(CI) it overrides any remaining inherited Deny across the whole
    subtree.

    Run this ONCE, before the new backup stack goes live. It is the
    manual, root-scoped equivalent of `rustback-mirror`'s built-in
    per-run self-heal (`heal_dst_acl`, kopia-0dr.49 prong B): prong A
    fixes the volume root; prong B keeps each destination SUBTREE root
    writable on every run, including after a future `wbadmin` re-stamp.

    The operation is idempotent and safe to re-run: `icacls /remove:d`
    on an absent ACE is a no-op, and `/grant` updates rather than
    duplicates.

    Scope: the volume ROOT only — no recursive ACL rewrite of the
    (multi-TB) volume. Explicit Deny ACEs that sit on individual
    subtree roots are handled by prong B at replica time.

.PARAMETER Target
    The volume root to repair. Default: E:\

.PARAMETER GrantUser
    The account the replica/backup-server runs as — it receives the
    inheritable Full-Control grant and has its Deny ACEs removed.
    Default: david

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    # Run elevated, AS the backup account (so the write-probe tests
    # that account's real access):
    powershell -ExecutionPolicy Bypass -File .\heal-e-drive-acl.ps1

.EXAMPLE
    .\heal-e-drive-acl.ps1 -Target E:\ -GrantUser david -WhatIf

.NOTES
    kopia-0dr.49. Companion: rustback src/mirror/acl.rs (prong B),
    docs/superpowers/specs/2026-05-19-mirror-acl-self-heal-design.md.
    Must be run elevated (modifying the volume-root DACL needs
    ownership / SeRestorePrivilege).
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$Target = 'E:\',
    [string]$GrantUser = 'david',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Section($text) {
    Write-Host ''
    Write-Host "── $text " -ForegroundColor Cyan
}

# Run an icacls invocation and fail loudly on a non-zero exit.
function Invoke-Icacls {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$IcaclsArgs)
    Write-Host "  icacls $($IcaclsArgs -join ' ')" -ForegroundColor DarkGray
    & icacls.exe @IcaclsArgs
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed (exit $LASTEXITCODE): icacls $($IcaclsArgs -join ' ')"
    }
}

# ── Preconditions ───────────────────────────────────────────────────

$isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Must run elevated. Re-launch in an Administrator PowerShell."
    exit 1
}

if (-not (Test-Path -LiteralPath $Target)) {
    Write-Error "Target not found: $Target"
    exit 1
}

# Resolve the bare-name account to DOMAIN\name so icacls and the ACL
# read agree on the trustee.
$grantQualified = $GrantUser
if ($GrantUser -notmatch '[\\@]') {
    $grantQualified = "$env:USERDOMAIN\$GrantUser"
}

Write-Host "RustBack — E: drive ACL heal (kopia-0dr.49 prong A)" -ForegroundColor White
Write-Host "  Target     : $Target"
Write-Host "  Grant user : $grantQualified"
Write-Host "  Running as : $env:USERDOMAIN\$env:USERNAME"
if ($env:USERNAME -ne $GrantUser -and $grantQualified -notmatch [regex]::Escape($env:USERNAME)) {
    Write-Warning ("Not running as '$GrantUser'. The write-probe will test " +
        "the current account, not the backup account. For a definitive " +
        "check, run this script as '$GrantUser', or rely on the " +
        "operator-supervised replica run.")
}

# ── Before ──────────────────────────────────────────────────────────

Write-Section "Current ACL of $Target"
& icacls.exe $Target
Write-Host ''
Write-Host ("Review the listing above. This script will remove explicit " +
    "(DENY) entries for '$grantQualified' and 'CREATOR OWNER', then grant " +
    "'$grantQualified' inheritable Full Control. Other trustees' ACEs are " +
    "left untouched.") -ForegroundColor Yellow

if (-not $Force -and -not $PSCmdlet.ShouldProcess($Target, 'clean-slate ACL repair')) {
    # ShouldProcess handles -WhatIf and the confirmation prompt.
    Write-Host 'Aborted — no changes made.' -ForegroundColor Yellow
    exit 0
}

# ── Repair ──────────────────────────────────────────────────────────

Write-Section "Taking ownership of $Target"
# Ownership grants implicit WRITE_DAC even when a Deny ACE would
# otherwise block editing the DACL. Root only — not recursive.
& takeown.exe /F $Target
if ($LASTEXITCODE -ne 0) {
    throw "takeown failed (exit $LASTEXITCODE) on $Target"
}

Write-Section "Removing blocking Deny ACEs"
# /remove:d strips only DENIED ACEs for the named trustee (any ALLOW
# ACE for the same trustee is kept). No-op when the ACE is absent.
Invoke-Icacls $Target '/remove:d' $grantQualified
Invoke-Icacls $Target '/remove:d' 'CREATOR OWNER'

Write-Section "Granting inheritable Full Control to $grantQualified"
# (OI)(CI) makes the ACE inheritable by files and subdirectories, so it
# overrides any inherited Deny across the whole E: subtree. Full Control
# (F) includes WRITE_DAC, so prong B can re-heal after a wbadmin re-stamp.
Invoke-Icacls $Target '/grant' "${grantQualified}:(OI)(CI)F"

# ── Write-probe ─────────────────────────────────────────────────────

Write-Section "Write-probe"
$probe = Join-Path $Target ('.rustback-acl-probe-' + [Guid]::NewGuid().ToString('N'))
$probeOk = $false
try {
    Set-Content -LiteralPath $probe -Value 'rustback acl probe' -ErrorAction Stop
    $null = Get-Content -LiteralPath $probe -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    $probeOk = $true
    Write-Host "  create + write + delete at $Target succeeded." -ForegroundColor Green
} catch {
    Write-Host "  write-probe FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $probe) {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

# ── After ───────────────────────────────────────────────────────────

Write-Section "Resulting ACL of $Target"
& icacls.exe $Target

Write-Host ''
if ($probeOk) {
    Write-Host ("DONE. $Target root is writable. Run an operator-supervised " +
        "orchestrated replica to confirm each subtree mirrors with " +
        "errors=0, then close kopia-0dr.49.") -ForegroundColor Green
    exit 0
} else {
    Write-Host ("ACLs were modified but the write-probe failed. Inspect the " +
        "ACL listing above for additional Deny ACEs (e.g. on other " +
        "trustees), or check that the volume is not read-only.") -ForegroundColor Red
    exit 2
}
