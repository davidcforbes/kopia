param(
    [ValidateSet('Inline', 'Surveillance')] [string]$Mode = 'Inline',
    [string]$StateFile = 'C:\dev\kopia\cicd\.last-deploy',
    [int]$StaleHours = 24,
    [string]$AppId = 'RustBack.HealthCheck',
    [string]$LaunchProto = 'rustback:open'
)

# REQUIRES Windows PowerShell 5.1 (NOT pwsh 7+). The WinRT type-loading idiom
# below is PS 5.1 only. Invoke explicitly via:
#   C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -File ...

[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,        ContentType=WindowsRuntime]

function Show-Toast([string]$Title, [string]$Body) {
    $enc = [System.Security.SecurityElement]
    $titleX = $enc::Escape($Title)
    $bodyX  = $enc::Escape($Body)
    $launch = $enc::Escape($LaunchProto)
    $xml = "<toast launch=`"$launch`" activationType=`"protocol`"><visual><binding template=`"ToastGeneric`"><text>$titleX</text><text>$bodyX</text></binding></visual></toast>"
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
}

# State file may be missing (no deploys ever)
if (-not (Test-Path $StateFile)) {
    if ($Mode -eq 'Surveillance') { exit 0 }
    Show-Toast 'Kopia CI/CD: NO STATE' "$StateFile not found - has 'make release-and-deploy' ever run?"
    exit 1
}

# Parse state
$state = $null
try { $state = Get-Content $StateFile -Raw | ConvertFrom-Json } catch {
    Show-Toast 'Kopia CI/CD: STATE CORRUPT' "$StateFile parse failed: $($_.Exception.Message)"
    exit 1
}

$verdict = [string]$state.verdict
$runIdStr = [string]$state.runId
$ageHours = -1
if ($runIdStr) {
    try { $ageHours = [int](((Get-Date) - [DateTimeOffset]::Parse($runIdStr).LocalDateTime).TotalHours) } catch { }
}
$ageStr = if ($ageHours -ge 0) { "${ageHours}h ago" } else { '?' }

# Failed-phase summary
$failedPhases = @()
if ($state.phases) {
    foreach ($p in $state.phases.PSObject.Properties) {
        if ($p.Value.status -eq 'failed') { $failedPhases += "$($p.Name): $($p.Value.message)" }
    }
}

$isFailure = ($verdict -eq 'failure')
$isStale   = ($ageHours -ge 0 -and $ageHours -ge $StaleHours)

# Surveillance mode is silent on fresh+green
if ($Mode -eq 'Surveillance' -and -not $isFailure -and -not $isStale) { exit 0 }

# Build toast
$title = if ($isFailure) {
    'Kopia CI/CD: FAIL'
} elseif ($isStale) {
    "Kopia CI/CD: STALE (last run $ageStr)"
} elseif ($verdict -eq 'success') {
    'Kopia CI/CD: PASS'
} elseif ($verdict -eq 'in_progress') {
    'Kopia CI/CD: IN PROGRESS (incomplete run?)'
} else {
    "Kopia CI/CD: $verdict"
}

$bodyParts = @()
if ($failedPhases.Count -gt 0) {
    $bodyParts += $failedPhases[0]
    if ($failedPhases.Count -gt 1) { $bodyParts += "(+$($failedPhases.Count - 1) more)" }
} else {
    $phaseCount = 0
    if ($state.phases) { $phaseCount = @($state.phases.PSObject.Properties).Count }
    $bodyParts += "$phaseCount phases ok"
}
$bodyParts += "Last run: $ageStr"
$body = $bodyParts -join ' | '

Show-Toast $title $body

if ($isFailure) { exit 1 } else { exit 0 }
