# deploy-artifacts.ps1 — Phase 3 of the cicd pipeline.
# Copies signed kopia.exe from build location to runtime locations, refusing
# to overwrite if any kopia.exe process holds the destination.
#
# Idempotent: if dest is already byte-identical to source AND has Status=Valid,
# the copy is skipped. Re-running on an already-deployed system is a no-op.

[CmdletBinding()]
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\pipeline-state.ps1"

$run = Start-PhaseRun -Phase 'deploy-artifacts'
Write-PhaseLog "[deploy-artifacts] Phase 3 — placing signed binaries at runtime locations" -Level info

$source = "$env:USERPROFILE\go\bin\kopia.exe"
$destinations = @(
    'D:\KopiaServer\bin\kopia.exe',
    'C:\dev\kopia\dist\kopia-ui\win-unpacked\resources\server\kopia.exe'
)

# Source must exist + be signed Valid
if (-not (Test-Path $source)) {
    Complete-PhaseRun -Run $run -Status 'failed' -Message "source not found: $source" `
        -RecommendedAction "make release   (rebuilds + signs kopia.exe)"
    Write-PhaseLog "  [FAIL] source missing: $source" -Level err
    exit 1
}

try {
    $srcSig = Get-AuthenticodeSignature $source -ErrorAction Stop
} catch {
    Complete-PhaseRun -Run $run -Status 'failed' -Message "source unreadable: $($_.Exception.Message)" `
        -RecommendedAction "wait for any in-flight 'make release' / signtool to finish, then re-run make deploy-artifacts"
    Write-PhaseLog "  [FAIL] cannot read source signature ($source): $($_.Exception.Message)" -Level err
    exit 1
}
if ($srcSig.Status -ne 'Valid') {
    Complete-PhaseRun -Run $run -Status 'failed' -Message "source signature: $($srcSig.Status)" `
        -RecommendedAction "make release   (rebuilds + signs kopia.exe)"
    Write-PhaseLog "  [FAIL] source not Valid: $source ($($srcSig.Status))" -Level err
    exit 1
}

try {
    $srcHash = (Get-FileHash $source -Algorithm SHA256 -ErrorAction Stop).Hash
} catch {
    Complete-PhaseRun -Run $run -Status 'failed' -Message "source hash failed: $($_.Exception.Message)" `
        -RecommendedAction "wait for any in-flight 'make release' / signtool to finish, then re-run make deploy-artifacts"
    Write-PhaseLog "  [FAIL] cannot hash source ($source): $($_.Exception.Message)" -Level err
    exit 1
}
Write-PhaseLog "  source: $source ($([int]((Get-Item $source).Length/1MB)) MB, $srcHash)" -Level info

$copied = @()
$skipped = @()
$errors = @()

foreach ($dest in $destinations) {
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) {
        Write-PhaseLog "  [skip] $dest (parent $destDir not present — destination disabled on this host)" -Level warn
        $skipped += "$dest (parent missing)"
        continue
    }

    # Refuse if held by a running process
    $procs = Get-Process -Name 'kopia' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $dest }
    if ($procs) {
        $lockedPids = ($procs.Id -join ', ')
        $errors += "$dest is locked by kopia.exe (PID $lockedPids)"
        Write-PhaseLog "  [FAIL] $dest locked by PID $lockedPids" -Level err
        continue
    }

    # Idempotency: skip if already identical
    if (Test-Path $dest) {
        $destHash = (Get-FileHash $dest -Algorithm SHA256).Hash
        if ($destHash -eq $srcHash) {
            $destSig = Get-AuthenticodeSignature $dest
            if ($destSig.Status -eq 'Valid') {
                Write-PhaseLog "  [ok] $dest already current (hash + sig match)" -Level ok
                $skipped += "$dest (already current)"
                continue
            }
        }
    }

    if ($VerifyOnly) {
        Write-PhaseLog "  [would-copy] $dest" -Level info
        continue
    }

    try {
        Copy-Item $source $dest -Force
        $verifySig = Get-AuthenticodeSignature $dest
        if ($verifySig.Status -ne 'Valid') {
            throw "post-copy signature: $($verifySig.Status)"
        }
        Write-PhaseLog "  [ok] copied -> $dest" -Level ok
        $copied += $dest
    } catch {
        $errors += "$dest`: $($_.Exception.Message)"
        Write-PhaseLog "  [FAIL] $dest`: $($_.Exception.Message)" -Level err
    }
}

if ($errors) {
    $msg = "$($errors.Count) error(s); $($copied.Count) copied; $($skipped.Count) skipped"
    Complete-PhaseRun -Run $run -Status 'failed' -Message $msg `
        -RecommendedAction "stop the kopia.exe process holding the destination, then re-run make deploy-artifacts"
    Write-PhaseLog "[deploy-artifacts] $msg" -Level err
    exit 1
} else {
    $msg = "$($copied.Count) copied; $($skipped.Count) skipped"
    Complete-PhaseRun -Run $run -Status 'ok' -Message $msg
    Write-PhaseLog "[deploy-artifacts] $msg" -Level ok
    exit 0
}
