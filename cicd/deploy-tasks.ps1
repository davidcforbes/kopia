# deploy-tasks.ps1 — Phase 4 of the cicd pipeline.
# Reconciles registered Task Scheduler tasks under \Backup\ against the
# desired-state XMLs in scripts/scheduled-tasks/.
#
# For each .xml in scripts/scheduled-tasks/:
#   - If task not registered: schtasks /create
#   - If registered but XML differs: schtasks /delete + /create
#   - If currently running: skip (don't disrupt active backups)
# Idempotent: a no-drift run is fast and silent.

[CmdletBinding()]
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\pipeline-state.ps1"

$run = Start-PhaseRun -Phase 'deploy-tasks'
Write-PhaseLog "[deploy-tasks] Phase 4 — reconciling Task Scheduler entries" -Level info

$desiredDir = 'C:\dev\kopia\scripts\scheduled-tasks'
if (-not (Test-Path $desiredDir)) {
    Complete-PhaseRun -Run $run -Status 'failed' -Message "missing $desiredDir" `
        -RecommendedAction "see plan Task 5 step 2 — seed scripts/scheduled-tasks/ from current registrations"
    Write-PhaseLog "  [FAIL] $desiredDir not present" -Level err
    exit 1
}

$created  = @()
$updated  = @()
$current  = @()
$skipped  = @()
$errors   = @()

# Normalize XML for comparison (strip whitespace + dynamic Date fields)
function Normalize-Xml([string]$xmlText) {
    $doc = [xml]$xmlText
    # Remove RegistrationInfo/Date which schtasks updates on every change
    $regInfo = $doc.SelectSingleNode("//*[local-name()='RegistrationInfo']/*[local-name()='Date']")
    if ($regInfo) { $regInfo.ParentNode.RemoveChild($regInfo) | Out-Null }
    $sw = New-Object IO.StringWriter
    $w  = New-Object Xml.XmlTextWriter($sw)
    $w.Formatting = 'None'
    $doc.WriteTo($w)
    return $sw.ToString()
}

foreach ($file in Get-ChildItem $desiredDir -Filter '*.xml') {
    $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $taskPath = "\Backup\$name"
    $desired = Get-Content $file.FullName -Raw

    # Is it currently running?
    try {
        $info = schtasks /query /tn $taskPath /v /fo csv 2>$null | Select-Object -Skip 1
        if ($info) {
            $statusField = ($info -split ',')[3] -replace '"', ''
            if ($statusField -match 'Running') {
                Write-PhaseLog "  [skip] $taskPath — currently Running, will reconcile next time" -Level warn
                $skipped += "$taskPath (running)"
                continue
            }
        }
    } catch { }

    # Compare to current registration
    $registered = $null
    schtasks /query /xml /tn $taskPath 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $registered = (schtasks /query /xml /tn $taskPath) -join "`n"
    }

    if ($registered -and (Normalize-Xml $registered) -eq (Normalize-Xml $desired)) {
        Write-PhaseLog "  [ok] $taskPath current" -Level ok
        $current += $taskPath
        continue
    }

    if ($VerifyOnly) {
        Write-PhaseLog "  [would-update] $taskPath" -Level info
        continue
    }

    try {
        # /create /f is force-overwrite-existing; safer than /delete + /create which can
        # leave the task in a deleted-but-not-recreated state if /create fails (e.g., on
        # HighestAvailable tasks that require elevation).
        schtasks /create /tn $taskPath /xml $file.FullName /f 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "schtasks /create /f returned $LASTEXITCODE (likely needs an elevated shell for HighestAvailable tasks)"
        }
        if ($registered) {
            $updated += $taskPath; Write-PhaseLog "  [ok] updated $taskPath" -Level ok
        } else {
            $created += $taskPath; Write-PhaseLog "  [ok] created $taskPath" -Level ok
        }
    } catch {
        $errors += "${taskPath}: $($_.Exception.Message)"
        Write-PhaseLog "  [FAIL] ${taskPath}: $($_.Exception.Message)" -Level err
    }
}

if ($errors) {
    $msg = "$($errors.Count) error(s); $($created.Count) created; $($updated.Count) updated; $($current.Count) current; $($skipped.Count) skipped"
    Complete-PhaseRun -Run $run -Status 'failed' -Message $msg
    Write-PhaseLog "[deploy-tasks] $msg" -Level err
    exit 1
} else {
    $msg = "$($created.Count) created; $($updated.Count) updated; $($current.Count) current; $($skipped.Count) skipped"
    Complete-PhaseRun -Run $run -Status 'ok' -Message $msg
    Write-PhaseLog "[deploy-tasks] $msg" -Level ok
    exit 0
}
