# smoke-test.ps1 — Phase 6 of the cicd pipeline.
# Light dynamic check that the deployed system actually works.
#   - Refuses to run if any kopia.exe is already running (would conflict)
#   - Briefly starts kopia server, GETs /api/v1/repo/status, shuts down
#   - Runs verify_helpers_preflight.ps1 against freshly-signed helpers
#   - Queries Task Scheduler for "next run time" of \Backup\ tasks

[CmdletBinding()]
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\pipeline-state.ps1"

$run = Start-PhaseRun -Phase 'smoke-test'
Write-PhaseLog "[smoke-test] Phase 6 — light dynamic validation" -Level info

# Guard: refuse if kopia already running
$running = Get-Process -Name 'kopia' -ErrorAction SilentlyContinue
if ($running) {
    $lockedPids = ($running.Id -join ', ')
    Complete-PhaseRun -Run $run -Status 'failed' -Message "kopia.exe already running (PID $lockedPids)" `
        -RecommendedAction "stop the existing kopia process(es), then re-run make smoke-test"
    Write-PhaseLog "  [FAIL] kopia already running (PID $lockedPids)" -Level err
    exit 1
}

$failures = @()

# Check A — kopia server starts + repo status responds
$serverProc = $null
try {
    $kopiaExe = "$env:USERPROFILE\go\bin\kopia.exe"
    if (-not (Test-Path $kopiaExe)) { throw "kopia.exe missing at $kopiaExe" }

    # Start a transient server on a unique port to avoid colliding with a real one
    $port = 51515
    $serverProc = Start-Process -FilePath $kopiaExe `
        -ArgumentList @('server', 'start', "--address=127.0.0.1:$port", '--insecure', '--no-ui') `
        -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 4

    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/v1/repo/status" `
        -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck
    if ($resp.StatusCode -eq 200) {
        Write-PhaseLog "  [ok] kopia server: /api/v1/repo/status → 200" -Level ok
    } else {
        $failures += "kopia server: /api/v1/repo/status → HTTP $($resp.StatusCode)"
        Write-PhaseLog "  [FAIL] /api/v1/repo/status → HTTP $($resp.StatusCode)" -Level err
    }
} catch {
    $failures += "kopia server probe: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] kopia server: $($_.Exception.Message)" -Level err
} finally {
    if ($serverProc -and -not $serverProc.HasExited) {
        Stop-Process -Id $serverProc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}

# Check B — verify_helpers_preflight.ps1 against freshly-signed helpers
try {
    & 'C:\dev\kopia\scripts\verify_helpers_preflight.ps1'
    if ($LASTEXITCODE -ne 0) {
        $failures += "verify_helpers_preflight.ps1 exit $LASTEXITCODE"
        Write-PhaseLog "  [FAIL] verify_helpers_preflight returned $LASTEXITCODE" -Level err
    } else {
        Write-PhaseLog "  [ok] verify_helpers_preflight passed" -Level ok
    }
} catch {
    $failures += "verify_helpers_preflight: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] verify_helpers_preflight: $($_.Exception.Message)" -Level err
}

# Check C — every \Backup\ task has a future Next Run Time
try {
    $tasks = schtasks /query /fo csv /tn '\Backup\' 2>$null | ConvertFrom-Csv
    foreach ($t in $tasks) {
        if (-not $t.'TaskName' -or $t.'TaskName' -eq 'TaskName') { continue }
        if ($t.'Next Run Time' -eq 'N/A' -or $t.'Status' -eq 'Disabled') {
            $failures += "$($t.'TaskName') Status=$($t.'Status') NextRun=$($t.'Next Run Time')"
            Write-PhaseLog "  [FAIL] $($t.'TaskName'): $($t.'Status'), next run $($t.'Next Run Time')" -Level err
        } else {
            Write-PhaseLog "  [ok] $($t.'TaskName'): next $($t.'Next Run Time')" -Level ok
        }
    }
} catch {
    $failures += "task scheduler query: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] task query: $($_.Exception.Message)" -Level err
}

# Verdict
if ($failures) {
    $msg = "$($failures.Count) failure(s)"
    Complete-PhaseRun -Run $run -Status 'failed' -Message $msg
    Write-PhaseLog "[smoke-test] $msg" -Level err
    exit 1
} else {
    Complete-PhaseRun -Run $run -Status 'ok' -Message "server 200, helpers Valid, all tasks scheduled"
    Set-RunVerdict -Verdict 'success'
    Write-PhaseLog "[smoke-test] all checks passed" -Level ok
    exit 0
}
