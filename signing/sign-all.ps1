# sign-all.ps1 — Sign kopia.exe and all backup helper .ps1 files using
# Azure Trusted Signing via signtool + Microsoft.Trusted.Signing.Client DLIB.
#
# Mirrors the flow from C:\dev\activity-journal\Makefile.toml [tasks.sign-cli].
# Re-uses the 'activity-journal' certificate profile under the famcodesign
# account (same identityValidationId, so legal publisher identity is identical).
[CmdletBinding()]
param(
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

# Ensure the dlib's AzureCliCredential can find 'az'. When sign-all is invoked
# from a non-interactive Make session (Bash → powershell.exe child), the PATH
# may not include the az CLI install dir even when an interactive PS session
# would have it. Prepend the standard install dir so the dlib's PATH-based
# az lookup succeeds. (Without this: 'AzureCliCredential authentication failed:
# Azure CLI not installed' even though Phase 1 diagnose just succeeded —
# diagnose has its own fallback path; the dlib doesn't.)
$azDir = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin'
if ((Test-Path $azDir) -and ($env:Path -notlike "*$azDir*")) {
    $env:Path = "$azDir;$env:Path"
}

# Phase 1 preflight (skippable for emergency only).
# Always invoke via pwsh.exe — diagnose-signing.ps1 uses the ?? operator (PS 7+).
if (-not $env:SKIP_DIAGNOSE) {
    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) {
        Write-Host "pwsh.exe (PowerShell 7+) required for diagnose-signing.ps1 (uses ?? operator)." -ForegroundColor Red
        Write-Host "  Install via: winget install Microsoft.PowerShell" -ForegroundColor Yellow
        Write-Host "  Or set `$env:SKIP_DIAGNOSE = '1' to bypass preflight (not recommended)." -ForegroundColor Yellow
        exit 1
    }
    $diagnoseScript = Join-Path $PSScriptRoot '..\cicd\diagnose-signing.ps1'
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $diagnoseScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host "diagnose-signing.ps1 reported failures (exit $LASTEXITCODE) — aborting sign-all." -ForegroundColor Red
        Write-Host "  Set `$env:SKIP_DIAGNOSE = '1' to bypass (not recommended)." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "[sign-all] SKIP_DIAGNOSE=1 — bypassing Phase 1 preflight (not recommended)." -ForegroundColor Yellow
}

$repo     = 'C:\dev\kopia'
$metadata = Join-Path $repo 'signing\metadata.json'
if (-not (Test-Path $metadata)) { throw "metadata.json not found at $metadata" }

# Locate signtool.exe and Azure.CodeSigning.Dlib.dll inside the user-global
# NuGet cache populated by 'dotnet restore' on signing/dlib/dlib.csproj.
$nugetRoot = (dotnet nuget locals global-packages --list |
              Select-String 'global-packages:').ToString().Split(': ')[1].Trim()

$signtool = (Get-ChildItem "$nugetRoot\microsoft.windows.sdk.buildtools" -Recurse -Filter signtool.exe |
             Where-Object { $_.FullName -like '*x64*' } |
             Select-Object -Last 1).FullName

$dlib = (Get-ChildItem "$nugetRoot\microsoft.trusted.signing.client" -Recurse -Filter Azure.CodeSigning.Dlib.dll |
         Where-Object { $_.FullName -like '*x64*' } |
         Select-Object -Last 1).FullName

if (-not $signtool) { throw 'signtool.exe not found. Run: cd signing\dlib && dotnet restore' }
if (-not $dlib)     { throw 'Azure.CodeSigning.Dlib.dll not found. Run: cd signing\dlib && dotnet restore' }

# Targets: the kopia CLI binary, every backup-monitor binary (signed
# whether or not scheduled tasks use them directly -- the DR recovery
# cache at D:\Recovery needs signed copies; kopia-2xy), and every
# PowerShell helper used by scheduled tasks.
$targets = @(
    'C:\Users\david\go\bin\kopia.exe',
    'C:\dev\backup-monitor\target\release\backup-mirror.exe',
    'C:\dev\backup-monitor\target\release\backup-monitor.exe',
    'C:\dev\backup-monitor\target\release\backup-dump.exe',
    'C:\dev\backup-monitor\target\release\backup-indexer.exe',
    "$repo\scripts\repo_status_check.ps1",
    "$repo\scripts\check_backup_errors.ps1"
)
foreach ($extra in 'check_backup_health.ps1','verify_helpers_preflight.ps1','get_kopia_password.ps1','get_kopia_server_password.ps1','start_kopia_server.ps1','heartbeat_watchdog.ps1','get_parent_pid.ps1','daily_d_replica.ps1','weekly_replica_verify.ps1') {
    $p = "$repo\scripts\$extra"
    if (Test-Path $p) { $targets += $p }
}

