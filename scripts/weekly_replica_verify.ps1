# weekly_replica_verify.ps1 - Open the replicated kopia repo on E: read-only,
# sample-verify content, then disconnect. Catches silent corruption of the
# replica before D: actually dies.
#
# Reads E:\KopiaRepo via a dedicated config file (NOT the default API-mode
# repository.config - connecting via the default would replace the upstream
# server connection that everything else uses). The replica is byte-identical
# to D:\KopiaRepo so the same DPAPI vault password (kopia-pw.dat) opens it.
#
# Scheduled weekly Sat 06:30 by \Backup\WeeklyReplicaVerify (kopia-ht4).
#
# Pre-flight defers if a daily_d_replica robocopy is currently running, since
# verifying a partially-written replica would produce false negatives.

[CmdletBinding()]
param(
    [string]$ReplicaRoot     = 'E:\KopiaRepo',
    [string]$ConfigFile      = 'C:\Users\david\AppData\Roaming\kopia\replica_verify.config',
    [string]$CacheDir        = 'C:\Users\david\AppData\Local\kopia-replica-verify-cache',
    [string]$KopiaBin        = 'C:\Users\david\go\bin\kopia.exe',
    [string]$LogFile         = 'C:\dev\kopia\logs\weekly_replica_verify.log',
    [string]$DailyKopiaLog   = 'C:\dev\kopia\logs\daily_kopia.log',
    [string]$FlagFile        = 'C:\dev\kopia\logs\BACKUP_REPLICA_VERIFY_FAIL.flag',
    [string]$AppId           = 'KopiaBackup.HealthCheck',
    [string]$LaunchProto     = 'kopiamonitor:open',
    [double]$DownloadPercent = 1.0,
    [int]$Parallel           = 4,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---- Log rotation ----
if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 1MB)) {
    $old = "$LogFile.old"
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    Move-Item -LiteralPath $LogFile -Destination $old -Force
}

function Write-Log {
    param([Parameter(Mandatory)] [string]$Message, [string]$Tag = 'verify')
    $line = '{0} - [{1}] {2}' -f (Get-Date -Format 'ddd MM/dd/yyyy HH:mm:ss.ff'), $Tag, $Message
    Add-Content -LiteralPath $LogFile -Value $line
    Write-Host $line
}

function Show-Toast {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Body
    )
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,        ContentType=WindowsRuntime]
        $enc    = { param($s) [System.Security.SecurityElement]::Escape($s) }
        $titleX = & $enc $Title
        $bodyX  = & $enc $Body
        $launch = & $enc $LaunchProto
        $xml = @"
<toast launch="$launch" activationType="protocol">
  <visual>
    <binding template="ToastGeneric">
      <text>$titleX</text>
      <text>$bodyX</text>
    </binding>
  </visual>
  <actions>
    <action content="Open Backup Monitor" activationType="protocol" arguments="$launch" />
  </actions>
</toast>
"@
        $doc = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $doc.LoadXml($xml)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
    } catch {
        Write-Log "toast emission failed: $_" 'toast'
    }
}

function Append-Summary {
    param([Parameter(Mandatory)] [hashtable]$Fields)
    $parts = $Fields.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }
    $line  = '{0} - replica verify summary {1}' -f (Get-Date -Format 'ddd MM/dd/yyyy HH:mm:ss.ff'), ($parts -join ' ')
    Add-Content -LiteralPath $DailyKopiaLog -Value $line
}

function Touch-FailFlag {
    param([Parameter(Mandatory)] [string]$Reason)
    "$(Get-Date -Format s) | $Reason" | Set-Content -LiteralPath $FlagFile
}

function Clear-FailFlag {
    if (Test-Path -LiteralPath $FlagFile) { Remove-Item -LiteralPath $FlagFile -Force }
}

