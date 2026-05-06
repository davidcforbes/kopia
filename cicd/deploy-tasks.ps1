# deploy-tasks.ps1 — Phase 4 of the cicd pipeline.
# Reconciles registered Task Scheduler tasks under \Backup\ against the
# desired-state XMLs in scripts/scheduled-tasks/.
#
# For each .xml in scripts/scheduled-tasks/:
#   - If task is currently Running: skip (don't disrupt active backups)
#   - If task not registered or XML differs from desired: schtasks /create /f
#     (atomic force-overwrite — keeps prior registration intact if /create
#     fails on elevation requirement)
#   - If registered XML matches desired: [ok] current
# Idempotent: a no-drift run is fast and silent.
#
# IMPORTANT: The XMLs in scripts/scheduled-tasks/ are PER-HOST SNAPSHOTS.
# They hardcode the user SID (S-1-5-21-...) and absolute paths
# (C:\dev\kopia\scripts\...). They are committed for reproducibility on
# THIS machine, not for portability. On a fresh host, regenerate them via:
#   schtasks /query /xml /tn '\Backup\<name>' > scripts/scheduled-tasks/<name>.xml
# (after registering each task once with the new host's SID/paths).
#
# Tasks with RunLevel=HighestAvailable (e.g., WbadminHealthCheck, KopiaServer)
# require an elevated PowerShell session for schtasks /create /f to succeed.
# A non-elevated invocation safely reports those as failed without modifying
# state — the prior registration stays intact (atomic /create /f semantic).
#
# Iteration order: alphabetical via Get-ChildItem default. Tasks are
# independent — no creation-order dependency exists today.
#
# Encoding-declaration quirk: the XMLs declare <?xml ... encoding="UTF-16"?>
# but the bytes on disk are actually ASCII (no BOM). This is what schtasks
# /query /xml emits, and — surprisingly — schtasks /create /xml only accepts
# files with that exact declaration; switching it to "UTF-8" makes schtasks
# reject the file with "ERROR: unable to switch the encoding". PowerShell's
# [xml] cast is lenient enough to parse it either way, so we leave the
# declaration alone and accept the lie. Don't "fix" it.

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
    # Remove RegistrationInfo/Date which schtasks updates on every change.
    $regInfo = $doc.SelectSingleNode("//*[local-name()='RegistrationInfo']/*[local-name()='Date']")
    if ($regInfo) { $regInfo.ParentNode.RemoveChild($regInfo) | Out-Null }
    # Remove RegistrationInfo/Description from drift comparison. Description
    # text is informational only — it doesn't affect scheduling, triggers, or
    # actions. AND its byte representation drifts permanently between the
    # canonical .xml file (UTF-8 bytes parsed as the literal characters) and
    # the live-registered task (schtasks emits UTF-16-with-cp1252-bytes that
    # PowerShell's [xml] parser substitutes with U+FFFD). The mismatch can
    # only be reconciled by re-registering, which needs elevation. Stripping
    # makes drift detection scheduling-relevant only. (kopia-njz)
    $desc = $doc.SelectSingleNode("//*[local-name()='RegistrationInfo']/*[local-name()='Description']")
    if ($desc) { $desc.ParentNode.RemoveChild($desc) | Out-Null }
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
        $rows = schtasks /query /tn $taskPath /v /fo csv 2>$null | ConvertFrom-Csv
        if ($rows | Where-Object { $_.Status -eq 'Running' }) {
            Write-PhaseLog "  [skip] $taskPath — currently Running, will reconcile next time" -Level warn
            $skipped += "$taskPath (running)"
            continue
        }
    } catch {
        # I3: log instead of silently swallowing — schtasks missing or path
        # syntax change in a future Windows would otherwise mask real failures.
        Write-PhaseLog "  [warn] running-task probe failed for ${taskPath}: $($_.Exception.Message)" -Level warn
    }

    # Compare to current registration
    $registered = schtasks /query /xml /tn $taskPath 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) { $registered = $null }

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
        $out = & schtasks /create /tn $taskPath /xml $file.FullName /f 2>&1
        if ($LASTEXITCODE -ne 0) {
            $stderr = ($out | Out-String).Trim()
            throw "schtasks /create /f returned ${LASTEXITCODE}: $stderr (likely needs an elevated PowerShell session for HighestAvailable tasks)"
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
