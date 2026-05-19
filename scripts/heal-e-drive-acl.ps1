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
# MII9bQYJKoZIhvcNAQcCoII9XjCCPVoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAEtbKm3
# Mu04MYwNAAAAAS1sMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNTE4MTc1MjI4WhcNMjYwNTIx
# MTc1MjI4WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAteMeWV4qcDkjDU9o8Vsf
# +8aimerhkD7QjnYhPuOA0ooqKzdC58dLkrEmEngklAOBFzhT05bKkbCtCEwT+q1+
# 5yJGmda3uwPhIm6r9jCBK9q44FYLBSOH+xuAk54raSZE/nVtWwpnTkYh0nw1TNne
# wH4TZA5W6vSGLNuksKfj0CwW9zWMI7+clSuUucu1VB9n+HyZcH+AjRbPruelh3x2
# PSjH9orDlH+quvnRJZm2DIE9pb8LS//wPWZA/59lfyU367z5imRf5NuYcK6EoBj1
# wVTwLh3xhDdCZ88DVE6SydHnTzUQpntLle0+jQ4lkXvS9PHIBTHcXkfOy/IIDUp+
# WrQrm99A1dy1eexUFdgvf+bkxzeMAqZfPfuHS/r4Si6xIp0MCPfouKUEkOXWWrJH
# WMI/Dtp+5cJfLVtd9b0dBwstKLJXaEs5WWSL5TQAHKHAQx+rbDDyhJxOuGKzKxEY
# X+NPcsxVXYkXS3LE0nWL7R3wthxaFPtNaP7lUx/fGOvFAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBSP044ig9IeEbOQyK4ZzyoAsjD99jAfBgNVHSMEGDAWgBSa8VR3dQyHFjdG
# oKzeefn0f8F46TBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBFT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwNC5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEALqQI6Ju6qI2FRjasZ6+rVyH15siAEE/zv83AoQ8ToGXYOaVT3TE4/hEptEKW
# vu8AgmiW70NHvYfGygfCuVrSjgakNd4Fx+fDLJJJ4OuQPizZKu5SIWjfAs0kXNCZ
# NymzpG5YB09tyzkT4C8/31DdMCWrOr5+6ZZoD+S40BLT1L+cS63SsHs3poK2/HAF
# V3Iv75jBKUqDKi2ApNupto68I/piqWjSyMCLMaGZigZBahkIxi1vJeSOmMd1ef43
# npvSqfuauHvp6unuJ8gj4+qXCu41GxVcYMxIDwkyKzs41fMKNVK9pRJl+3bs8ZGz
# Nz/lWc06i7dYP0K6wCJUmrJQw6a3n80Il9C3mlqabg/mDmZsDb7uk9LNYfPigNwL
# dq1xQkPPn3a0w4fanG3NrQNhJqvNKAJ7op+mr6w9BPdKCw69MfoOzyrD2S5w/kAD
# 4P1X1v1HNPbWhY8CS64N2ySn2ri8sxGCMZ5so4SBaZoKVYqGmIAAy+IZWXhF5RxA
# hgZPUNuanx5ygMqAxbgwN41j7ybUOGhBrl6HFVW5SNd0oD9hOu6dcmCH5KqZXWkH
# BzWG4ZlTW1mhWaIwdR1vIGPCjhqe2YoLuVaBhdKX/8gb5OFYB4Y7X4Z26l4WMHKC
# w+Lf+bMKjBRYBPrtJIYaaE0dFvlMGqJ20XTmFhG5KTjm8kcwggbFMIIEraADAgEC
# AhMzAAEtbKm3Mu04MYwNAAAAAS1sMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNTE4MTc1MjI4
# WhcNMjYwNTIxMTc1MjI4WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAteMeWV4q
# cDkjDU9o8Vsf+8aimerhkD7QjnYhPuOA0ooqKzdC58dLkrEmEngklAOBFzhT05bK
# kbCtCEwT+q1+5yJGmda3uwPhIm6r9jCBK9q44FYLBSOH+xuAk54raSZE/nVtWwpn
# TkYh0nw1TNnewH4TZA5W6vSGLNuksKfj0CwW9zWMI7+clSuUucu1VB9n+HyZcH+A
# jRbPruelh3x2PSjH9orDlH+quvnRJZm2DIE9pb8LS//wPWZA/59lfyU367z5imRf
# 5NuYcK6EoBj1wVTwLh3xhDdCZ88DVE6SydHnTzUQpntLle0+jQ4lkXvS9PHIBTHc
# XkfOy/IIDUp+WrQrm99A1dy1eexUFdgvf+bkxzeMAqZfPfuHS/r4Si6xIp0MCPfo
# uKUEkOXWWrJHWMI/Dtp+5cJfLVtd9b0dBwstKLJXaEs5WWSL5TQAHKHAQx+rbDDy
# hJxOuGKzKxEYX+NPcsxVXYkXS3LE0nWL7R3wthxaFPtNaP7lUx/fGOvFAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBSP044ig9IeEbOQyK4ZzyoAsjD99jAfBgNVHSMEGDAWgBSa
# 8VR3dQyHFjdGoKzeefn0f8F46TBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwNC5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEALqQI6Ju6qI2FRjasZ6+rVyH15siAEE/zv83AoQ8ToGXYOaVT
# 3TE4/hEptEKWvu8AgmiW70NHvYfGygfCuVrSjgakNd4Fx+fDLJJJ4OuQPizZKu5S
# IWjfAs0kXNCZNymzpG5YB09tyzkT4C8/31DdMCWrOr5+6ZZoD+S40BLT1L+cS63S
# sHs3poK2/HAFV3Iv75jBKUqDKi2ApNupto68I/piqWjSyMCLMaGZigZBahkIxi1v
# JeSOmMd1ef43npvSqfuauHvp6unuJ8gj4+qXCu41GxVcYMxIDwkyKzs41fMKNVK9
# pRJl+3bs8ZGzNz/lWc06i7dYP0K6wCJUmrJQw6a3n80Il9C3mlqabg/mDmZsDb7u
# k9LNYfPigNwLdq1xQkPPn3a0w4fanG3NrQNhJqvNKAJ7op+mr6w9BPdKCw69MfoO
# zyrD2S5w/kAD4P1X1v1HNPbWhY8CS64N2ySn2ri8sxGCMZ5so4SBaZoKVYqGmIAA
# y+IZWXhF5RxAhgZPUNuanx5ygMqAxbgwN41j7ybUOGhBrl6HFVW5SNd0oD9hOu6d
# cmCH5KqZXWkHBzWG4ZlTW1mhWaIwdR1vIGPCjhqe2YoLuVaBhdKX/8gb5OFYB4Y7
# X4Z26l4WMHKCw+Lf+bMKjBRYBPrtJIYaaE0dFvlMGqJ20XTmFhG5KTjm8kcwggco
# MIIFEKADAgECAhMzAAAAFydFCQuLh6/GAAAAAAAXMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjYwMzI2MTgxMTMxWhcNMzEwMzI2MTgxMTMxWjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDA0MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAgsdk/gMPZioBlcyfk6tDzJ+PRt4rSLGKW8ewpS0kRxXt
# URC3T3GdbCKljobEn8ussqhGqQpRh/SXvRVwNXEIGb76UG5IPkCJ1S6/9BD61QQs
# KzPepW0SNj8TXgsFxvS7MltoRuikIIp7Q5jQgaOM6QyK9++6ZVXUpYmZulAe6x8J
# rwZ0dNkE+rZ66lqtoocwepUSVUxM7odDmn8yDHjJ2DNPsfr3uRDix3X4qvh14jH/
# SW+2Cx7WIMhyIiQO201i6hUixmk4e2ZW8W7C1wPdTjq6BKb+zo8xbrt7ZKQvRX5Q
# OA6dhLquPqj5sVKnxqfk19IC0SafTSTs8yC43Ew965BRRW8VL9ccoOmr4rxQy7aC
# gYTNk3dd/LphNaTTmnGp7kmLTxyHkB5geoWhYuuGrywS8E0wJv0W4rfOtHBV0e9s
# KvuUIeIUpnsx6ilxEVj6VQXvgD6yeCKnPmj3jJiJKAlmUDtth5yzRVBUl44sMiG4
# L5R/yyACRKk2n088Q2YCoZS1O86+oMLKt1jaXGECOjbsVp8Id1VQw8he6J0KirOS
# 5e25XlTdGPFb6oBOOaacgW78Kjf0bp+XzAgkc92mDGNJGYSjvdnj+7eMx6meW0DA
# IGdLRNj8/429MIspFBfz3KDqqpN71S4kQ2LLer3dxhDDczKVFL0HLwRuOvgjiG8C
# AwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUmvFUd3UMhxY3RqCs3nn59H/BeOkwVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcw
# AoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIx
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEAkHVaGf1NJt/JdoimmRZbMWr6baaDi8mk
# dWvWStk0hdZDpxSYTA7HuipAoLL3qIhI101XOl7fOiCh5++jZOamQdAV79ojEUNo
# IgCZmL2XJrLaGanwdjNynecJyYVCTrRf2+h7KknpWOp4axdOs6K9ZQ5g0IsQWXCw
# fc0dfkSkLKNY3pDcWLlJPh2jd5NUue6pNDv/2G5MFNJhCwltODebyAjGceU+XOza
# v+7i721YQnQ+39m2aQOFO7zpAdaKAeAGhEd6Y6CdDGneSxcoujWvafWbv4ay3jo1
# ORSLUuWMbKr5X18QE4Sde+gppGLLSkZsrUh2eyYSkX1envWX7ZPzg2/wiuKRlQFa
# rDn+N9+20BqzhxwkNyLzfYJp1Lg4fCXb24XqFjx8SDdRgebFImOfOLVze8XQ/Cwk
# rEaib0PHu2t4GVk4FYroEbNUFqvjdBvTY3uiR5TdQoyXoYHvh+TxpLSY2vo7hhK9
# D/rpEpHC+qmmcRUE4d0gyO9Zb1vvt25fxM3ekjvDfVHcPq3qMr0Rwsk4krKZWUEg
# U1SXT5qN6gqRrshxbT6OQgZ9/xT04qiXdzPQR6KindBvSpoOnxnALxcJyzVwNpKL
# +9u8EZYy98qX6i+4gE/2J6cbpekcB0ZXDn/XQxoNUUb6/djT/wllVyG+vIHkdq71
# PzbH5rYxdcAwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
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
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakzCC
# Go8CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENB
# IDA0AhMzAAEtbKm3Mu04MYwNAAAAAS1sMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIK1UMZXc4g0YZYeacGqVb9/BYa7wP3xJNOkAsDMR4gZ5MA0GCSqGSIb3
# DQEBAQUABIIBgCUlEEGwWuM9G8pfnuKhikcFCu/7HBO9FGnPZjunk5Gr8B0LRG84
# TbzarmfvQCY7bJuaiWQdinhCXdC2ZzQ68F+BTiG389GiNBFAfnb7SIv8wsg3vAvQ
# B3SQqNTqe1YS3JN8db2dSW5GhTouZCfwERqIt9IhrCjmHcamyBnHA3tfgtbzJWW1
# c9hZPsl5QmiB0I2iqtZcgqwhEPHpXLAA2NmLbuJ2IaE6ffPm/eDDz/AT9wpNHFvY
# ZFAsAfiCjlgan68FjgKwzy3JZKYfRNAx12UJIPlv3WXcCXmNURz0L5vl/tytn77Q
# z2WY7qgWPkVrLceaBjrZPZyP3FNLOKXzQhD0PoyxQBnmX0HQVxugO4HcPD623s6S
# 0Dehz5+AIrd70JZKlefGVnnjsVb0hii93uIl8cVyZ2v2iLwjr/ekC5QqJHaxdV2T
# lhG8wwTPpvtn211rqfCw3t2UQOs5DA44pEze5H0nJPcls/DNksctvgjWK6u1GcED
# Vh3c16n7OzYMlaGCGBMwghgPBgorBgEEAYI3AwMBMYIX/zCCF/sGCSqGSIb3DQEH
# AqCCF+wwghfoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFiBgsqhkiG9w0BCRABBKCC
# AVEEggFNMIIBSQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCDL3qb
# wabZx4BgmYKFK/mnfNFCZaiPPXB49c2iyFIDwAIGagxEypbwGBMyMDI2MDUxOTE3
# MzUzNy4zNjJaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRp
# b25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5NDcxNTAz
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
# yX4lhthsGHumaABdWzCCB5cwggV/oAMCAQICEzMAAABXJNOV4KLpyTEAAAAAAFcw
# DQYJKoZIhvcNAQEMBQAwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGlt
# ZXN0YW1waW5nIENBIDIwMjAwHhcNMjUxMDIzMjA0NjUzWhcNMjYxMDIyMjA0NjUz
# WjCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UE
# CxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVs
# ZCBUU1MgRVNOOjc4MDAtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALFspQqTCH24syS2NZD1ztnJl9h0Vr0WwJnikmeXse/4
# wspnVexGqfiHNoqkbVg5CinuYC+iVfNMLZ+QtqhySz8VGBSjRt1JB5ACNtTKAjfm
# Fp4U/Cv2Lj4m+vuve9I3W3hSiImTFsHeYZ6V/Sd43rXrhHV26fw3xQSteSbg9yTs
# 1rhdrLkAj4KmI0D5P4KavtygirVyUW10gkifWLSE1NiB8Jn3RO5dj32deeMNONaa
# Pnw3k49ICTs3Ffyb+ekNDPsNfYwCqPyOTxM6y1dSD0J5j+KK9V+EWyV5PDjV8jjn
# 1zsStlS6TcYJJStcgHs2xT9rs6ooWl5FtYfRkCxhDShEp3s8IHUWizTWmLZvAE/6
# WR2Cd+ZmVapGXTCHJKUByZPxdX0i8gynirR+EwuHHNxEilDICLatO2WZu+CQrH4Z
# q0NYo1TQ4tUpZ/kAWpoAu1r4mW5EJ3HkEavQ2PuoQDcDq2rAGVIla9pD7o9Yxwzl
# 81BuDvUEyu9D/6F0qmQDdaE791HxfCUxpgMYPpdWTzs+dDGPehwQ8P92yP8ARjby
# 5Ony1Z68RjeQebpxf5WL441myFHcgT1UJzzil7tPEkR22NfTNR6Fl+jzWb/r80nq
# lXllhynSowtxo1Y22xqYviS24smikUsBKqOPbSS77uvXEO3VrG5LGouE1EZ1Y9pj
# AgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQUjoPJXi01DgIJSGfm416Yg+0SkqcwHwYD
# VR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBhoF+gXYZb
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIw
# UHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNybDB5Bggr
# BgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0
# YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEGDCsGAQQB
# gjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqGSIb3DQEB
# DAUAA4ICAQBydcB2POmZOUlAQz2NuXf7vWCVWmjWu9bsY1+HMjv1yeLjxDQkjsJE
# U5zaIDy8Uw9BYN8+ExX/9k/9CBUsXbVlbU44c65/liyJ83kWsFIUwhVazwSShFlb
# IZviIO/5weyWyTfPPpbSJgWy+ZE9UrQS3xulJLAHA2zUkMMPdAlF4RrngcZZ0r45
# AF9aIYjdestWwdrNK70MfArHqZdgrgXn03w6zBs1v7czceWGitg/DlsHqk1mXBpS
# TuGI2TSPN3E60IIXx5f/AFzh4/HFi98BBZbUELNsXkWAG9ynZ5e6CFiil1mgWCWO
# T90D7Igvg0zKe3o3WCk629/en94K/sC/zLOf2d7yFmTySb9fKjcONH1Db3kZ8MzE
# J8fHTNmxrl10Gecuz/Gl0+ByTKN+PambZ+F0MIlBPww6fvjFC9JII73fw3qO169+
# 9TxTz2G+E26GYY1dcffsAhw6DqTQgbflbl1O/MrSXSs0NSb9nBD9RfR/f8Ei7DA1
# L1jBO7vZhhJTjw2TzFa/ALgRLi3W00hHWi8LGQaZc8SwXIMYWfwrN9MgYbhN0Iak
# 9WA2dqWuekXsTwNkmrD3E6E+oCYCehNOgZmds0Ezb1jo7OV0Kh22Ll3KHg3MHtlG
# guxAzhg/BpixPS4qrULLkAjO7+yNsUfrD2U9gMf/OR4yJDPtzM0ytTGCB0UwggdB
# AgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjACEzMAAABXJNOV4KLpyTEAAAAAAFcwDQYJYIZIAWUDBAIBBQCgggSe
# MBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MDUxOTE3MzUzN1owLwYJKoZIhvcNAQkEMSIEIGHD
# w07Y7+IJOhBhstzBaQOz6rrv/9m+/dLQNhsVZcJJMIG5BgsqhkiG9w0BCRACLzGB
# qTCBpjCBozCBoAQg9TyfZLUFbkxliGyizuH9VVDpVFNvQEQhKQ2ZhUx421IwfDBl
# pGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENB
# IDIwMjACEzMAAABXJNOV4KLpyTEAAAAAAFcwggNgBgsqhkiG9w0BCRACEjGCA08w
# ggNLoYIDRzCCA0MwggIrAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjc4MDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUA/S8xOZxCUQFBNkrN8Wiij1x5y8Og
# ZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDttsNMMCIYDzIwMjYwNTE5MTEwOTAw
# WhgPMjAyNjA1MjAxMTA5MDBaMHYwPAYKKwYBBAGEWQoEATEuMCwwCgIFAO22w0wC
# AQAwCQIBAAIBNAIB/zAHAgEAAgISljAKAgUA7bgUzAIBADA2BgorBgEEAYRZCgQC
# MSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqG
# SIb3DQEBCwUAA4IBAQAg/gCio2Fa6ssaoTXNVatMwWNd3EdtWNoj8zAl9eoc/sOG
# BgvQnDIQCgmWBYh81MCl9UGPrf7nB8VDjyxdtymDSaFccAChyjfuNdzKXyiag1A8
# 5ZiJbrQVNGu6bB1D67T6lzeYraoWBfqBxgz2iRTbX7zFaRrj72NR1s17kuYZEOHr
# wPDcz34O2rFEvNIpmUFbOfRD7vtlApSOC7ziWCAGq846aIVXtFVYqSFYw2I9gbv2
# QJK/09+zo3s9iCjHk6+eDBPAO1WGiPQnXmtHu8WddlcRq9Ae7allz8Z6M5Lk/SkW
# l7j1PXoKSs8+t0ZKxKWS+2lRZVDLouWNvNzWUYksMA0GCSqGSIb3DQEBAQUABIIC
# ACHwyGJXjT36qRvTQph6D51h25egH+smihpQ6eCWwvPDyDoivCv1b1dX1xEVSpFC
# HR5Ra8pxSfDrJ7UzBfqwY61KEC0SGTTPGfZeCYyHBwydvP12tIPmmX6l6R8v9f+6
# +aVKkPi//qeuDVPmkty0GExXmI4EMyvYo6ZyFpNBk8g1V73iv+yLa5/SmV1lOLUp
# IL0/CmlkrJq42nL0AUupvjcvzd27hZ8dBoxUuLtqIQDrlp4Tm4GAcdOKOrBFo6Qx
# wdkDa/83NTwn4lhYqafxUIkeNYKl57jhaEjdAxaCt8rlyr8sFXSWGOkcka5Ovtjd
# qmNySAIjgHUmSYx2Vg0L8Ak3ydAq8/3uwFPMi5P3q0Co3PkXnOFGvwiIEjycuexL
# feqBaTD2wZxAcrYQi+LS2v7ff2/CBNjyVCpv78TZcR2pW2Zp3xj5SKOcFPKjtPz2
# HvMu/g2y0HOop8RvRJCy/raK/BYaEjZ78EXlm+tJT4lidqW/lgHYATjMelzguoA3
# kRb0DU8uVCCXam9etnHcn42TdUYlVwc7k/E3B5Ar6piCGnGMOu69LcR/CMlSGbvr
# 0m21fwxgVvY2lnzr/xgVWpWDzOOoOfO+4Q1olf4gg+ZczpsQtmV9f+eSLZgp+Kj+
# NWTZ76eAee0JElFFkCfUJoekHnyvE9SFRL14BmJzWesx
# SIG # End signature block
