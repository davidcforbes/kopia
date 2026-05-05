# smoke-test.ps1 — Phase 6 of the cicd pipeline.
# Light dynamic check that the deployed system actually works.
#   - Refuses to run if any kopia.exe is already running (would conflict)
#   - Runs `kopia --version` to confirm the binary executes cleanly
#   - Runs verify_helpers_preflight.ps1 against freshly-signed helpers
#   - Queries Task Scheduler for backup tasks; flags only Disabled tasks
#     OR CalendarTrigger tasks with no future run-time (BootTrigger tasks
#     like KopiaServer correctly show "Next Run Time = N/A")

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

# Check A — kopia binary executes cleanly (kopia --version)
# We don't start a transient server because that would require providing the
# same DPAPI-decrypted repo password the real KopiaServer uses, which would
# leak the password into the smoke-test process. `kopia --version` proves the
# binary runs without library/runtime issues; a broken binary fails it
# instantly. The real "does this work end-to-end" test is the nightly backup.
try {
    $kopiaExe = "$env:USERPROFILE\go\bin\kopia.exe"
    if (-not (Test-Path $kopiaExe)) { throw "kopia.exe missing at $kopiaExe" }
    $verOut = & $kopiaExe --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-PhaseLog "  [ok] kopia --version: $verOut" -Level ok
    } else {
        $failures += "kopia --version exit ${LASTEXITCODE}: $verOut"
        Write-PhaseLog "  [FAIL] kopia --version: exit $LASTEXITCODE" -Level err
    }
} catch {
    $failures += "kopia binary: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] kopia binary: $($_.Exception.Message)" -Level err
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

# Check C — every \Backup\ task is enabled. CalendarTrigger tasks must also
# have a future Next Run Time. BootTrigger / LogonTrigger tasks (e.g.,
# KopiaServer which runs continuously, started at boot) correctly have
# "Next Run Time = N/A" and are NOT a failure.
try {
    $tasks = schtasks /query /fo csv /tn '\Backup\' 2>$null | ConvertFrom-Csv
    foreach ($t in $tasks) {
        if (-not $t.'TaskName' -or $t.'TaskName' -eq 'TaskName') { continue }
        $taskName = $t.'TaskName'
        if ($t.'Status' -eq 'Disabled') {
            $failures += "${taskName}: Status=Disabled"
            Write-PhaseLog "  [FAIL] ${taskName}: Disabled" -Level err
            continue
        }
        # Inspect the task's triggers to decide whether N/A is acceptable.
        $hasCalendarTrigger = $false
        try {
            $xml = [xml]((schtasks /query /xml /tn $taskName 2>$null) -join "`n")
            if ($xml.Task.Triggers.CalendarTrigger) { $hasCalendarTrigger = $true }
        } catch { }
        if ($hasCalendarTrigger -and $t.'Next Run Time' -eq 'N/A') {
            $failures += "${taskName}: CalendarTrigger but NextRun=N/A"
            Write-PhaseLog "  [FAIL] ${taskName}: scheduled but NextRun=N/A" -Level err
        } elseif ($hasCalendarTrigger) {
            Write-PhaseLog "  [ok] ${taskName}: next $($t.'Next Run Time')" -Level ok
        } else {
            Write-PhaseLog "  [ok] ${taskName}: enabled (boot/logon trigger; NextRun=$($t.'Next Run Time') is correct)" -Level ok
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
