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

# Targets: the kopia CLI binary plus every PowerShell helper used by scheduled tasks.
$targets = @(
    'C:\Users\david\go\bin\kopia.exe',
    "$repo\scripts\repo_status_check.ps1",
    "$repo\scripts\check_backup_errors.ps1"
)
foreach ($extra in 'check_backup_health.ps1','verify_helpers_preflight.ps1','get_kopia_password.ps1','get_kopia_server_password.ps1','start_kopia_server.ps1','heartbeat_watchdog.ps1','get_parent_pid.ps1') {
    $p = "$repo\scripts\$extra"
    if (Test-Path $p) { $targets += $p }
}

if (-not $VerifyOnly) {
    Write-Host "signtool : $signtool"
    Write-Host "dlib     : $dlib"
    Write-Host "metadata : $metadata"
    Write-Host ''

    foreach ($t in $targets) {
        if (-not (Test-Path $t)) { Write-Warning "Skipping (not found): $t"; continue }
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
