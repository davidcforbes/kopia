# connect_wrapper_config.ps1 — one-shot setup for the wrapper's separate
# kopia client config (epic kopia-0m5).
#
# Background: daily_kopia_backup.cmd shares %APPDATA%\kopia\repository.config
# with KopiaUI. Both use the same cacheDirectory and race on temp-file
# renames inside server-contents/ ("Access is denied" warnings, hundreds
# per nightly). The fix is a SEPARATE client config for the wrapper with
# its own cacheDirectory baked in at connect time.
#
# This script is IDEMPOTENT — running it twice is safe. If the wrapper
# config already exists with a working connection, it's a no-op.
#
# Usage: pwsh -NoProfile -ExecutionPolicy Bypass -File this-script.ps1
#
# Requires: KopiaServer task running (the wrapper config connects to it).
# Decrypts the server password via DPAPI from scripts\.kopia-server-pw.dat.

[CmdletBinding()]
param(
    [string]$WrapperConfig = 'C:\Users\david\AppData\Roaming\kopia\wrapper.config',
    [string]$WrapperCache  = 'C:\Users\david\AppData\Local\kopia-wrapper-cache',
    [string]$ServerUrl     = 'https://127.0.0.1:51515',
    [string]$Fingerprint   = '16db248994adcec841b8c0c24ee79b892da86e030608764705d2a0272fdde2d2',
    [string]$Username      = 'david',
    [string]$Hostname      = 'chrislaptop2',
    [string]$KopiaBin      = 'C:\Users\david\go\bin\kopia.exe',
    [string]$ServerPwVault = 'C:\dev\kopia\scripts\.kopia-server-pw.dat'
)

$ErrorActionPreference = 'Stop'

Write-Host "[connect-wrapper] target config: $WrapperConfig"
Write-Host "[connect-wrapper] cache dir:    $WrapperCache"

# Idempotency: if config already exists and connects, exit clean
if (Test-Path $WrapperConfig) {
    & $KopiaBin --config-file=$WrapperConfig repository status 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[connect-wrapper] $WrapperConfig already exists and connects — no-op" -ForegroundColor Green
        exit 0
    }
    Write-Host "[connect-wrapper] $WrapperConfig exists but doesn't connect — will recreate"
    Remove-Item $WrapperConfig -Force
}

# Decrypt the server password from DPAPI vault
if (-not (Test-Path $ServerPwVault)) {
    throw "Server password vault not found: $ServerPwVault"
}
Write-Host "[connect-wrapper] decrypting server password from DPAPI vault"
$encrypted = [System.IO.File]::ReadAllBytes($ServerPwVault)
$plaintext = [System.Text.Encoding]::UTF8.GetString(
    [System.Security.Cryptography.ProtectedData]::Unprotect(
        $encrypted, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )
)
if (-not $plaintext) { throw "DPAPI decrypt produced empty result" }

# Run kopia repository connect server with the wrapper-specific config + cache
Write-Host "[connect-wrapper] connecting to $ServerUrl"
$env:KOPIA_PASSWORD = $plaintext
try {
    & $KopiaBin --config-file=$WrapperConfig repository connect server `
        --url=$ServerUrl `
        --server-cert-fingerprint=$Fingerprint `
        --override-username=$Username `
        --override-hostname=$Hostname `
        --cache-directory=$WrapperCache 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "kopia repository connect returned exit $LASTEXITCODE" }
} finally {
    $env:KOPIA_PASSWORD = $null
    $plaintext = $null
}

# Verify the new config works
Write-Host ""
Write-Host "[connect-wrapper] verifying new config..."
& $KopiaBin --config-file=$WrapperConfig repository status 2>&1 | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { throw "wrapper.config repository status returned exit $LASTEXITCODE" }

Write-Host ""
Write-Host "[connect-wrapper] OK — wrapper config ready" -ForegroundColor Green
Write-Host "  Config:  $WrapperConfig"
Write-Host "  Cache:   $WrapperCache  (will be auto-created on first use)"
