# pipeline-state.ps1 — shared helpers for cicd/ phase scripts.
# - Read/write cicd/.last-deploy JSON
# - Structured per-phase logging
# - Color-coded console output
#
# Sourced via: . "$PSScriptRoot\..\lib\pipeline-state.ps1"

$script:CicdRoot     = (Resolve-Path "$PSScriptRoot\..").Path
$script:StateFile    = Join-Path $CicdRoot '.last-deploy'

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
    return $raw | ConvertFrom-Json
}

function Set-PipelineState {
    param([Parameter(Mandatory)] $State)
    $json = $State | ConvertTo-Json -Depth 10
    Set-Content -Path $script:StateFile -Value $json -Encoding UTF8
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
        durationMs  = [int]((Get-Date) - $Run.StartTime).TotalMilliseconds
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

    if ($Status -eq 'failed') { $state.verdict = 'failure' }
    elseif ($Status -eq 'ok' -and $state.verdict -eq 'in_progress') { $state.verdict = 'in_progress' }

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
