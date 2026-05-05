# pipeline-state.ps1 — shared helpers for cicd/ phase scripts.
# - Read/write cicd/.last-deploy JSON
# - Structured per-phase logging
# - Color-coded console output
#
# Sourced via: . "$PSScriptRoot\..\lib\pipeline-state.ps1"

$script:CicdRoot     = (Resolve-Path "$PSScriptRoot\..").Path
$script:StateFile    = Join-Path $CicdRoot '.last-deploy'

# State is a pscustomobject (for dot-property access on top-level fields like
# $state.verdict). state.phases is an [ordered] hashtable so phase insertion
# order survives JSON round-trips.
function Get-PipelineState {
    if (-not (Test-Path $script:StateFile)) {
        return [pscustomobject]@{
            runId   = $null
            trigger = $null
            verdict = $null
            phases  = [ordered]@{}
        }
    }
    $raw = Get-Content $script:StateFile -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{ runId = $null; trigger = $null; verdict = $null; phases = [ordered]@{} }
    }
    try {
        return $raw | ConvertFrom-Json
    } catch {
        throw "cicd/.last-deploy is corrupt: $($_.Exception.Message). Delete the file (or restore from backup) to continue."
    }
}

function Set-PipelineState {
    param([Parameter(Mandatory)] $State)
    $json = $State | ConvertTo-Json -Depth 10
    $tmp  = "$script:StateFile.tmp"
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Path $tmp -Destination $script:StateFile -Force
}

function Start-PhaseRun {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [string]$Trigger = $MyInvocation.PSCommandPath
    )
    $state = Get-PipelineState
    if (-not $state.runId -or $state.verdict -in @('success', 'failure')) {
        # Start a new run
        $state = [pscustomobject]@{
            runId   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
            trigger = $Trigger
            verdict = 'in_progress'
            phases  = [ordered]@{}
        }
    }
    # Record a placeholder so a crash mid-phase still leaves a marker in the state file
    $phases = [ordered]@{}
    if ($state.phases) {
        $state.phases.PSObject.Properties | ForEach-Object { $phases[$_.Name] = $_.Value }
    }
    $phases[$Phase] = [ordered]@{
        status     = 'running'
        durationMs = 0
        message    = 'phase started'
        timestamp  = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    }
    $state.phases = $phases
    Set-PipelineState $state
    return [pscustomobject]@{
        Phase     = $Phase
        StartTime = Get-Date
    }
}

function Complete-PhaseRun {
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)][ValidateSet('ok', 'failed', 'skipped')] $Status,
        [Parameter(Mandatory)][string] $Message,
        [string] $RecommendedAction
    )
    $state = Get-PipelineState
    $entry = [ordered]@{
        status      = $Status
        durationMs  = [long]((Get-Date) - $Run.StartTime).TotalMilliseconds
        message     = $Message
        timestamp   = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    }
    if ($RecommendedAction) { $entry.recommendedAction = $RecommendedAction }

    # PSObject -> hashtable mutation
    $phases = [ordered]@{}
    if ($state.phases) {
        $state.phases.PSObject.Properties | ForEach-Object { $phases[$_.Name] = $_.Value }
    }
    $phases[$Run.Phase] = $entry
    $state.phases = $phases

    # Verdict is sticky: once any phase fails, the run verdict stays 'failure'
    # regardless of subsequent phases. Set-RunVerdict is the only way to reach 'success'.
    if ($Status -eq 'failed') { $state.verdict = 'failure' }

    Set-PipelineState $state
}

function Write-PhaseLog {
    param([string]$Message, [ValidateSet('info','ok','warn','err')]$Level = 'info')
    $color = switch ($Level) {
        'ok'   { 'Green' }
        'warn' { 'Yellow' }
        'err'  { 'Red' }
        default { 'White' }
    }
    Write-Host $Message -ForegroundColor $color
}

function Set-RunVerdict {
    param([Parameter(Mandatory)][ValidateSet('success','failure','in_progress')]$Verdict)
    $state = Get-PipelineState
    $state.verdict = $Verdict
    Set-PipelineState $state
}