if (-not $VerifyOnly) {
    Write-Host "signtool : $signtool"
    Write-Host "dlib     : $dlib"
    Write-Host "metadata : $metadata"
    Write-Host ''

    # Pre-flight lock check (kopia-tpl). signtool can't re-sign a file that is
    # already memory-mapped as an executable image -- Windows returns
    # ERROR_SHARING_VIOLATION and signtool reports "The file is being used by
    # another process". The previous behavior was to abort the whole loop on
    # the first locked file, leaving later targets unsigned. Instead: identify
    # locked targets up front, name the holding processes, and skip them with
    # a clear message so the rest of the batch can complete.
    $lockedTargets = @()
    foreach ($t in $targets) {
        if (-not (Test-Path $t)) { continue }
        try {
            $fs = [System.IO.File]::Open($t, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $fs.Close()
        } catch [System.IO.IOException] {
            $abs = (Resolve-Path -LiteralPath $t).Path
            $holders = Get-Process | Where-Object { $_.Path -eq $abs } | Select-Object -ExpandProperty Id
            $lockedTargets += [pscustomobject]@{ Path = $t; Holders = $holders }
        }
    }
    if ($lockedTargets.Count -gt 0) {
        Write-Host '=== Locked targets (skipping) ===' -ForegroundColor Yellow
        foreach ($lt in $lockedTargets) {
            $hint = if ($lt.Path -like '*kopia.exe') { '  hint: stop the kopia server (Stop-Process -Id <pid>) and rerun sign-all' } else { '' }
            Write-Host ("  {0}  held by PID(s): {1}{2}" -f $lt.Path, ($lt.Holders -join ', '), "`n$hint") -ForegroundColor Yellow
        }
        Write-Host ''
        $lockedPaths = $lockedTargets.Path
        $targets = $targets | Where-Object { $_ -notin $lockedPaths }
    }

    foreach ($t in $targets) {
        if (-not (Test-Path $t)) { Write-Warning "Skipping (not found): $t"; continue }
        # Pre-sign parse-check for .ps1 targets (kopia-02h). Past incidents
        # (2026-05-12, 2026-05-14) had a hygiene tool drop a brace and sign-all
        # happily signed the unparseable result -- scheduled tasks then failed
        # at parse time with zero log output and a stale-but-Valid signature.
        # Refuse to sign any .ps1 that the parser rejects.
        if ($t -like '*.ps1') {
            $errs = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile($t, [ref]$null, [ref]$errs)
            if ($errs -and $errs.Count -gt 0) {
                $first = $errs[0]
                throw "REFUSING TO SIGN: $t failed AST parse ($($errs.Count) errors; first at $($first.Extent.StartLineNumber):$($first.Extent.StartColumnNumber): $($first.Message))"
            }
        }
        Write-Host ">>> Signing $t" -ForegroundColor Cyan
        & $signtool sign `
            /v `
            /fd SHA256 `
            /tr 'http://timestamp.acs.microsoft.com' `
            /td SHA256 `
            /dlib $dlib `
            /dmdf $metadata `
            $t
        if ($LASTEXITCODE -ne 0) { throw "signtool failed on $t (exit $LASTEXITCODE)" }
    }
    Write-Host ''
}

Write-Host '=== Verification ===' -ForegroundColor Cyan
$bad = 0
foreach ($t in $targets) {
    if (-not (Test-Path $t)) { continue }
    $sig = Get-AuthenticodeSignature $t
    $color = if ($sig.Status -eq 'Valid') { 'Green' } else { 'Red' }
    Write-Host ("{0,-8} {1}" -f $sig.Status, $t) -ForegroundColor $color
    if ($sig.Status -ne 'Valid') { $bad++ }
}
if ($bad -gt 0) { throw "$bad file(s) have non-Valid signatures." }
Write-Host 'All signatures valid.' -ForegroundColor Green

# Refresh bare-metal recovery cache at D:\Recovery (kopia-2xy). Copies the
# five core .exe binaries (kopia, backup-monitor, backup-mirror, backup-dump,
# backup-indexer) into D:\Recovery only if their content actually changed,
# so successful sign-all runs that don't touch any exe are a no-op.
# Silently skipped if D:\Recovery doesn't exist (clean-host or DR not yet
# configured); user can mkdir D:\Recovery to opt in.
$recoveryDir = 'D:\Recovery'
if (Test-Path -LiteralPath $recoveryDir) {
    $recoveryTargets = $targets | Where-Object { $_ -like '*.exe' }
    foreach ($src in $recoveryTargets) {
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $recoveryDir (Split-Path $src -Leaf)
        $srcHash = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
        $dstHash = if (Test-Path -LiteralPath $dst) { (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash } else { '' }
        if ($srcHash -ne $dstHash) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Write-Host ("Recovery cache refreshed: {0}" -f $dst) -ForegroundColor Cyan
        }
    }
}

# SIG # Begin signature block
# MII9awYJKoZIhvcNAQcCoII9XDCCPVgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBci0XME+HPzS1u
# d4SKjeO0w0NPtGY96RRixSeo/NkHqqCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAEQB7Jf
# AW3AtcBgAAAAARAHMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNTE1MTc1MDQ1WhcNMjYwNTE4
# MTc1MDQ1WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAr2LJ61/gYnFRuY9peqbv
# go3sQvA7PRqazQn16PSaFdy16sJ9KKjR8jmqyFDiueZVUuRh94tt3m7Wqry34dhF
# p1Xf+grajrMdQNkh3QmevtT9oKXSv27N7P/rjjGdAyx2F5Nd9I2Tf2ArfHmHWpQx
# uCDjk+UuV19xcF9GIa8HkgJS6jEaKcaJ5QR2Hi1Rr9lIv3GmOEB8Au+Jz6AAzSdZ
# HcYFYTMwv+QUO7lg7Suuze/JbdtfUyHjK4V746uTJuNCOW8LPgq/5qYeDjFuv/W3
# 33rHFbYoIyGR8pbmmnT97tpRxvRQpp4pfrqazUqbPOF7TDlgaEpsE0ThX3Q1wkuY
# sJakywElLOc6rJilkawNUUI4iIXyelKg/+c8LGb9mK2PTdZvYrAGP2+aKw6/3FvD
# BCvCZmNCiUxr1niEykzFN6BdHA09pMKZT4smdkx0w8g2PUlk1QnI+tqe07PXI4NZ
# DsK+rWnMGrzPIeTv8n5qtBZQFL+uhdXcYPPj6mPgxpWpAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBQwat2ukhyLpm/JD4NOfdCL6xZXADAfBgNVHSMEGDAWgBRrXqU0wwXFYkoh
# Wo6rc2Bi1KxjhTBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBFT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwMy5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEArGmHo6zVXEkxr5MsyaHWDPauCXLIx8XUhC6/+Mw1/e/Mlxh5U1Pw5yFc3BRs
# pQQbxgCcL4TTaIW5o34jGcWd2zZDrCou0pISfQ5KY01aUu24j2wIujKS6pinrpl8
# oo62+kXirCNKB5bq/Rn8dIi/AikuZHXxP5iud2gq+wk/jOyAdUX7qQjEMG7EVMb4
# petMTcQHWam6YGvFQEKY4ZZuToB7Ar6fTLKenLQizKgg/We67BRkBdArzQxv3rVx
# yoS52KVlQMBro41hYdWQxjeT0ybYAxIo3FhtOq5vnaHPJd/8horVuAg38yTjuzRa
# e8FoibJhrjydFO1V5vqAbLLlQX+RGRO79c7XtAIzicE6cXJIMAQh0Q107F+qYx5e
# aDdYjbXTSO7oyiA47ls/ZsAOBKkh41IgPB9/1D3fa3XwDQmImuqNIzr+UAcNL1lC
# wuXycdne4KSuPXtsJIVTbiwvodXDZFZGlXew+ChCx3rpfOtlE+t7SyMlDvUujkR7
# y3/ouyTJkUX63KMjm5Y+9GKRoN1/vdw+lOm68i597EqHsEueK5sq67JBNhbZ+OmG
# dzj10XS0u6EDYhfqxkCuLGhCgB/2DV9HRkIeWquHy08P7yKoAiz4znF0XBHq1K7N
# xAZocQ6UU/0vAOUwDTcFdWOv7baX4LcXolyRNv5qQ98CXAowggbFMIIEraADAgEC
# AhMzAAEQB7JfAW3AtcBgAAAAARAHMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNTE1MTc1MDQ1
# WhcNMjYwNTE4MTc1MDQ1WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAr2LJ61/g
# YnFRuY9peqbvgo3sQvA7PRqazQn16PSaFdy16sJ9KKjR8jmqyFDiueZVUuRh94tt
# 3m7Wqry34dhFp1Xf+grajrMdQNkh3QmevtT9oKXSv27N7P/rjjGdAyx2F5Nd9I2T
# f2ArfHmHWpQxuCDjk+UuV19xcF9GIa8HkgJS6jEaKcaJ5QR2Hi1Rr9lIv3GmOEB8
# Au+Jz6AAzSdZHcYFYTMwv+QUO7lg7Suuze/JbdtfUyHjK4V746uTJuNCOW8LPgq/
# 5qYeDjFuv/W333rHFbYoIyGR8pbmmnT97tpRxvRQpp4pfrqazUqbPOF7TDlgaEps
# E0ThX3Q1wkuYsJakywElLOc6rJilkawNUUI4iIXyelKg/+c8LGb9mK2PTdZvYrAG
# P2+aKw6/3FvDBCvCZmNCiUxr1niEykzFN6BdHA09pMKZT4smdkx0w8g2PUlk1QnI
# +tqe07PXI4NZDsK+rWnMGrzPIeTv8n5qtBZQFL+uhdXcYPPj6mPgxpWpAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBQwat2ukhyLpm/JD4NOfdCL6xZXADAfBgNVHSMEGDAWgBRr
# XqU0wwXFYkohWo6rc2Bi1KxjhTBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwMy5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEArGmHo6zVXEkxr5MsyaHWDPauCXLIx8XUhC6/+Mw1/e/Mlxh5
# U1Pw5yFc3BRspQQbxgCcL4TTaIW5o34jGcWd2zZDrCou0pISfQ5KY01aUu24j2wI
# ujKS6pinrpl8oo62+kXirCNKB5bq/Rn8dIi/AikuZHXxP5iud2gq+wk/jOyAdUX7
# qQjEMG7EVMb4petMTcQHWam6YGvFQEKY4ZZuToB7Ar6fTLKenLQizKgg/We67BRk
# BdArzQxv3rVxyoS52KVlQMBro41hYdWQxjeT0ybYAxIo3FhtOq5vnaHPJd/8horV
# uAg38yTjuzRae8FoibJhrjydFO1V5vqAbLLlQX+RGRO79c7XtAIzicE6cXJIMAQh
# 0Q107F+qYx5eaDdYjbXTSO7oyiA47ls/ZsAOBKkh41IgPB9/1D3fa3XwDQmImuqN
# Izr+UAcNL1lCwuXycdne4KSuPXtsJIVTbiwvodXDZFZGlXew+ChCx3rpfOtlE+t7
# SyMlDvUujkR7y3/ouyTJkUX63KMjm5Y+9GKRoN1/vdw+lOm68i597EqHsEueK5sq
# 67JBNhbZ+OmGdzj10XS0u6EDYhfqxkCuLGhCgB/2DV9HRkIeWquHy08P7yKoAiz4
# znF0XBHq1K7NxAZocQ6UU/0vAOUwDTcFdWOv7baX4LcXolyRNv5qQ98CXAowggco
# MIIFEKADAgECAhMzAAAAFQU+bhmOkynZAAAAAAAVMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjYwMzI2MTgxMTI4WhcNMzEwMzI2MTgxMTI4WjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAzMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA4PTLPQKqLw5zHj7zDnvism4QnfPpaJM2DkZUt5AVV7Hn
# nG8hsAXLHp5ZuWy7TBj44iBS8wUBfoIZVVf1NvauRnHXhBAQh00xoS9pKCKy3OFK
# 5YjEXG7/ZjjLUf5e/8QJr9BceASR59XR7d+376wal5ioynxn+Q6cjv/oZ1e0xK3j
# LUtfYjvm42f/R56YNzwpNHu2Em0UxZMfexWcEVqQuLNzXqUX0V0If1jAI+yZrGHl
# WaIYuExecltiTKyWasB3MsyWWLQ9h5Z6OWRCZHYmXBGsRzqG5sDtOmdSfXNt6bPT
# xiIRmqtbCixAM/Q6HOay5GFhrXg67HCoQKdpCHP6GJR/SI+gZDqqoFiDRJBLQvGT
# RtTGpPod6OuWo9IkCpncVuyGWhzuXLsqDIvirWH13iCIN7FSG0thC/JFLbAxnRKj
# agKv4rKk4tY16i3uoiqdZ4tUj3bz1vRtNwk7GBevG/8riEEcG3aAQl3pjDSQktHa
# KwkWOG9lgAMuJ4O0gDXBIKwYGX+d+fkHy1OYRs6yoyKWzGm2rlm+RSllCpDLD3Fx
# ZF0VjuJ6Cj5uClpRcqajqWyfyjjVUXiJcR0EXoADgcyIUQe4K/SA0NbHNjIDoEPs
# VRluKKuBw9JnwIsIsi7JGa5GkOyaGp2IwTXEfUUtumMQFW3AbS4rRU8wiBIOWXUC
# AwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUa16lNMMFxWJKIVqOq3NgYtSsY4UwVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcw
# AoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIx
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEAXW4iPM8Fy1/IJSRIf/ENtlDAlIVgTuOm
# fRT4cDkd5nZakVS5GDqJ/zHM1MK4w4cd1/fUjx+T0n5ZBqE75zvWVhzOWBVWKTuz
# WLgfpn1UhgBmcIhjgElpNItge75/ZxJSSZqIl8boHx+WHQbK1IE7dABTV5M5qk4J
# PktR8W9bv9BwqhB1WT5NgP+niV2G7aUTORXM9NI4rFJfQUWYEnmzg1fOWwczr3qs
# gt39D5xwsUSTYTG/MT/7Af1SO6X9q4Xkle86lEr/L5/3yDG5V3mlSJaaqKvEj/QS
# TIxPwqFVycZ5GUETNRWu5Dfcs7b0XjocUoD4KWcf15f45MMhBVSUwXwad7E4HyHP
# 6Zqr9nobWpC9gBI+/BJjj0KIcSU98Ml/j+/BgNubS6QL8490TDB3fM9fGbrlYvut
# DAMxqTgEh9S/DZa932UWZ0Dvqcsntgwr2Jh2iH3VIGCap+56McRlb/PfkWhE4dbY
# Ag78DaRQkhu75eQOGpKPtn8eNPa/U1o1wuzon9SEOWScweEX/BrwYh2I7zJh6ZXn
# adRRkS3UkRVaQt/ziqWWOmryKmae/vKT/1kD/dNw3YK7wE+luMTzgcVz2uLRpLDd
# 0rqiWohWB0jcngbn5/IrHro1uCGwUmxw+AT6mxd6mfu5xvXf3fxtvy8eJB/XApgX
# 5rGXUpB5rpAwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
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
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENB
# IDAzAhMzAAEQB7JfAW3AtcBgAAAAARAHMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIHJRkKTc+0RL8vy+1S9eXur+xiUoMdcI77cbCJI1DL7nMA0GCSqGSIb3
# DQEBAQUABIIBgBminl0U758Z0rOk/uvAqsXv5sJINOxDITI9oiOAP7PLZ8xgipbQ
# V4gWPPkYrdFPvZbWC5TpePoTn09EBTiT7HLRxPZnIaHTsA+2WatsbZ/V7bRX8tcJ
# Qm9J9GvP8LL7EzoJvvPlvaPQrxMWztmWjlrC4Vh04N2gQXqIon54WgA9SU9CQFbJ
# 432F7DyalrDpwiMZfQ60tA96YWNvCZf1U+SD2SriYd8Jdhkpz0KW4u6uGNGjdUqX
# 9mn3PqylbT2vli4Gml5w7kCTp8AFe35toj9/IRAzGhHkvxXeE4UEbFq/u3fgvPD3
# YK+YFNYDIUwsAY7QHAqPS75X8b58O855bqldrGhETztf2iOuulrwzRr41IV0pFvu
# sWv816SR8J/DYuXDvMUlpYcmaMlhG+GPv5eTS2tdtDnrFD2XD42fVd2HKPkhGZPN
# u4E/367nNABu5Z8iX9f4C46uoJW1Bf2HNpKyRrOtRzE5/kWr+VEN2zpeY3wDK0+z
# 0VsgamWqWlkJEqGCGBEwghgNBgorBgEEAYI3AwMBMYIX/TCCF/kGCSqGSIb3DQEH
# AqCCF+owghfmAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFiBgsqhkiG9w0BCRABBKCC
# AVEEggFNMIIBSQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCA+fJAZ
# tfc5x1ewKpvYw5CLIT7+QwmmG5lNxToHbKMt2wIGaedYha1fGBMyMDI2MDUxNjE1
# NDU0NS45MDZaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
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
# guxAzhg/BpixPS4qrULLkAjO7+yNsUfrD2U9gMf/OR4yJDPtzM0ytTGCB0Mwggc/
# AgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjACEzMAAABXJNOV4KLpyTEAAAAAAFcwDQYJYIZIAWUDBAIBBQCgggSc
# MBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MDUxNjE1NDU0NVowLwYJKoZIhvcNAQkEMSIEIP62
# 8ongQiZHB1gH+VW50BsXBi+qKvZrjWxn7bzV+zZzMIG5BgsqhkiG9w0BCRACLzGB
# qTCBpjCBozCBoAQg9TyfZLUFbkxliGyizuH9VVDpVFNvQEQhKQ2ZhUx421IwfDBl
# pGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENB
# IDIwMjACEzMAAABXJNOV4KLpyTEAAAAAAFcwggNeBgsqhkiG9w0BCRACEjGCA00w
# ggNJoYIDRTCCA0EwggIpAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjc4MDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUA/S8xOZxCUQFBNkrN8Wiij1x5y8Og
# ZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDtssxJMCIYDzIwMjYwNTE2MTA1ODE3
# WhgPMjAyNjA1MTcxMDU4MTdaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO2yzEkC
# AQAwBwIBAAICNlswBwIBAAICEvwwCgIFAO20HckCAQAwNgYKKwYBBAGEWQoEAjEo
# MCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG
# 9w0BAQsFAAOCAQEAF5XBBI8KZ+TMH2eTUAGFcsg81kE86FCRFJ/SeZfR/AJiXhbO
# aX9obkrLfX6cbK52V2maV7WJBqbKaOKLjN7iFPcj845+1l0tpOZv8HrnhhOA+oQy
# z93MnRdYLXIK6KsUoGSed6h24grzTahYulCw5ADf4XH1TY9yKxbkpDLlINwLOhU1
# iyIeMiCAb6dif2wSGHqigCD1q73VGpTkUem+slkBoKyujTbNUJ6/hgjRSPH4EM6G
# DbxuMGRoscepI24U8YXLPqlu+E1lpq/kiV44LmlbGot9KwJGbd4uW9K7P6f371I/
# zZhOnTeZ/q0nUz8hZkGbIUm7QcBQB0iANWX7ADANBgkqhkiG9w0BAQEFAASCAgBg
# GaVm2ospRrod4VekrocdSW6ua+Gpy2/Q0b6FSy56unq2tyL84nxbavfPHZRnczuQ
# Ib+iIPdsrEj/uSpwkUZcX7/Tq9MvXqK5uBl9DlYlyRa5hmmOynauz5mqiBsV55yJ
# TU3q+HvxwvS6G34eV30WaU0XpqGlfdU0u0ZnKcUBsgtYJltrrwwM7HmmPOiPH9Yn
# IJv8AmDD+QnDnBGZLsOuqmVOAa5P/QIoInKpfYZaAkE8cdyRzbpPYbkTJseHrRRu
# 42f5woSL383xd7VS9UG+dQx4ZMEZksI7t/VIh2Uob3/1uHg4h5/6jr1jEum5O90+
# ZYFJd00Eut7ivcOCSyfP67dRlUBlnRpkta+GPsrVg++CKh/GJTY0mwYb/zlvz+VK
# qX15ETnxfcS/O1WRy77fVx89rm4SmId7i36Ov/zLvel/whLRT5PYcQRSsCXkhqTq
# 6UbpKmQPkyh6iicY4HAtNTi7dk1OQepdNBT8qRYPAaK9jxIDH3P2HVDxjLnjZc4h
# dPYd5eWvkchzRCtzg1ffbNvJDC/UW6S+nlJ9E01rvYaUQS/fVg7GWS4WwhaaFyGC
# Km95W3pQX2ij9nbkgfxfHy9LDPSjzZG9TVKnSdZpgYsrE84MboJiykm9rCmxDRSN
# yEtbYdbqAIWIHHLPvLLzIiwuopY0X/GxZCNlrYkiFw==
# SIG # End signature block