# Invoke a native command, tag-logging each line, returning its exit code.
# With $ErrorActionPreference='Stop' at script scope, `cmd 2>&1 | ...` re-throws
# any stderr line as an ErrorRecord before the pipeline can process it.
# Kopia writes informational messages (e.g. "Connected to repository.") to
# stderr even on success, which would falsely trigger the catch block. This
# helper isolates the call with 'Continue' so stderr lines flow through.
# Empty/whitespace-only lines from kopia (it emits blank padding around
# progress sections) are filtered out -- Write-Log's [Parameter(Mandatory)]
# [string]$Message rejects empty strings, which produced a false-FAIL flag
# on 2026-05-11 (kopia-4cs) even though the underlying connect+verify
# succeeded.
function Invoke-Logged {
    param(
        [Parameter(Mandatory)] [string]$Exe,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [string]$Tag = 'cmd'
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object {
            $line = "$_"   # coerce ErrorRecord / other types to string
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log $line $Tag
            }
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

Write-Log "============================================"
Write-Log "Weekly D: replica verify start (replica=$ReplicaRoot dryRun=$DryRun)" 'start'

$startTime = Get-Date
$connected = $false
$summary = @{
    replica          = $ReplicaRoot
    download_percent = $DownloadPercent
    parallel         = $Parallel
    errors           = 1   # default fail; cleared on PASS
    sample_bytes     = 0
    duration_s       = 0
    deferred         = 'no'
}

try {
    # ---- Preflight: kopia binary ----
    if (-not (Test-Path -LiteralPath $KopiaBin)) {
        throw "kopia.exe not found: $KopiaBin"
    }

    # ---- Preflight: replica volume ----
    if (-not (Test-Path -LiteralPath $ReplicaRoot)) {
        throw "replica not found: $ReplicaRoot (E: not mounted, or initial seed not run)"
    }

    # ---- Preflight: defer if a daily replica is currently in progress ----
    # Verifying mid-mirror would see partial state and produce false negatives.
    $robo = Get-Process robocopy -ErrorAction SilentlyContinue
    if ($robo) {
        $summary.deferred = 'yes'
        $summary.errors   = 0   # not a failure, just a defer
        # ASCII hyphen below is deliberate. PS 5.1 reads no-BOM scripts as
        # Windows-1252 and the third byte (0x94) of an em-dash maps to a
        # smart-quote that terminates the surrounding double-quoted string.
        # Em-dashes are only safe in single-quoted strings and comments.
        Write-Log "DEFER: robocopy.exe running (PID $($robo.Id -join ',')) -- daily replica in progress; verify will skip this week" 'defer'
        return   # finally still runs, summary line still written
    }

    # ---- Preflight: cache dir ----
    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
        Write-Log "created cache dir: $CacheDir" 'preflight'
    }

    # ---- Preflight: stale config? Disconnect quietly first. ----
    if (Test-Path -LiteralPath $ConfigFile) {
        Write-Log "stale config from prior run - attempting clean disconnect" 'preflight'
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & $KopiaBin "--config-file=$ConfigFile" repository disconnect 2>&1 | Out-Null }
        finally { $ErrorActionPreference = $prev }
        if (Test-Path -LiteralPath $ConfigFile) { Remove-Item -LiteralPath $ConfigFile -Force }
    }

    # ---- Resolve repo password from DPAPI vault ----
    $pwScript = Join-Path (Split-Path -Parent $PSCommandPath) 'get_kopia_password.ps1'
    if (-not (Test-Path -LiteralPath $pwScript)) {
        throw "get_kopia_password.ps1 not found at $pwScript"
    }
    $env:KOPIA_PASSWORD = (& $pwScript | Select-Object -First 1)
    if (-not $env:KOPIA_PASSWORD) { throw "DPAPI vault returned empty password" }
    Write-Log "KOPIA_PASSWORD resolved from DPAPI vault" 'preflight'

    if ($DryRun) {
        Write-Log "DRY-RUN: would connect/verify/disconnect against $ReplicaRoot; skipping" 'verify'
        $summary.errors = 0
        return
    }

    # ---- Connect to replica (read-only, dedicated config + cache) ----
    Write-Log "connecting to $ReplicaRoot (read-only)" 'connect'
    $connectArgs = @(
        "--config-file=$ConfigFile"
        'repository'
        'connect'
        'filesystem'
        "--path=$ReplicaRoot"
        "--cache-directory=$CacheDir"
        '--readonly'
    )
    $rc = Invoke-Logged -Exe $KopiaBin -Arguments $connectArgs -Tag 'connect'
    if ($rc -ne 0) { throw "kopia connect failed (exit=$rc)" }
    $connected = $true

    # ---- Verify content (sampling) ----
    # `kopia content verify` uses --download-percent (0.0..100.0), not the
    # planned --max-bytes (that flag doesn't exist in this kopia version,
    # confirmed via `kopia content verify --help-long`).
    Write-Log "verifying content: download-percent=$DownloadPercent parallel=$Parallel" 'verify'
    $verifyArgs = @(
        "--config-file=$ConfigFile"
        'content'
        'verify'
        "--download-percent=$DownloadPercent"
        "--parallel=$Parallel"
    )
    $rc = Invoke-Logged -Exe $KopiaBin -Arguments $verifyArgs -Tag 'verify'
    if ($rc -ne 0) { throw "kopia content verify failed (exit=$rc)" }
    $summary.errors = 0
    Write-Log "PASS" 'result'
}
catch {
    # Defensive: $_.Exception.Message can be empty for pipeline-injected
    # ErrorRecords (e.g. an empty stderr line caught by a 'Stop' preference).
    # Pass an empty string to Touch-FailFlag / Show-Toast and they'd crash
    # the same way Write-Log used to (kopia-4cs).
    $errMsg = $null
    if ($_ -and $_.Exception -and $_.Exception.Message) { $errMsg = $_.Exception.Message }
    if ([string]::IsNullOrWhiteSpace($errMsg)) { $errMsg = "$_" }
    if ([string]::IsNullOrWhiteSpace($errMsg)) { $errMsg = 'unknown error (empty exception message)' }
    Write-Log "ERROR: $errMsg" 'result'
    Touch-FailFlag -Reason $errMsg
    Show-Toast -Title 'D: Replica Verify: FAIL' -Body $errMsg
    $summary.errors = 1
}
finally {
    # Always disconnect if we connected.
    if ($connected) {
        try {
            $null = Invoke-Logged -Exe $KopiaBin -Arguments @("--config-file=$ConfigFile",'repository','disconnect') -Tag 'disconnect'
            Write-Log "disconnected" 'disconnect'
        } catch {
            Write-Log "WARNING: disconnect failed: $_" 'disconnect'
        }
    }
    if (Test-Path -LiteralPath $ConfigFile) { Remove-Item -LiteralPath $ConfigFile -Force }
    Remove-Item Env:KOPIA_PASSWORD -ErrorAction SilentlyContinue

    $summary.duration_s = [int]((Get-Date) - $startTime).TotalSeconds
    Append-Summary -Fields $summary
    Write-Log ("done: errors={0} sample_bytes={1} duration={2}s deferred={3}" -f `
        $summary.errors, $summary.sample_bytes, $summary.duration_s, $summary.deferred) 'done'

    if ($summary.errors -eq 0) { Clear-FailFlag }

    Write-Log "============================================"
    exit $summary.errors
}
# SIG # Begin signature block
# MII9bgYJKoZIhvcNAQcCoII9XzCCPVsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBRUQCpiU2kg4mP
# q30dD2dcGpHxCNYdWNRve2n0czJ2m6CCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAEFiZv8
# E6F66OgKAAAAAQWJMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNTEyMTc1NzE1WhcNMjYwNTE1
# MTc1NzE1WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAsWMGHi6/7066sJrgEsxa
# Ee5ODk6uVGfw63/Gg/BFmYhU1sC6zgwJEXkdeDE5tYqTyfmh/rQpOebdHaENo8qI
# F06/zbwCMjuqlZ3eVrvaumE6sjHDAJDMA77M74qDld2xLb+mdgkUVlIi9bsZvsNe
# f6NV7yiai+wiyST8nGI840qipapjksTJVJzQImXvxJbWG/PcJT8jDfP/PbfMQu02
# LHiV+0xGvgCyU+2hIaVHtQPBknpoWbp8R6L/8si2y96NQmzS43eauKQouFvEpeep
# m3QtWENxfRipg8STRpU6C7M50Qiu3BpatK/OKPpI1tjtYyddbU+3qlz8BQ1TpPqe
# biZ7xVEmpyCQJAPkVK7PNtHpH/8wnYcJss/32IM9MCS1aXYNLRYOffxIj04OlvXX
# EMmjnIcA3ghv6QTld8GCGxdR13CMHds8AenohnACRnvnOPR+kyl9ehkLRnh+xhsO
# B1tk6FDLgjSZtXxWFQIAVwMtkN7oC7MpH32ljy7kJk0PAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBR3EYArX/EN7kDtbdX3ERC39NbwdjAfBgNVHSMEGDAWgBRrXqU0wwXFYkoh
# Wo6rc2Bi1KxjhTBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBFT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwMy5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEA2A2R9LCbYtDugZ1Q8jiUBo+g2N4DZvSBUJSewz6mUhaHim0wlnSHORQ10StP
# 8o7H0sWx3SVjy0nHWRULx0ZTsZFOOIMrc1AoUw4mI+25CFsL6+/mePwoSamvrpin
# 5vrThYjWm4di/+51wP2owoFlV6Ue0l7lJ8VygZqPyZRceVCYsiPVcgnLaAOTp155
# UIxQ/fBbKQnkePrevLjtaeXoHZcYnbVG6inoDXfcigfdUR+VLML3ZzgoVKIE7NG8
# IEcXWu5QU1DiULgidfEkyUXZiz4/7yKOiX5jCNqOv0ibITPRM9HjUV30Y+GVJd0T
# R936hEEU+YXdQiYmYHZPhLDMMD7zhkmwNCn8DYUkd1lQNkhNXAJmOyqvORBkyWyt
# w3W4qRNlqUHkP8xuYvrUGCjsA6fiOZrIQw6IMT8OZY08O66Q3K/P33f9g+LauKxK
# cauXbzosDQE5TEk3ad4xCn3P3F9pS9DuPf+mNfaHFTzh+BLo9qGfZYKNbZIV9Mrg
# 5jLQWMxAfgZtyr5vEHt0uDN1fYPwuPU6qsWpDX/cFzPR9l4zasF321MdLQ0zs/kG
# 9xWMURtvD6a8mq2oz7hwx0QQhXM81QhqJXDYXV+6FZ3CG9YVIytgGXvFWQl+KOcY
# YnmoYkNNa0uOjf/apUXpblED9t85X90o8lZJsIbyjHAtVd8wggbFMIIEraADAgEC
# AhMzAAEFiZv8E6F66OgKAAAAAQWJMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNTEyMTc1NzE1
# WhcNMjYwNTE1MTc1NzE1WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAsWMGHi6/
# 7066sJrgEsxaEe5ODk6uVGfw63/Gg/BFmYhU1sC6zgwJEXkdeDE5tYqTyfmh/rQp
# OebdHaENo8qIF06/zbwCMjuqlZ3eVrvaumE6sjHDAJDMA77M74qDld2xLb+mdgkU
# VlIi9bsZvsNef6NV7yiai+wiyST8nGI840qipapjksTJVJzQImXvxJbWG/PcJT8j
# DfP/PbfMQu02LHiV+0xGvgCyU+2hIaVHtQPBknpoWbp8R6L/8si2y96NQmzS43ea
# uKQouFvEpeepm3QtWENxfRipg8STRpU6C7M50Qiu3BpatK/OKPpI1tjtYyddbU+3
# qlz8BQ1TpPqebiZ7xVEmpyCQJAPkVK7PNtHpH/8wnYcJss/32IM9MCS1aXYNLRYO
# ffxIj04OlvXXEMmjnIcA3ghv6QTld8GCGxdR13CMHds8AenohnACRnvnOPR+kyl9
# ehkLRnh+xhsOB1tk6FDLgjSZtXxWFQIAVwMtkN7oC7MpH32ljy7kJk0PAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBR3EYArX/EN7kDtbdX3ERC39NbwdjAfBgNVHSMEGDAWgBRr
# XqU0wwXFYkohWo6rc2Bi1KxjhTBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwMy5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEA2A2R9LCbYtDugZ1Q8jiUBo+g2N4DZvSBUJSewz6mUhaHim0w
# lnSHORQ10StP8o7H0sWx3SVjy0nHWRULx0ZTsZFOOIMrc1AoUw4mI+25CFsL6+/m
# ePwoSamvrpin5vrThYjWm4di/+51wP2owoFlV6Ue0l7lJ8VygZqPyZRceVCYsiPV
# cgnLaAOTp155UIxQ/fBbKQnkePrevLjtaeXoHZcYnbVG6inoDXfcigfdUR+VLML3
# ZzgoVKIE7NG8IEcXWu5QU1DiULgidfEkyUXZiz4/7yKOiX5jCNqOv0ibITPRM9Hj
# UV30Y+GVJd0TR936hEEU+YXdQiYmYHZPhLDMMD7zhkmwNCn8DYUkd1lQNkhNXAJm
# OyqvORBkyWytw3W4qRNlqUHkP8xuYvrUGCjsA6fiOZrIQw6IMT8OZY08O66Q3K/P
# 33f9g+LauKxKcauXbzosDQE5TEk3ad4xCn3P3F9pS9DuPf+mNfaHFTzh+BLo9qGf
# ZYKNbZIV9Mrg5jLQWMxAfgZtyr5vEHt0uDN1fYPwuPU6qsWpDX/cFzPR9l4zasF3
# 21MdLQ0zs/kG9xWMURtvD6a8mq2oz7hwx0QQhXM81QhqJXDYXV+6FZ3CG9YVIytg
# GXvFWQl+KOcYYnmoYkNNa0uOjf/apUXpblED9t85X90o8lZJsIbyjHAtVd8wggco
# MIIFEKADAgECAhMzAAAAFQU+bhmOkynZAAAAAAAVMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjYwMzI2MTgxMTI4WhcNMzEwMzI2MTgxMTI4WjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDAzMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA4PTLPQKqLw5zHj7zDnvism4QnfPpaJM2DkZUt5AVV7Hn
# nG8hsAXLHp5ZuWy7TBj44iBS8wUBfoIZVVf1NvauRnHXhBAQh00xoS9pKCKy3OFK
# 5YjEXG7/ZjjLUf5e/8QJr9BceASR59XR7d+376wal5ioynxn+Q6cjv/oZ1e0xK3j
# LUtfYjvm42f/R56YNzwpNHu2Em0UxZMfexWcEVqQuLNzXqUX0V0If1jAI+yZrGHl
# WaIYuExecltiTKyWasB3MsyWWLQ9h5Z6OWRCZHYmXBGsRzqG5sDtOmdSfXNt6bPT
# xiIRmqtbCixAM/Q6HOay5GFhrXg67HCoQKdpCHP6GJR/SI+gZDqqoFiDRJBLQvGT
# RtTGpPod6OuWo9IkCpncVuyGWhzuXLsqDIvirWH13iCIN7FSG0thC/JFLbAxnRKj
# agKv4rKk4tY16i3uoiqdZ4tUj3bz1vRtNwk7GBevG/8riEEcG3aAQl3pjDSQktHa
# KwkWOG9lgAMuJ4O0gDXBIKwYGX+d+fkHy1OYRs6yoyKWzGm2rlm+RSllCpDLD3Fx
# ZF0VjuJ6Cj5uClpRcqajqWyfyjjVUXiJcR0EXoADgcyIUQe4K/SA0NbHNjIDoEPs
# VRluKKuBw9JnwIsIsi7JGa5GkOyaGp2IwTXEfUUtumMQFW3AbS4rRU8wiBIOWXUC
# AwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUa16lNMMFxWJKIVqOq3NgYtSsY4UwVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcw
# AoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIx
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEAXW4iPM8Fy1/IJSRIf/ENtlDAlIVgTuOm
# fRT4cDkd5nZakVS5GDqJ/zHM1MK4w4cd1/fUjx+T0n5ZBqE75zvWVhzOWBVWKTuz
# WLgfpn1UhgBmcIhjgElpNItge75/ZxJSSZqIl8boHx+WHQbK1IE7dABTV5M5qk4J
# PktR8W9bv9BwqhB1WT5NgP+niV2G7aUTORXM9NI4rFJfQUWYEnmzg1fOWwczr3qs
# gt39D5xwsUSTYTG/MT/7Af1SO6X9q4Xkle86lEr/L5/3yDG5V3mlSJaaqKvEj/QS
# TIxPwqFVycZ5GUETNRWu5Dfcs7b0XjocUoD4KWcf15f45MMhBVSUwXwad7E4HyHP
# 6Zqr9nobWpC9gBI+/BJjj0KIcSU98Ml/j+/BgNubS6QL8490TDB3fM9fGbrlYvut
# DAMxqTgEh9S/DZa932UWZ0Dvqcsntgwr2Jh2iH3VIGCap+56McRlb/PfkWhE4dbY
# Ag78DaRQkhu75eQOGpKPtn8eNPa/U1o1wuzon9SEOWScweEX/BrwYh2I7zJh6ZXn
# adRRkS3UkRVaQt/ziqWWOmryKmae/vKT/1kD/dNw3YK7wE+luMTzgcVz2uLRpLDd
# 0rqiWohWB0jcngbn5/IrHro1uCGwUmxw+AT6mxd6mfu5xvXf3fxtvy8eJB/XApgX
# 5rGXUpB5rpAwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
# SIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJpZmljYXRp
# b24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMTA0MDEyMDA1
# MjBaFw0zNjA0MDEyMDE1MjBaMGMxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xNDAyBgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmll
# ZCBDb2RlIFNpZ25pbmcgUENBIDIwMjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQCy8MCvGYgo4t1UekxJbGkIVQm0Uv96SvjB6yUo92cXdylN65Xy96q2
# YpWCiTas7QPTkGnK9QMKDXB2ygS27EAIQZyAd+M8X+dmw6SDtzSZXyGkxP8a8Hi6
# EO9Zcwh5A+wOALNQbNO+iLvpgOnEM7GGB/wm5dYnMEOguua1OFfTUITVMIK8faxk
# P/4fPdEPCXYyy8NJ1fmskNhW5HduNqPZB/NkWbB9xxMqowAeWvPgHtpzyD3PLGVO
# mRO4ka0WcsEZqyg6efk3JiV/TEX39uNVGjgbODZhzspHvKFNU2K5MYfmHh4H1qOb
# U4JKEjKGsqqA6RziybPqhvE74fEp4n1tiY9/ootdU0vPxRp4BGjQFq28nzawuvaC
# qUUF2PWxh+o5/TRCb/cHhcYU8Mr8fTiS15kRmwFFzdVPZ3+JV3s5MulIf3II5FXe
# ghlAH9CvicPhhP+VaSFW3Da/azROdEm5sv+EUwhBrzqtxoYyE2wmuHKws00x4GGI
# x7NTWznOm6x/niqVi7a/mxnnMvQq8EMse0vwX2CfqM7Le/smbRtsEeOtbnJBbtLf
# oAsC3TdAOnBbUkbUfG78VRclsE7YDDBUbgWt75lDk53yi7C3n0WkHFU4EZ83i83a
# bd9nHWCqfnYa9qIHPqjOiuAgSOf4+FRcguEBXlD9mAInS7b6V0UaNwIDAQABo4IC
# NTCCAjEwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQW
# BBTZQSmwDw9jbO9p1/XNKZ6kSGow5jBUBgNVHSAETTBLMEkGBFUdIAAwQTA/Bggr
# BgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1Jl
# cG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB
# /wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZmAQHJ89QEE9oqKIwgYQGA1Ud
# HwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENl
# cnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcmwwgcMGCCsGAQUFBwEBBIG2
# MIGzMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJv
# b3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjAuY3J0MC0GCCsGAQUF
# BzABhiFodHRwOi8vb25lb2NzcC5taWNyb3NvZnQuY29tL29jc3AwDQYJKoZIhvcN
# AQEMBQADggIBAH8lKp7+1Kvq3WYK21cjTLpebJDjW4ZbOX3HD5ZiG84vjsFXT0OB
# +eb+1TiJ55ns0BHluC6itMI2vnwc5wDW1ywdCq3TAmx0KWy7xulAP179qX6VSBNQ
# kRXzReFyjvF2BGt6FvKFR/imR4CEESMAG8hSkPYso+GjlngM8JPn/ROUrTaeU/BR
# u/1RFESFVgK2wMz7fU4VTd8NXwGZBe/mFPZG6tWwkdmA/jLbp0kNUX7elxu2+HtH
# o0QO5gdiKF+YTYd1BGrmNG8sTURvn09jAhIUJfYNotn7OlThtfQjXqe0qrimgY4V
# poq2MgDW9ESUi1o4pzC1zTgIGtdJ/IvY6nqa80jFOTg5qzAiRNdsUvzVkoYP7bi4
# wLCj+ks2GftUct+fGUxXMdBUv5sdr0qFPLPB0b8vq516slCfRwaktAxK1S40MCvF
# bbAXXpAZnU20FaAoDwqq/jwzwd8Wo2J83r7O3onQbDO9TyDStgaBNlHzMMQgl95n
# HBYMelLEHkUnVVVTUsgC0Huj09duNfMaJ9ogxhPNThgq3i8w3DAGZ61AMeF0C1M+
# mU5eucj1Ijod5O2MMPeJQ3/vKBtqGZg4eTtUHt/BPjN74SsJsyHqAdXVS5c+ItyK
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIalDCC
# GpACAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENB
# IDAzAhMzAAEFiZv8E6F66OgKAAAAAQWJMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIDo4xkGW/SbNT1hbtV/zO4n/7R3j0eEq7cM8k28aJBYEMA0GCSqGSIb3
# DQEBAQUABIIBgHNZ3RRPKiK0fy6PDuLR8sbfEVknx9sHU/BJqE8SOzyUmvhdrSxo
# Kg+/wWdrUEwfYTJ9iok+BzydJqYxAKkRgUH7UVU7znxn/kwUT7JOq527MQh/HAPQ
# L+55MhQsHisNlHuTB8ONigGfBuRCwBZQ08NthDsPJk2FqGyQELAOVagO3iTSBQMl
# wON4JMMClnFlJaN6un8eM+NAntxQepKP9Azg+ecR9PzA+uSj9ugNuC0DbgeTaOdP
# bVsVKJKzt4No8AcsnC+STeS2ACbzaebpGCbv/Osvl4tzHUYH1YO1IgR61OAjWeY4
# dTTDgwY+KqvhkuaUCACS6ItUAC9AAB5fQiX4L2f9/JsXtYCB8DC7rnudDS/7htMe
# aXLCoxZTiE555i/0hCzkWj2h8qC213apzskduBqxBYPgAUY7GIlbpyQHa5a/dtbz
# 3cezhG4Gag0iH+ETYNSdlo7y2HS1i/6hkiPuKIX9FQ5KLQOdGhl/uzavVgUzyGN0
# DEkBqfpb+RXS46GCGBQwghgQBgorBgEEAYI3AwMBMYIYADCCF/wGCSqGSIb3DQEH
# AqCCF+0wghfpAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFiBgsqhkiG9w0BCRABBKCC
# AVEEggFNMIIBSQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAFMwQo
# nNPr/t5s4JuBOOmlBaFoXOfS4bJCPcR6W08pgAIGaeddl/4MGBMyMDI2MDUxMjIw
# MTMwMC4yMDNaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRp
# b25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTUwMC0wNUUwLUQ5NDcxNTAz
# BgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9y
# aXR5oIIPITCCB4IwggVqoAMCAQICEzMAAAAF5c8P/2YuyYcAAAAAAAUwDQYJKoZI
# hvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlmaWNhdGlv
# biBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIwMTExOTIwMzIz
# MVoXDTM1MTExOTIwNDIzMVowYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0Eg
# VGltZXN0YW1waW5nIENBIDIwMjAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQCefOdSY/3gxZ8FfWO1BiKjHB7X55cz0RMFvWVGR3eRwV1wb3+yq0OXDEqh
# UhxqoNv6iYWKjkMcLhEFxvJAeNcLAyT+XdM5i2CgGPGcb95WJLiw7HzLiBKrxmDj
# 1EQB/mG5eEiRBEp7dDGzxKCnTYocDOcRr9KxqHydajmEkzXHOeRGwU+7qt8Md5l4
# bVZrXAhK+WSk5CihNQsWbzT1nRliVDwunuLkX1hyIWXIArCfrKM3+RHh+Sq5RZ8a
# Yyik2r8HxT+l2hmRllBvE2Wok6IEaAJanHr24qoqFM9WLeBUSudz+qL51HwDYyID
# PSQ3SeHtKog0ZubDk4hELQSxnfVYXdTGncaBnB60QrEuazvcob9n4yR65pUNBCF5
# qeA4QwYnilBkfnmeAjRN3LVuLr0g0FXkqfYdUmj1fFFhH8k8YBozrEaXnsSL3kdT
# D01X+4LfIWOuFzTzuoslBrBILfHNj8RfOxPgjuwNvE6YzauXi4orp4Sm6tF245Da
# FOSYbWFK5ZgG6cUY2/bUq3g3bQAqZt65KcaewEJ3ZyNEobv35Nf6xN6FrA6jF944
# 7+NHvCjeWLCQZ3M8lgeCcnnhTFtyQX3XgCoc6IRXvFOcPVrr3D9RPHCMS6Ckg8wg
# gTrtIVnY8yjbvGOUsAdZbeXUIQAWMs0d3cRDv09SvwVRd61evQIDAQABo4ICGzCC
# AhcwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRr
# aSg6NS9IY0DPe9ivSek+2T3bITBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEF
# BQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9z
# aXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoA
# UwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZ
# mAQHJ89QEE9oqKIwgYQGA1UdHwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZp
# Y2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5j
# cmwwgZQGCCsGAQUFBwEBBIGHMIGEMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUy
# MFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
# MDIwMjAuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBfiHbHfm21WhV150x4aPpO4dhE
# mSUVpbixNDmv6TvuIHv1xIs174bNGO/ilWMm+Jx5boAXrJxagRhHQtiFprSjMktT
# liL4sKZyt2i+SXncM23gRezzsoOiBhv14YSd1Klnlkzvgs29XNjT+c8hIfPRe9rv
# VCMPiH7zPZcw5nNjthDQ+zD563I1nUJ6y59TbXWsuyUsqw7wXZoGzZwijWT5oc6G
# vD3HDokJY401uhnj3ubBhbkR83RbfMvmzdp3he2bvIUztSOuFzRqrLfEvsPkVHYn
# vH1wtYyrt5vShiKheGpXa2AWpsod4OJyT4/y0dggWi8g/tgbhmQlZqDUf3UqUQsZ
# aLdIu/XSjgoZqDjamzCPJtOLi2hBwL+KsCh0Nbwc21f5xvPSwym0Ukr4o5sCcMUc
# Sy6TEP7uMV8RX0eH/4JLEpGyae6Ki8JYg5v4fsNGif1OXHJ2IWG+7zyjTDfkmQ1s
# nFOTgyEX8qBpefQbF0fx6URrYiarjmBprwP6ZObwtZXJ23jK3Fg/9uqM3j0P01nz
# VygTppBabzxPAh/hHhhls6kwo3QLJ6No803jUsZcd4JQxiYHHc+Q/wAMcPUnYKv/
# q2O444LO1+n6j01z5mggCSlRwD9faBIySAcA9S8h22hIAcRQqIGEjolCK9F6nK9Z
# yX4lhthsGHumaABdWzCCB5cwggV/oAMCAQICEzMAAABWfo+dWAiO6WAAAAAAAFYw
# DQYJKoZIhvcNAQEMBQAwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGlt
# ZXN0YW1waW5nIENBIDIwMjAwHhcNMjUxMDIzMjA0NjUxWhcNMjYxMDIyMjA0NjUx
# WjCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UE
# CxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVs
# ZCBUU1MgRVNOOkE1MDAtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALSln5v7pdNu/3fEZW/DJ/4NEFL7y6mNlbMt7SPFNrRU
# rKU2aJmTg9wR0/C5Efka4TCYG9VYwChTcrGivXC0l4nzxkiAazwoLPT+MtuJayRJ
# q1ekOc+AZqjISD62YRL2Z1qQkuBzu42Enov58Zgu/9RK/peS4Nz5ksW/HdiFXAEc
# UsNQeJsQelyNJ5HpfcGtXWG9sHxqaH62hZsWTsU/XjYbeCx9EQUlbnm2umTaY0v9
# ILX5u6oiIsj+qej0c002zJ1arB51f3f61tMx8fkPkDWecFKipk2SQfYVPOd/tqV+
# aw3yt9rjWPf1gTgJs26oKRHUJG4jGr1DMlA0oZsnCL4B3UJ0ttO7E4/DPpCS97Tn
# WoT7j6jMLGggoHX8MEMdDvUynuxUr2wBGLNQJ5XQpfyhxmQjlb1Dao8i9dCS3tP/
# hg/f8p6lxlhaVzo2rp72f3CkToYzeDOXuscdG9poqnD4ouP4otmYXimpZSRE+wip
# aRUobN8MoOhf36I0MULz521g+DcsepYY1o8JqC3MesNRUgrWrywpct9wS0UpU1OK
# ilMWmvHe2DexKqZ/VztEmNLpjryhV61h+68ZfvYmonIrXZ005LAJ0Y73pHSk95YO
# 5UTH5n2VPL1zYjdFGCc0/RI6o0ZtLjf4dKF8T4TXz2KnhW8j1xhsc2mFM+s8d6k3
# AgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQUvrYz8rurWf4eRrMi78s9R/hTSFowHwYD
# VR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBhoF+gXYZb
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIw
# UHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNybDB5Bggr
# BgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0
# YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEGDCsGAQQB
# gjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqGSIb3DQEB
# DAUAA4ICAQAOA6gFxLDtuo/y2uxYJ/0In4rfMbmXpKmee/mHvrB/4UU2xBIxmK2Y
# LKsEf5VFHyghaW2RfJrGmT0CTkeGGFBFPF8oy65/GNYwkpqMYfZe7VokqHPyRQcN
# +eiQJsxhsXgQNhFksUbk69QLmXup2GjfP8LRZIh3LPIDGncVwbOg8VYcruWJ4Sz0
# JH7pipt5RX7cBO6Ynle39ZbJJpYLAugHkhgsxj2VIAr3B+U7/0Hvc+2yCJkg90rs
# 4TiMGj/nikE2H+u04n8iSpFkEnRn0wOinLuNZPCweqDyvjC5NY28cSucD6i0i+ts
# YytOEgVxxCUhJ7BbdM8VpMT/5YHo9Q8alJ5q2BHZMb8ykhyAKhVkmbpf+YSPrycb
# xT4bDUARJOHErpQ5CUKXHVYv4Jn/5hxTmIQwY7GtebOC/trAYpd11f0/EYkeukPM
# WL0y0VsXdnVbKzqAsJ7FOFiHogtCYpwr9VixxIe0Ms6/UUq+JCiS1naTWC4YI5KI
# 05hJAIxTu++Ld8Qe3p27yBdBjrFdfcZwlM6vRBisrdIDLmqYSpTYyfmk6Y1jGQxq
# PhjirJ6fdx5n7ZpdEsqdxffjN8vsuliRlGaCGSattu4w44xJ3baVK4fQXT3VSH1S
# Q/wLvNUc4dOVBwIr6K0NzrPDxCxyIIjnfU1s23YJhs3CC7f3XVUBETGCB0YwggdC
# AgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjACEzMAAABWfo+dWAiO6WAAAAAAAFYwDQYJYIZIAWUDBAIBBQCgggSf
# MBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MDUxMjIwMTMwMFowLwYJKoZIhvcNAQkEMSIEID/A
# LbbpgRtuEoRS4Wr3YVx9s/l3ddw6bI/C9hTvZfuvMIG5BgsqhkiG9w0BCRACLzGB
# qTCBpjCBozCBoAQgtgwzJU2k4/CVd4k4OV56XuAkh+tNeN2fl/aOTQYDDKgwfDBl
# pGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENB
# IDIwMjACEzMAAABWfo+dWAiO6WAAAAAAAFYwggNhBgsqhkiG9w0BCRACEjGCA1Aw
# ggNMoYIDSDCCA0QwggIsAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkE1MDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUA/3P3KRUqkFmAXl4IMkSdmW72BBGg
# ZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDtrYtoMCIYDzIwMjYwNTEyMTEyMDA4
# WhgPMjAyNjA1MTMxMTIwMDhaMHcwPQYKKwYBBAGEWQoEATEvMC0wCgIFAO2ti2gC
# AQAwCgIBAAICITQCAf8wBwIBAAICEoMwCgIFAO2u3OgCAQAwNgYKKwYBBAGEWQoE
# AjEoMCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkq
# hkiG9w0BAQsFAAOCAQEAV519OnGUjFN70HfL5zS3LqPzZ/JxBKiKZ5vNMWFXahtK
# Zc7k1Sr+uRQRDSZo6DNgmn39O7dk3CC3OqAdbYHpMb7ilV4oUbTGTbljw/yn5nyx
# vbyYzofCuoAeihhnNnsKAbdPGeA8zpsJbKEZm/54SBcU1jO1e6KbtAS9NkrPT9jZ
# Nx84vOpNhJu594pI3aryHkK+x2NfKHan/izW6We7LFh1WBo/PZWxW/5NXn57qD2v
# UKaApy+o+jeBPw/DbiSneiYjqaXT0j8gIhqiPlH5TZ4FJBAmyQbEYjw9POZQ9/xd
# fZPbdLCVMTXsnLd+y0GBlwXseFklXxkDo0eosYc2cjANBgkqhkiG9w0BAQEFAASC
# AgAGBK2xqY7gRDeKxr5ZTpQBJIiaqJPxAuypfN5tFLXN57ex9/vqVj5Xo3p1GIZS
# H7o25eFhfAG+lec4RKfDU2czI7HRSsrNlrjyzJtw5rvh3NhhVc+0ob3XVRLk10kQ
# isnKV7J39SmALZNB2K6h4HDHGjtDC03I7t8JsZCc6XLR0LZaiCPhRsbGIN13PwFH
# /NJPRXAI+kIlgQL1M80B11YuerFnrpK/IQSiLaavkTQ56ZYDpLD05U21ZFiEdkRA
# mi9doPhoP3VdvkSjtX18OyWyGU9Vx7CD/tcFPic0EIvAaGb8eA8Np+uxHj1PahnX
# 5/bQ67bofOx9gyUweIwO2bcHihn1hs+5ywrFDBpQ2LULLB/IhMGOUKAKtE0ZkFFa
# rw2+KOQzYBWSe5mo3bLwsIWrJ5Sr+JbF0aWZfplAKuwwqHIc0YKswfIR8c0pBkL9
# 3XGQD9j2xoOmtlvyLYhxDvEE+Ve7CoN9L1D0OYwSR+DREVpXSwuY1AfYQOoxrFYs
# NfNP0LRWfZsi7bF8qEnE7vrPT0Fp+SIY0KvKiZQ3YQhr9Pm8KbNsY6rDMFRe3Jxj
# yljRhCa7zXnEwVxYfyTKN2JERcEPYiPbRVeM1UAKuWOEjpSY3hYyq4ge+TPWUWOn
# 69YbmqYk4TS8OsiRCxp5CPEoUaKDz3xN6w3j+GODpof21A==
# SIG # End signature block
