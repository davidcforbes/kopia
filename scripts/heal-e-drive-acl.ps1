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

# SIG # Begin signature block
# MII9awYJKoZIhvcNAQcCoII9XDCCPVgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA34zPyqgk6Cs9B
# o2YU1zrNrmicQZVJWdTtQSswsqg1MKCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAEuTThO
# B8uVoxpoAAAAAS5NMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNTE5MTc1MjU4WhcNMjYwNTIy
# MTc1MjU4WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA0Z8gdyilROysNZkdgIEP
# Lz1IqP1KS2/+XMYQIbwpNyp10zpviET1ShNMSAh/h/XkR7EJPREFWlofoekpk8lS
# c3PtYKypZ99Azw3yUGslgpAGX9WmBNw8B9kYfodNKI0J8sj1uZLUMccozbhxQhwC
# RX//PO29bPPZx8blfjyZdhKXdFDe8j+6C1jL11SZxd1Yvh9Sq+hfNeFZhPNdxbMc
# Mgy1hAKRLTH7YP/c3eScqG48D0Rkqgz4NMQXKltb+tHVSr9z1p9Xpf5059ls2l2w
# vnZbnpBwkO4Emeq4VxIozsXS+V/DGa+B8pTWjb9nT7om7pIqzkc1bKYKzLPbetfw
# 3tVIBcHMBTUFMYraswP+plxwTtIay+PCdVqd9IkTZUIRiK/fkV7zAYuuLyV9L4Ol
# XBe9HH7j8/QN+AqJzzytGy37fxjBdkM0YGlJniomuhLqmXiHx9wueabZ7T912ods
# Z8g1G08yJ9nXf+zJe44Cfwht2Mw+wDQp0R0hiYFZvMJBAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBQ9h/vet312AcYL7wbnVxU8uRFV/jAfBgNVHSMEGDAWgBRrJUHe+2t8/RiA
# Ci1/j3ZdqnM9uDBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBBT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwNC5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEAf5B3djqFpt2lQ7lUR2C6XAGlcFjgR7JvPyy5PjrSX77ASsspgtYQh0BRk4az
# cjJXFi3lSKscmOy694Li9deSq9lbbFZQ932E4Nm8bP4jY/nKKSw10o9wGZHulkTI
# RSTNt4XS8X4o/7lkQmj02kCJ2BRwCZWjX2srYmxzbGzU9KnosOUWJ1QR/3Q5DHxF
# 1mQEHdvWoiIhEVr/yu0q5/GhDfuPvq83qg7+VASjgJwQRAGWhpVUrUcMOpPzGolg
# m55RrY8skp1V5wGKxTTIgHWQAglYZhQFyu0o4y3xVgbp/bhO9Rz0WwTMBz6ZWj3a
# bukOBglLXwGHtsCQMmsrN3MgTkXLIoDJhn/1Wmn9OCTvS3imjA8vDqSZOlllessn
# Dlfk6gmyFgLSUAhR0NWEUWBAB1/AIHaOUMwKmmakPDKy4b7KfS90urvZX9MeA3h4
# 7F6bpyTI9yThsNJcUy3/MiRjBNIOtvpXiS1lQesTsJSBzO4TohwGjfq4Pj//JmSs
# gJzkMfqqrJhKGNZFgD8ryr5lBljzmzJwvI9rDcmMJvcPfR16cVgJfigeaQwQovuC
# MxQWZ3smlwQc1JDVNMiv5kFs5v0EFocEpzLdLhcvh3Mk2N3bOlJrx9D7//pVvIX9
# TspIfWPvWTLKzg7Uilcv4pL16xQ787QfYv5TVBXAzyCI8eswggbFMIIEraADAgEC
# AhMzAAEuTThOB8uVoxpoAAAAAS5NMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNTE5MTc1MjU4
# WhcNMjYwNTIyMTc1MjU4WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA0Z8gdyil
# ROysNZkdgIEPLz1IqP1KS2/+XMYQIbwpNyp10zpviET1ShNMSAh/h/XkR7EJPREF
# Wlofoekpk8lSc3PtYKypZ99Azw3yUGslgpAGX9WmBNw8B9kYfodNKI0J8sj1uZLU
# MccozbhxQhwCRX//PO29bPPZx8blfjyZdhKXdFDe8j+6C1jL11SZxd1Yvh9Sq+hf
# NeFZhPNdxbMcMgy1hAKRLTH7YP/c3eScqG48D0Rkqgz4NMQXKltb+tHVSr9z1p9X
# pf5059ls2l2wvnZbnpBwkO4Emeq4VxIozsXS+V/DGa+B8pTWjb9nT7om7pIqzkc1
# bKYKzLPbetfw3tVIBcHMBTUFMYraswP+plxwTtIay+PCdVqd9IkTZUIRiK/fkV7z
# AYuuLyV9L4OlXBe9HH7j8/QN+AqJzzytGy37fxjBdkM0YGlJniomuhLqmXiHx9wu
# eabZ7T912odsZ8g1G08yJ9nXf+zJe44Cfwht2Mw+wDQp0R0hiYFZvMJBAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBQ9h/vet312AcYL7wbnVxU8uRFV/jAfBgNVHSMEGDAWgBRr
# JUHe+2t8/RiACi1/j3ZdqnM9uDBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwNC5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEAf5B3djqFpt2lQ7lUR2C6XAGlcFjgR7JvPyy5PjrSX77ASssp
# gtYQh0BRk4azcjJXFi3lSKscmOy694Li9deSq9lbbFZQ932E4Nm8bP4jY/nKKSw1
# 0o9wGZHulkTIRSTNt4XS8X4o/7lkQmj02kCJ2BRwCZWjX2srYmxzbGzU9KnosOUW
# J1QR/3Q5DHxF1mQEHdvWoiIhEVr/yu0q5/GhDfuPvq83qg7+VASjgJwQRAGWhpVU
# rUcMOpPzGolgm55RrY8skp1V5wGKxTTIgHWQAglYZhQFyu0o4y3xVgbp/bhO9Rz0
# WwTMBz6ZWj3abukOBglLXwGHtsCQMmsrN3MgTkXLIoDJhn/1Wmn9OCTvS3imjA8v
# DqSZOlllessnDlfk6gmyFgLSUAhR0NWEUWBAB1/AIHaOUMwKmmakPDKy4b7KfS90
# urvZX9MeA3h47F6bpyTI9yThsNJcUy3/MiRjBNIOtvpXiS1lQesTsJSBzO4TohwG
# jfq4Pj//JmSsgJzkMfqqrJhKGNZFgD8ryr5lBljzmzJwvI9rDcmMJvcPfR16cVgJ
# figeaQwQovuCMxQWZ3smlwQc1JDVNMiv5kFs5v0EFocEpzLdLhcvh3Mk2N3bOlJr
# x9D7//pVvIX9TspIfWPvWTLKzg7Uilcv4pL16xQ787QfYv5TVBXAzyCI8eswggco
# MIIFEKADAgECAhMzAAAAFjGSjZICZXuaAAAAAAAWMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjYwMzI2MTgxMTI5WhcNMzEwMzI2MTgxMTI5WjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDA0MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAylX6yNvoCTDP9G0OTlSjXbzgEsy21FDL17n/lZe2BrqH
# z2mR1aN4DBxeYp0/hjEqSHHyGfarV1NVBuvK8vLzW0LTi+DZt9In16aiNfgcogFi
# ztWE9Fp8xu1zzrqE3nlrDWb+RZo8QrEXgWb8s8swsl2W7tREHycVkx+Hm1MLQIlv
# a6jH/Xg4/8GIYhHzbXiVd2RXomw9s7Qh6/SYRXXfe125wh4EKEyKnNNl+cZUSrVB
# gWvvjrRwQY4if7sAZ805KruBY6WY0Hiba5nWvrq9Qk9o35ViAf8qZ+7u1fbb1vcC
# WyWLfx9hLSdBjjVsSWe0xLvI1j4p3Tjt5czz+1Lc0v5lQ1feB7nFmpbZrK2us0hv
# AaBCfOyDPEEm+735vzuNRYWJFL/PViI+REtjuJMcojEn3veQjIrwrmK0T9oSr8e3
# oDzK1oAwwZMTC4KymTvYUTVDJvL5N8OW/UqIBzsiVYcchZvGhV3yMYKgxeEtIOG4
# W4Z85Y5kpQi5bpjGXFxRg46RdrTaALt1RhRmLR7U0jVSr2aYAd2+Mp2qA5Gz3/lo
# OOdt47eFZ3mrAYGYQtbK2SNjQpwgQX4Iy6tOKahCgFhKIcltitvSkpJB77eVWhNW
# nN2LfqMojszEue7V8EAySxry4PzlxTtFTb3Mw53XyH12BMQf2m9j7jEsHeVSATsC
# AwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUayVB3vtrfP0YgAotf492XapzPbgwVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcw
# AoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIx
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEABtVQXlR01UQZY5XGQ9yIjMcD8jI0MizW
# hJ1buZjg5toUQSXx/BrASwE5qxwHPBeO45pOQp6VD4iILgm8OmfylY+A7KIqttvD
# UizC3sBXxjK4u7sDRiyEguXHKfL1HQAwxCLEtnRPkCPTsJA6b917lA+3foQIHC1X
# DDpdQLHxGbbGXp4Rr0mFK5vxbi6tAahBi/RlzOXPh6PavKPlZ/0vhlkDdsvoJETt
# ebNJCNOZ1Kav3Tg+K4va4FbOrYqRHdGGahoA/gmTYmmVqw0zkGzT53HdhfajrFGt
# tJomK7qE+T8CQGiPkEIkxNmSXjCTpDqc4U1IKlTGcGYnRFGSgqrnWnkANPFsJ5ED
# Hysh82lPI+PFC3FOIVMLzLL+30rqznvRgHUUAj7xfFnEiuaAx3vFVSTOLb+iigpv
# dR6i8fSWpgYESOkdkn2N57tuhBs57tKwoP++vc/MVpuD1XAtmWi+lZSlahadTbDf
# GKjMn+bfm2xlW9PZ6BSnCRv1MMhpcUZkAZX3gVEMef8rZc2c7BJ4ayRfX0wH43vI
# 9znV+ZRJ3j0xUC0Zb82RQalF5yHkCr93x0IwvZtn6P2dNQyCP6qd3fC4RlVFtAQh
# tOH0cByTR/Iqqghv6qHzL/pMptgMQQ5x8zYEYy+tCThYgYIrq7y4WEDYQfeSlqIx
# QOrIUJ4IJDEwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
# SIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJpZmljYXRp
# b24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMTA0MDEyMDA1
# MjBaFw0zNjA0MDEyMDE1MjBaMGMxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xNDAyBgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmll
# ZCBDb2RlIFNpZ25pbmcgUENBIDIwMjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQCy8MCvGYgo4t1UekxJbGkIVQm0Uv96SvjB6yUo92cXdylN65Xy96q2
# YpWCiTas7QPTkGnK9QMKDXB2ygS27EAIQZyAd+M8X+dmw6SDtzSZXyGkxP8a8Hi6
# EO9Zcwh5A+wOALNQbNO+iLvpgOnEM7GGB/wm5dYnMEOguua1OFfTUITVMIK8faxk
# P/4fPdEPCXYyy8NJ1fmskNhW5HduNqPZB/NkWbB9xxMqowAeWvPgHtpzyD3PLGVO
# mRO4ka0WcsEZqyg6efk3JiV/TEX39uNVGjgbODZhzspHvKFNU2K5MYfmHh4H1qOb
# U4JKEjKGsqqA6RziybPqhvE74fEp4n1tiY9/ootdU0vPxRp4BGjQFq28nzawuvaC
# qUUF2PWxh+o5/TRCb/cHhcYU8Mr8fTiS15kRmwFFzdVPZ3+JV3s5MulIf3II5FXe
# ghlAH9CvicPhhP+VaSFW3Da/azROdEm5sv+EUwhBrzqtxoYyE2wmuHKws00x4GGI
# x7NTWznOm6x/niqVi7a/mxnnMvQq8EMse0vwX2CfqM7Le/smbRtsEeOtbnJBbtLf
# oAsC3TdAOnBbUkbUfG78VRclsE7YDDBUbgWt75lDk53yi7C3n0WkHFU4EZ83i83a
# bd9nHWCqfnYa9qIHPqjOiuAgSOf4+FRcguEBXlD9mAInS7b6V0UaNwIDAQABo4IC
# NTCCAjEwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQW
# BBTZQSmwDw9jbO9p1/XNKZ6kSGow5jBUBgNVHSAETTBLMEkGBFUdIAAwQTA/Bggr
# BgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1Jl
# cG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB
# /wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZmAQHJ89QEE9oqKIwgYQGA1Ud
# HwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENl
# cnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcmwwgcMGCCsGAQUFBwEBBIG2
# MIGzMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJv
# b3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjAuY3J0MC0GCCsGAQUF
# BzABhiFodHRwOi8vb25lb2NzcC5taWNyb3NvZnQuY29tL29jc3AwDQYJKoZIhvcN
# AQEMBQADggIBAH8lKp7+1Kvq3WYK21cjTLpebJDjW4ZbOX3HD5ZiG84vjsFXT0OB
# +eb+1TiJ55ns0BHluC6itMI2vnwc5wDW1ywdCq3TAmx0KWy7xulAP179qX6VSBNQ
# kRXzReFyjvF2BGt6FvKFR/imR4CEESMAG8hSkPYso+GjlngM8JPn/ROUrTaeU/BR
# u/1RFESFVgK2wMz7fU4VTd8NXwGZBe/mFPZG6tWwkdmA/jLbp0kNUX7elxu2+HtH
# o0QO5gdiKF+YTYd1BGrmNG8sTURvn09jAhIUJfYNotn7OlThtfQjXqe0qrimgY4V
# poq2MgDW9ESUi1o4pzC1zTgIGtdJ/IvY6nqa80jFOTg5qzAiRNdsUvzVkoYP7bi4
# wLCj+ks2GftUct+fGUxXMdBUv5sdr0qFPLPB0b8vq516slCfRwaktAxK1S40MCvF
# bbAXXpAZnU20FaAoDwqq/jwzwd8Wo2J83r7O3onQbDO9TyDStgaBNlHzMMQgl95n
# HBYMelLEHkUnVVVTUsgC0Huj09duNfMaJ9ogxhPNThgq3i8w3DAGZ61AMeF0C1M+
# mU5eucj1Ijod5O2MMPeJQ3/vKBtqGZg4eTtUHt/BPjN74SsJsyHqAdXVS5c+ItyK
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakTCC
# Go0CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENB
# IDA0AhMzAAEuTThOB8uVoxpoAAAAAS5NMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIK1UMZXc4g0YZYeacGqVb9/BYa7wP3xJNOkAsDMR4gZ5MA0GCSqGSIb3
# DQEBAQUABIIBgK/HKMrPLsgregtO6898gJU5O1MPOyPRHyHnkRi8KaMJJkNnX0yv
# Wi0I3rdXyKSiGGHy0qV23/tH6Th+xNAXG2fkYl/VL4XgHk+SsWNkIPUkbcZpWao3
# CYQRGBip2cUkBWg4PuLqhdgt0t8mNf8h+mXSEe6JI+vMCL+pjbLEaEJArmc7b1hr
# IKNXaWXPag67f0f8I5rJ/5xMdEFM7b9nZvcVuxPm/VEdSdZMmDaGlzgl5ydwIBFQ
# Vs5neuWKVLWXaF7agPqcGr4KR/KJPLVe4twSBrQ7LbKoGkkdonTZiTSGZ0s6e27Y
# sqWRtoQLK73Jr5kth6C1PiV9VeCxIt8PSMqmyCG5hq8ZFWKcJbuSAGxvaaZvlRE+
# rqyu9gmGugOJB8pGQLEs6nurYs6fpvb1zdt/JTvFnUqHeUidYKs+Rsi2maGZBvOz
# PwpCSVgH5/OAtY7xvw5gtMF7K25LMy50aN9DbhvRk2jBfDNJIV1XSvZRC4erFRe1
# pCmGJ/a4KgLbeqGCGBEwghgNBgorBgEEAYI3AwMBMYIX/TCCF/kGCSqGSIb3DQEH
# AqCCF+owghfmAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFiBgsqhkiG9w0BCRABBKCC
# AVEEggFNMIIBSQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCnyWoV
# AHZE6SjbdhqAcwnVyScqTQXNtls89DtHUJP2yQIGaeiBMUyzGBMyMDI2MDUxOTIy
# NTAzNy4zMjZaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRp
# b25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAz
# BgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9y
# aXR5oIIPITCCB4IwggVqoAMCAQICEzMAAAAF5c8P/2YuyYcAAAAAAAUwDQYJKoZI
# hvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlmaWNhdGlv
# biBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIwMTExOTIwMzIz
# MVoXDTM1MTExOTIwNDIzMVowYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0Eg
# VGltZXN0YW1waW5nIENBIDIwMjAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQCefOdSY/3gxZ8FfWO1BiKjHB7X55cz0RMFvWVGR3eRwV1wb3+yq0OXDEqh
# UhxqoNv6iYWKjkMcLhEFxvJAeNcLAyT+XdM5i2CgGPGcb95WJLiw7HzLiBKrxmDj
# 1EQB/mG5eEiRBEp7dDGzxKCnTYocDOcRr9KxqHydajmEkzXHOeRGwU+7qt8Md5l4
# bVZrXAhK+WSk5CihNQsWbzT1nRliVDwunuLkX1hyIWXIArCfrKM3+RHh+Sq5RZ8a
# Yyik2r8HxT+l2hmRllBvE2Wok6IEaAJanHr24qoqFM9WLeBUSudz+qL51HwDYyID
# PSQ3SeHtKog0ZubDk4hELQSxnfVYXdTGncaBnB60QrEuazvcob9n4yR65pUNBCF5
# qeA4QwYnilBkfnmeAjRN3LVuLr0g0FXkqfYdUmj1fFFhH8k8YBozrEaXnsSL3kdT
# D01X+4LfIWOuFzTzuoslBrBILfHNj8RfOxPgjuwNvE6YzauXi4orp4Sm6tF245Da
# FOSYbWFK5ZgG6cUY2/bUq3g3bQAqZt65KcaewEJ3ZyNEobv35Nf6xN6FrA6jF944
# 7+NHvCjeWLCQZ3M8lgeCcnnhTFtyQX3XgCoc6IRXvFOcPVrr3D9RPHCMS6Ckg8wg
# gTrtIVnY8yjbvGOUsAdZbeXUIQAWMs0d3cRDv09SvwVRd61evQIDAQABo4ICGzCC
# AhcwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRr
# aSg6NS9IY0DPe9ivSek+2T3bITBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEF
# BQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9z
# aXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoA
# UwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZ
# mAQHJ89QEE9oqKIwgYQGA1UdHwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZp
# Y2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5j
# cmwwgZQGCCsGAQUFBwEBBIGHMIGEMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUy
# MFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
# MDIwMjAuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBfiHbHfm21WhV150x4aPpO4dhE
# mSUVpbixNDmv6TvuIHv1xIs174bNGO/ilWMm+Jx5boAXrJxagRhHQtiFprSjMktT
# liL4sKZyt2i+SXncM23gRezzsoOiBhv14YSd1Klnlkzvgs29XNjT+c8hIfPRe9rv
# VCMPiH7zPZcw5nNjthDQ+zD563I1nUJ6y59TbXWsuyUsqw7wXZoGzZwijWT5oc6G
# vD3HDokJY401uhnj3ubBhbkR83RbfMvmzdp3he2bvIUztSOuFzRqrLfEvsPkVHYn
# vH1wtYyrt5vShiKheGpXa2AWpsod4OJyT4/y0dggWi8g/tgbhmQlZqDUf3UqUQsZ
# aLdIu/XSjgoZqDjamzCPJtOLi2hBwL+KsCh0Nbwc21f5xvPSwym0Ukr4o5sCcMUc
# Sy6TEP7uMV8RX0eH/4JLEpGyae6Ki8JYg5v4fsNGif1OXHJ2IWG+7zyjTDfkmQ1s
# nFOTgyEX8qBpefQbF0fx6URrYiarjmBprwP6ZObwtZXJ23jK3Fg/9uqM3j0P01nz
# VygTppBabzxPAh/hHhhls6kwo3QLJ6No803jUsZcd4JQxiYHHc+Q/wAMcPUnYKv/
# q2O444LO1+n6j01z5mggCSlRwD9faBIySAcA9S8h22hIAcRQqIGEjolCK9F6nK9Z
# yX4lhthsGHumaABdWzCCB5cwggV/oAMCAQICEzMAAABV2d1pJij5+OIAAAAAAFUw
# DQYJKoZIhvcNAQEMBQAwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGlt
# ZXN0YW1waW5nIENBIDIwMjAwHhcNMjUxMDIzMjA0NjQ5WhcNMjYxMDIyMjA0NjQ5
# WjCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UE
# CxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVs
# ZCBUU1MgRVNOOjdEMDAtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBAL25H5IeWUiz9DAlFmn2sPymaFWbvYkMfK+ScIWb3a1I
# vOlIwghUDjY0Gp6yMRhfYURiGS0GedIB6ywvuH6VBCX3+bdOFcAclgtv21jrpOjZ
# mk4fSaT2Q3BszUfeUJa8o3xI7ZfoMY9dszTxHQAz6ZVX87fHGEVhQcfxW33IdPJO
# j/ae419qtYxT21MVmCfsTshgtWioQxmOW/vMC9/b+qgtBxSMf798vm3qfmhF6KCv
# FaHlivrM32hY16PGE3L0PFC+LM7vRxU7mTb+r76CeybvqOWk4+dbKYftPhV1t/E5
# S/6wwXeYmu/Y7JC7Tnh2w45G5Y4pcM3oHMb/YuPRdOWa0v+RC2QgmNVWqjuxDiyl
# WscXQDuaMtb29AcdGUVV9ZsRY2M2sthAtOdZOshiR5ufMtaHtiCkWv0jNfgUxrHu
# rxzYuUNneWZ6EfQDgFAw8CSCKkSOK2c9jEop4ddVq10xvbqxdrqMneVXvvIcXrPQ
# AXj9j2ECpV2EwMb3Wnmpw00P78JpzPsk3Fs61ZvOGd/F1RcOBu6f2TWdp7HL7+rq
# 7tgHr13MldbfIWu4lpoYYE1gTQa1Yrg5XN4j7zs9klT2z3qocmPzV8DWQgIHNh+a
# Ts7bujMEMQyI7Xt1zPxZCgcR6H0tmmzU/9BxvsWbRalCQ2sYGyWupTdc4e7KY7kP
# AgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQUVgRfEG3cCAPwyL+pyRbKwdesZbYwHwYD
# VR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBhoF+gXYZb
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIw
# UHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNybDB5Bggr
# BgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0
# YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEGDCsGAQQB
# gjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqGSIb3DQEB
# DAUAA4ICAQBSHuGSVHvalCnFnlsqXIQefH1xP2SFr9g+Vz+f5P7QeywjfQb5jUlS
# md1XnJUDPe/MHxL7r3TEElL+mNtG6CDPAytStSFPXD9tTBtBMYh8Wqo64pH9qm36
# 1yIqeBH979mzWCkMQsTd0nM6dUl9B+7qiti+ToXwxIl39eYqLuYYfhD2mqqePXMz
# UKSQzkf73yYIVHP6nLJQz4aAmaWcfG9jg78sBkDV8KpW7JgktuLhphJEN1B+SVHj
# enPdcmrFXIUu/K4jK5ukfWaQIjuaXzSjBlNjC5tQN6adPfA3GxUwHPeR4ekL5If/
# 9vBf13tmzBW+gy+0sNGTveb9IL9GU8iX8UvywsX62nhCCPRUhTigDBKdczRUrNrn
# tBhowbfchBDFML8avRMRc9Gmc2JvIryX336SFQ51//q1UU2HMSJEMhWLJSIWJVhf
# UowsOa+PampIzETYfFvTu2mqKJUlWZXkGYxrdCvCczJcqeoadpW1ul6kcdnDh228
# SQ8ZhDc6IRlM4iNd5SNoNgX+aom3wuGyjUaSaPZWxPB1G2NKiYhPLt0lPHg0Gskj
# 1zhISY8UQkMMDr3o2JgRuT+wnJEDQUp55ddvhSkSoD6I9DL/s+TjIY/c9jLaW5xy
# wJHqdKHUApRMsghv7kebSua1upmR+TquelFktDSOjVdSRkuya4uoxTGCB0Mwggc/
# AgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjACEzMAAABV2d1pJij5+OIAAAAAAFUwDQYJYIZIAWUDBAIBBQCgggSc
# MBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MDUxOTIyNTAzN1owLwYJKoZIhvcNAQkEMSIEIKst
# ccyVQ7WtpfDISyg/bNnsQm//xmIv2H5PZ60/CVPlMIG5BgsqhkiG9w0BCRACLzGB
# qTCBpjCBozCBoAQg2Lk8l2SGYru/ff7+D2qrJnkswcYdK6pGKu7GGGr4/s0wfDBl
# pGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENB
# IDIwMjACEzMAAABV2d1pJij5+OIAAAAAAFUwggNeBgsqhkiG9w0BCRACEjGCA00w
# ggNJoYIDRTCCA0EwggIpAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjdEMDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUAHTtUAYJlv7bgWVeRBo4X7FeHDeqg
# ZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDtt0CwMCIYDzIwMjYwNTE5MjAwNDAw
# WhgPMjAyNjA1MjAyMDA0MDBaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO23QLAC
# AQAwBwIBAAICBnUwBwIBAAICE0UwCgIFAO24kjACAQAwNgYKKwYBBAGEWQoEAjEo
# MCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG
# 9w0BAQsFAAOCAQEAmbjrux/idm60fBzDYipIb53jEhU8zxEhkhhdcxIaYUuzJy/+
# eg7Es6x9mpVU8631zsXpbkltl5o8xgDq/qiQSEKJLJYXYBi9q5gSu+jvrJYXh2n3
# yi/PMOu8S1yWFHDRc1lRgUp2sFmHLYFZTU+obzL5yZ9Sm9ElVqQRhmc/4Z7iMjxJ
# ilJrkYAnNVnq3YkBjXj+S8M0IAUYA6tMdmjEbuEVDQS9DLPNt7hWF54Q07lQ2n27
# sGndfmQGIajF9BOhKESZWbSbYskefUPMCu1jYIBHKCSzdpoXNorB+pFyPh44LZoO
# PnFggSWfg0TU4sXXZvPHRsSuBH/AOCkoXHXT4jANBgkqhkiG9w0BAQEFAASCAgCd
# oMlInXe4LyMIOqkXYBwUaJBwtxl1tvbmF5BO9CJp09ZQdV7vIe17k3r5/I31QzFO
# umVQIuPABPMo22gCU7s9BfEroU6dY4i3ovARA0qsoraExw3FQBqqPuhm9oML9V9L
# 4KtoQpRB82AZMplKl41tGz52NkmMEfmMx8s+V1mmvqMZSATSVixAUCn0moSEwgWU
# ZesV1cXbML2HHrVTP6bAjDRVvDYbyfnaWrqIrVwb5a5hemUBVFc8pZNhWR1Hfyq9
# qLKchOEO6aKsVAy4aytUsqIIaXP8ekr9GOJjzIvcvXwPmMqKMCNZSJxvCWZClV75
# 0JlWIqJDX/v1N5aYZvcQKDzfLwj03JBs7zeUux0KrCDhpqLI2prescCJMTC4RmeF
# /TXWArS0howOVHCiOzg2kzjDJGqa43ogIy8bQPqNQcjPQuQyaYN+XL9Q2LpJxf/1
# P5CIkX5lueZv+192z44GhbocJutoy2WuARu7VQQWVDmafzhbcxQBT/UsZMn4QG8k
# LgkVJ5ICPSxn5iCsCVKLbBUxZZQ0HGsfXELdH1AYqV8ZK9eI8aNPC1GTMmTVAJv7
# GymJbj9GptLUHl1ePUwEObL4rwsQhw4nFU1W+MMA0AB3GbH2W+j9jGTYBo/AqSnR
# VCIwD2P0Jsmt3zPiwMe1y1F5lDAzTnw0BjYKEY7tbg==
# SIG # End signature block
