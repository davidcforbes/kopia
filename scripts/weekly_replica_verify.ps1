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
    [string]$AppId           = 'RustBack.HealthCheck',
    [string]$LaunchProto     = 'rustback:open',
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

# Probe WinRT toast availability ONCE at startup (kopia-ytq). See the
# matching block in daily_d_replica.ps1 for rationale.
$script:ToastsEnabled = $true
try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,        ContentType=WindowsRuntime]
} catch {
    $script:ToastsEnabled = $false
}

function Show-Toast {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Body
    )
    if (-not $script:ToastsEnabled) {
        if (-not $script:ToastSkipLogged) {
            Write-Log "toasts disabled (WinRT type-loading failed -- non-interactive session); silently skipping further Show-Toast calls" 'toast'
            $script:ToastSkipLogged = $true
        }
        return
    }
    try {
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
    <action content="Open RustBack" activationType="protocol" arguments="$launch" />
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
    # Append one `replica verify summary ...` line to daily_kopia.log. Same
    # share-violation hazard as daily_d_replica.ps1's Append-Summary: the
    # kopia daily wrapper holds the file via cmd's `>>` (FILE_SHARE_READ
    # only), so a poorly-timed Add-Content throws under
    # $ErrorActionPreference='Stop' and -- inside this script's finally --
    # kills the rest of cleanup before [done:] / flag clear / exit 0 run.
    # Observed once on weekly_replica_verify 2026-05-14 08:35:07 (kopia-bmy.7);
    # the exact same pattern bit daily_d_replica on 2026-05-16 03:19:16. Retry
    # with short backoff; on final failure log a warning so the rest of
    # finally always runs.
    param([Parameter(Mandatory)] [hashtable]$Fields)
    $parts = $Fields.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }
    $line  = '{0} - replica verify summary {1}' -f (Get-Date -Format 'ddd MM/dd/yyyy HH:mm:ss.ff'), ($parts -join ' ')
    $attempts = 20
    $delayMs  = 250
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Add-Content -LiteralPath $DailyKopiaLog -Value $line -ErrorAction Stop
            return
        } catch {
            if ($i -eq $attempts) {
                Write-Log ("WARNING: Append-Summary gave up after {0} attempts ({1}ms): {2}" -f $attempts, ($attempts * $delayMs), $_.Exception.Message) 'done'
                return
            }
            Start-Sleep -Milliseconds $delayMs
        }
    }
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

    # ---- Verify VHDX structural integrity ----
    # Validate latest wbadmin dated folder on E: to catch replica corruption
    # before disaster restore. Test-VHD performs full structural validation
    # (BAT + sample blocks); costs ~1-2 min per file.
    $wbadminRoot = 'E:\WindowsImageBackup\ChrisLaptop2'
    $vhdxChecked = 0; $vhdxValid = 0; $vhdxInvalid = 0
    $vhdxFolder  = ''
    $vhdxStart   = Get-Date

    if (Test-Path -LiteralPath $wbadminRoot) {
        $latestFolder = Get-ChildItem $wbadminRoot -Directory -Filter 'Backup *' -ErrorAction SilentlyContinue |
                        Sort-Object Name -Descending | Select-Object -First 1
        if ($latestFolder) {
            $vhdxFolder = $latestFolder.Name
            foreach ($vhdx in (Get-ChildItem $latestFolder.FullName -Filter '*.vhdx' -ErrorAction SilentlyContinue)) {
                $vhdxChecked++
                try {
                    $null = Get-VHD -Path $vhdx.FullName -ErrorAction Stop
                    if (Test-VHD -Path $vhdx.FullName -ErrorAction Stop) {
                        $vhdxValid++
                    } else {
                        $vhdxInvalid++
                        Write-Log "VHDX validation FAILED: $($vhdx.Name)" 'verify'
                    }
                } catch {
                    $vhdxInvalid++
                    Write-Log "VHDX read FAILED: $($vhdx.Name): $_" 'verify'
                }
            }
        }
    }
    $vhdxDur = [int]((Get-Date) - $vhdxStart).TotalSeconds

    # Promote VHDX failure to overall verify FAIL
    if ($vhdxInvalid -gt 0) {
        throw "$vhdxInvalid VHDX file(s) failed structural validation in $vhdxFolder"
    }

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
# MII9bQYJKoZIhvcNAQcCoII9XjCCPVoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD6e41bRx1Z/bWm
# l4LPfNJIgwD+DoSNs5tS4koF1DkHvaCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAE6LURa
# eblMZe0rAAAAATotMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNTIwMTc1MzM5WhcNMjYwNTIz
# MTc1MzM5WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAtcEjbSCyoSYGMjojbxkZ
# GFOMyHfLOlkcVUl1SQRGQbYMuaMuSChpl2t6UiCsnzc45yuOLj0M2J3vyZrc0rIe
# QJ8Cm6GUq//xUqaHS1OATgI9zds62axeljUqTJH6lg8wt9RA3PYz6oMwcVd86W3s
# j5kwhThUUUIC3PrrLRDAec033miLBYB4uRvO4KiFdFCg0520zKU2T7N8VTfq1+2w
# b9uGLTv3sBxs+/tflwlUYOc/zqTMKtUzKPauTXT16c31nMWccm4P3hgJc/U/q9bC
# KH0BYkI05FAKG3I6gHIYrrbE978Z1W9qUtIy7A1y3wCTVDPCyrNjMQj926sgoDVb
# tFNuYuhLUCeI1wph1RixBWYSR8MHuN3Vi4HqOPNzUbzkj9eXqYDaP0TgjpMnNjte
# capbO2QddbNibZZAhNU/01ayk9joRoUQRRxxuQOtHdJpBlnE6vjb/tzO8qYMFveD
# OhxpAJKTTzGRGdBG+SNVFqO4d5W96yQdpFIyn5KdLigTAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBR0tCX1Zb8HlyGwDHvvyifFlZJs+zAfBgNVHSMEGDAWgBSa8VR3dQyHFjdG
# oKzeefn0f8F46TBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBFT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwNC5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEAFjciX8FZnZr+ZozPYCW48ZP0GYBEEMhydRdA6tPxQZW5xgQH3F4ZPVM3W3x1
# L921B8RmfITOjMCCdCM+ySZOX7QGIsTb9VzFkXG7e9LbooVC+reOFjsIROoywmRE
# ylmREviTdxjVG80TEPjfpRBkVKAGz3Z1p9k0TrlH7MXO2yFIrJuWn7nB9vf0GEda
# sBdz4mq0x0+MgNFDA7RTs9li5/b5K0H7og9oeM7h7SlxiDg/xVbSXRrIR0Rl2Gsc
# FlNKohhEkihmHMKKzmo/T19EIzOrIKESY9OTUJrzpNfZethqnCx4IBnmP6JwYSU3
# KqZSVH9cNxxvGHOKRsYvGu2LkAB08yqP5D4A3yMjul/ILreP4KKhYRLiBtikcSfz
# 22dh8iRfE9B/gJHvfCyEXBxItBdepA72Tp6eS/u+03k9I8YV0wtNLEc6FoN8rcgW
# tWvaceugKPh6wuj257VD6WMYDUrSZsuIVd7wMdVe7lCPE+/jUmH87lrkD6nAySl3
# XBZK6waPnhfKgvbvboCnTTjPyYq9JLsdGqxtPG7ds7Rcjhzj+X8NPTUaPndZ5nfl
# Wt7zD/jtaecWsLBpi8v4sbOumwLOD+YV2J1fyZD7lIVfYSQvtZRcxNhSde2zoU4J
# +P4e+7v0h0UFmFxzc4EAEYYD5ClDz5qT1rR09imKIcDgfZgwggbFMIIEraADAgEC
# AhMzAAE6LURaeblMZe0rAAAAATotMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNTIwMTc1MzM5
# WhcNMjYwNTIzMTc1MzM5WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAtcEjbSCy
# oSYGMjojbxkZGFOMyHfLOlkcVUl1SQRGQbYMuaMuSChpl2t6UiCsnzc45yuOLj0M
# 2J3vyZrc0rIeQJ8Cm6GUq//xUqaHS1OATgI9zds62axeljUqTJH6lg8wt9RA3PYz
# 6oMwcVd86W3sj5kwhThUUUIC3PrrLRDAec033miLBYB4uRvO4KiFdFCg0520zKU2
# T7N8VTfq1+2wb9uGLTv3sBxs+/tflwlUYOc/zqTMKtUzKPauTXT16c31nMWccm4P
# 3hgJc/U/q9bCKH0BYkI05FAKG3I6gHIYrrbE978Z1W9qUtIy7A1y3wCTVDPCyrNj
# MQj926sgoDVbtFNuYuhLUCeI1wph1RixBWYSR8MHuN3Vi4HqOPNzUbzkj9eXqYDa
# P0TgjpMnNjtecapbO2QddbNibZZAhNU/01ayk9joRoUQRRxxuQOtHdJpBlnE6vjb
# /tzO8qYMFveDOhxpAJKTTzGRGdBG+SNVFqO4d5W96yQdpFIyn5KdLigTAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBR0tCX1Zb8HlyGwDHvvyifFlZJs+zAfBgNVHSMEGDAWgBSa
# 8VR3dQyHFjdGoKzeefn0f8F46TBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwNC5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEAFjciX8FZnZr+ZozPYCW48ZP0GYBEEMhydRdA6tPxQZW5xgQH
# 3F4ZPVM3W3x1L921B8RmfITOjMCCdCM+ySZOX7QGIsTb9VzFkXG7e9LbooVC+reO
# FjsIROoywmREylmREviTdxjVG80TEPjfpRBkVKAGz3Z1p9k0TrlH7MXO2yFIrJuW
# n7nB9vf0GEdasBdz4mq0x0+MgNFDA7RTs9li5/b5K0H7og9oeM7h7SlxiDg/xVbS
# XRrIR0Rl2GscFlNKohhEkihmHMKKzmo/T19EIzOrIKESY9OTUJrzpNfZethqnCx4
# IBnmP6JwYSU3KqZSVH9cNxxvGHOKRsYvGu2LkAB08yqP5D4A3yMjul/ILreP4KKh
# YRLiBtikcSfz22dh8iRfE9B/gJHvfCyEXBxItBdepA72Tp6eS/u+03k9I8YV0wtN
# LEc6FoN8rcgWtWvaceugKPh6wuj257VD6WMYDUrSZsuIVd7wMdVe7lCPE+/jUmH8
# 7lrkD6nAySl3XBZK6waPnhfKgvbvboCnTTjPyYq9JLsdGqxtPG7ds7Rcjhzj+X8N
# PTUaPndZ5nflWt7zD/jtaecWsLBpi8v4sbOumwLOD+YV2J1fyZD7lIVfYSQvtZRc
# xNhSde2zoU4J+P4e+7v0h0UFmFxzc4EAEYYD5ClDz5qT1rR09imKIcDgfZgwggco
# MIIFEKADAgECAhMzAAAAFydFCQuLh6/GAAAAAAAXMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjYwMzI2MTgxMTMxWhcNMzEwMzI2MTgxMTMxWjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDA0MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAgsdk/gMPZioBlcyfk6tDzJ+PRt4rSLGKW8ewpS0kRxXt
# URC3T3GdbCKljobEn8ussqhGqQpRh/SXvRVwNXEIGb76UG5IPkCJ1S6/9BD61QQs
# KzPepW0SNj8TXgsFxvS7MltoRuikIIp7Q5jQgaOM6QyK9++6ZVXUpYmZulAe6x8J
# rwZ0dNkE+rZ66lqtoocwepUSVUxM7odDmn8yDHjJ2DNPsfr3uRDix3X4qvh14jH/
# SW+2Cx7WIMhyIiQO201i6hUixmk4e2ZW8W7C1wPdTjq6BKb+zo8xbrt7ZKQvRX5Q
# OA6dhLquPqj5sVKnxqfk19IC0SafTSTs8yC43Ew965BRRW8VL9ccoOmr4rxQy7aC
# gYTNk3dd/LphNaTTmnGp7kmLTxyHkB5geoWhYuuGrywS8E0wJv0W4rfOtHBV0e9s
# KvuUIeIUpnsx6ilxEVj6VQXvgD6yeCKnPmj3jJiJKAlmUDtth5yzRVBUl44sMiG4
# L5R/yyACRKk2n088Q2YCoZS1O86+oMLKt1jaXGECOjbsVp8Id1VQw8he6J0KirOS
# 5e25XlTdGPFb6oBOOaacgW78Kjf0bp+XzAgkc92mDGNJGYSjvdnj+7eMx6meW0DA
# IGdLRNj8/429MIspFBfz3KDqqpN71S4kQ2LLer3dxhDDczKVFL0HLwRuOvgjiG8C
# AwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUmvFUd3UMhxY3RqCs3nn59H/BeOkwVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcw
# AoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIx
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEAkHVaGf1NJt/JdoimmRZbMWr6baaDi8mk
# dWvWStk0hdZDpxSYTA7HuipAoLL3qIhI101XOl7fOiCh5++jZOamQdAV79ojEUNo
# IgCZmL2XJrLaGanwdjNynecJyYVCTrRf2+h7KknpWOp4axdOs6K9ZQ5g0IsQWXCw
# fc0dfkSkLKNY3pDcWLlJPh2jd5NUue6pNDv/2G5MFNJhCwltODebyAjGceU+XOza
# v+7i721YQnQ+39m2aQOFO7zpAdaKAeAGhEd6Y6CdDGneSxcoujWvafWbv4ay3jo1
# ORSLUuWMbKr5X18QE4Sde+gppGLLSkZsrUh2eyYSkX1envWX7ZPzg2/wiuKRlQFa
# rDn+N9+20BqzhxwkNyLzfYJp1Lg4fCXb24XqFjx8SDdRgebFImOfOLVze8XQ/Cwk
# rEaib0PHu2t4GVk4FYroEbNUFqvjdBvTY3uiR5TdQoyXoYHvh+TxpLSY2vo7hhK9
# D/rpEpHC+qmmcRUE4d0gyO9Zb1vvt25fxM3ekjvDfVHcPq3qMr0Rwsk4krKZWUEg
# U1SXT5qN6gqRrshxbT6OQgZ9/xT04qiXdzPQR6KindBvSpoOnxnALxcJyzVwNpKL
# +9u8EZYy98qX6i+4gE/2J6cbpekcB0ZXDn/XQxoNUUb6/djT/wllVyG+vIHkdq71
# PzbH5rYxdcAwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
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
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakzCC
# Go8CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENB
# IDA0AhMzAAE6LURaeblMZe0rAAAAATotMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIAAqBn/95QFCzAEouDKBqIUf9aJ7XNGn09Pu9jMgi2TeMA0GCSqGSIb3
# DQEBAQUABIIBgBUMol+XzcdpUHnPWhHppIjk6rcYwk/TrDvoJYwsrJFkEhRiu7D+
# A+z1AiHVBBmSCxqUpLIdgAdvwtyOpkhFR2/GREJbQa2mtx5IdGJVkAKowIWLuGyF
# Fwr4nKerk6U7aiFTr48/ARTiiwHeh9tXy3gtr0BH5L5FwATrvHZYyLYSoumeWz2i
# SnVj1S1kI0S14d7TNdmXLJGa7bIR1uLIUbce3Os87f9CJfkIJZTOsHUtRzi541U+
# SpPLGNDy35+VDVC3351A9z6gZDHoLgM6FDyi43k9tbQUuWKPOjqWjDhcbWwxFQLT
# BFFMKunih0PvG3/QAhBmUmQRDpFFdAG5Sptm5yUFjnLl8TUfY2nz7qQdkarVXaoa
# 7ewr9dic0fjfgSGk6sRbpaLl6Qr067Zl3/OUmZBmQ1+oVZH3FGlD3u5KFCnm2T+1
# ojccend9KjCX/Glw4dhSCbVGl1hXrSXMeIVUXT3RMf2Yda5s/qHIEaNMTjtplL35
# cRfHsLb/d5x+daGCGBMwghgPBgorBgEEAYI3AwMBMYIX/zCCF/sGCSqGSIb3DQEH
# AqCCF+wwghfoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFhBgsqhkiG9w0BCRABBKCC
# AVAEggFMMIIBSAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCC/eILl
# qUl+kFd+1zl8rfp90rzZiiiydV1i6taA3C1rawIGaeiBNV0pGBIyMDI2MDUyMDIx
# MDIwNS42NFowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlv
# bnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RDAwLTA1RTAtRDk0NzE1MDMG
# A1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3Jp
# dHmggg8hMIIHgjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAABTANBgkqhkiG
# 9w0BAQwFADB3MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMUgwRgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVyaWZpY2F0aW9u
# IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAxMTE5MjAzMjMx
# WhcNMzUxMTE5MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBU
# aW1lc3RhbXBpbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAJ5851Jj/eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBvf7KrQ5cMSqFS
# HGqg2/qJhYqOQxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDsfMuIEqvGYOPU
# RAH+Ybl4SJEESnt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbBT7uq3wx3mXht
# VmtcCEr5ZKTkKKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5EeH5KrlFnxpj
# KKTavwfFP6XaGZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6ovnUfANjIgM9
# JDdJ4e0qiDRm5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fjJHrmlQ0EIXmp
# 4DhDBieKUGR+eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOsRpeexIveR1MP
# TVf7gt8hY64XNPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiunhKbq0XbjkNoU
# 5JhtYUrlmAbpxRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE3oWsDqMX3jjv
# 40e8KN5YsJBnczyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8cIxLoKSDzCCB
# Ou0hWdjzKNu8Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMBAAGjggIbMIIC
# FzAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFGtp
# KDo1L0hjQM972K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUF
# BwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3Np
# dG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBT
# AHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmY
# BAcnz1AQT2ioojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmlj
# YXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNy
# bDCBlAYIKwYBBQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIw
# VmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIw
# MjAyMC5jcnQwDQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXnTHho+k7h2ESZ
# JRWluLE0Oa/pO+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC2IWmtKMyS1OW
# IviwpnK3aL5JedwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5zyEh89F72u9U
# Iw+IfvM9lzDmc2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbNnCKNZPmhzoa8
# PccOiQljjTW6GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqst8S+w+RUdie8
# fXC1jKu3m9KGIqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVmoNR/dSpRCxlo
# t0i79dKOChmoONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRSSvijmwJwxRxL
# LpMQ/u4xXxFfR4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7vPKNMN+SZDWyc
# U5ODIRfyoGl59BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/26ozePQ/TWfNX
# KBOmkFpvPE8CH+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/AAxw9Sdgq/+r
# Y7jjgs7X6fqPTXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSOiUIr0Xqcr1nJ
# fiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFXZ3WkmKPn44gAAAAAAVTAN
# BgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NDlaFw0yNjEwMjIyMDQ2NDla
# MIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJs
# aWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAvbkfkh5ZSLP0MCUWafaw/KZoVZu9iQx8r5JwhZvdrUi8
# 6UjCCFQONjQanrIxGF9hRGIZLQZ50gHrLC+4fpUEJff5t04VwByWC2/bWOuk6Nma
# Th9JpPZDcGzNR95QlryjfEjtl+gxj12zNPEdADPplVfzt8cYRWFBx/Fbfch08k6P
# 9p7jX2q1jFPbUxWYJ+xOyGC1aKhDGY5b+8wL39v6qC0HFIx/v3y+bep+aEXooK8V
# oeWK+szfaFjXo8YTcvQ8UL4szu9HFTuZNv6vvoJ7Ju+o5aTj51sph+0+FXW38TlL
# /rDBd5ia79jskLtOeHbDjkbljilwzegcxv9i49F05ZrS/5ELZCCY1VaqO7EOLKVa
# xxdAO5oy1vb0Bx0ZRVX1mxFjYzay2EC051k6yGJHm58y1oe2IKRa/SM1+BTGse6v
# HNi5Q2d5ZnoR9AOAUDDwJIIqRI4rZz2MSinh11WrXTG9urF2uoyd5Ve+8hxes9AB
# eP2PYQKlXYTAxvdaeanDTQ/vwmnM+yTcWzrVm84Z38XVFw4G7p/ZNZ2nscvv6uru
# 2AevXcyV1t8ha7iWmhhgTWBNBrViuDlc3iPvOz2SVPbPeqhyY/NXwNZCAgc2H5pO
# ztu6MwQxDIjte3XM/FkKBxHofS2abNT/0HG+xZtFqUJDaxgbJa6lN1zh7spjuQ8C
# AwEAAaOCAcswggHHMB0GA1UdDgQWBBRWBF8QbdwIA/DIv6nJFsrB16xltjAfBgNV
# HSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6Bdhlto
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQ
# dWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsG
# AQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3Rh
# bXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAww
# CgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGC
# N0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEM
# BQADggIBAFIe4ZJUe9qUKcWeWypchB58fXE/ZIWv2D5XP5/k/tB7LCN9BvmNSVKZ
# 3VeclQM978wfEvuvdMQSUv6Y20boIM8DK1K1IU9cP21MG0ExiHxaqjrikf2qbfrX
# Iip4Ef3v2bNYKQxCxN3Sczp1SX0H7uqK2L5OhfDEiXf15iou5hh+EPaaqp49czNQ
# pJDOR/vfJghUc/qcslDPhoCZpZx8b2ODvywGQNXwqlbsmCS24uGmEkQ3UH5JUeN6
# c91yasVchS78riMrm6R9ZpAiO5pfNKMGU2MLm1A3pp098DcbFTAc95Hh6Qvkh//2
# 8F/Xe2bMFb6DL7Sw0ZO95v0gv0ZTyJfxS/LCxfraeEII9FSFOKAMEp1zNFSs2ue0
# GGjBt9yEEMUwvxq9ExFz0aZzYm8ivJfffpIVDnX/+rVRTYcxIkQyFYslIhYlWF9S
# jCw5r49qakjMRNh8W9O7aaoolSVZleQZjGt0K8JzMlyp6hp2lbW6XqRx2cOHbbxJ
# DxmENzohGUziI13lI2g2Bf5qibfC4bKNRpJo9lbE8HUbY0qJiE8u3SU8eDQaySPX
# OEhJjxRCQwwOvejYmBG5P7CckQNBSnnl12+FKRKgPoj0Mv+z5OMhj9z2MtpbnHLA
# kep0odQClEyyCG/uR5tK5rW6mZH5Oq56UWS0NI6NV1JGS7Jri6jFMYIHRjCCB0IC
# AQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTANBglghkgBZQMEAgEFAKCCBJ8w
# EQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAc
# BgkqhkiG9w0BCQUxDxcNMjYwNTIwMjEwMjA1WjAvBgkqhkiG9w0BCQQxIgQgyPFI
# LmennvnK8xjhBtF2DTNuLeyu/SFc8QyqA8Zy4WYwgbkGCyqGSIb3DQEJEAIvMYGp
# MIGmMIGjMIGgBCDYuTyXZIZiu799/v4PaqsmeSzBxh0rqkYq7sYYavj+zTB8MGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTCCA2EGCyqGSIb3DQEJEAISMYIDUDCC
# A0yhggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5
# NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcg
# QXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQAdO1QBgmW/tuBZV5EGjhfsV4cN6qBn
# MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO24kjAwIhgPMjAyNjA1MjAyMDA0MDBa
# GA8yMDI2MDUyMTIwMDQwMFowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7biSMAIB
# ADAKAgEAAgIIWAIB/zAHAgEAAgISKzAKAgUA7bnjsAIBADA2BgorBgEEAYRZCgQC
# MSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqG
# SIb3DQEBCwUAA4IBAQCv415Pmxa+/1wQxYKOgMUyYj6/JCjslKWjxwYjupn3Pxyb
# 211BlaVtvDIOIJgOVGgyiE8p6ekor3mv3iwMFNrFa3yiCjGnGfgEedtT2B47IOb3
# SmnX7W93Wa+UV048NHnPKP0dowFxJqKdl1a5j+2yiD+C/JLW6VeBvo58IVSGHMbL
# HAcWVEScBCsyL4iPr13AzFrz83WWkBAJemlH/iseu9Vvdcmhg6c63G9rnaQx7SS+
# K00DHlt6Vt+Sk2LK9HcTMDVQE7ILTV1n/6ZKC2i+iag5Y6+0VnuUCTk6md2XLF7R
# pyb0somUJPZzXKhVY1iNxWvHUG4lTwph5DI7KFkkMA0GCSqGSIb3DQEBAQUABIIC
# AIEco1xj3y3ZzvK41vLGsHPBvpZoEdQ3lkLg0qCWW0zpNWQlVQpQiz1pM9Iz+SkU
# 0Rfc/+LPT2poljHKUB5WzUJHKmYLU6IT8z0yU33kHThblPqBZAwWswCfuW67FWdF
# fe2ijHAUJQWnAe8BYT/c/aI1mFXnFV3zd+488lB5Rg8LHyxRDI367MjJF6Mr4FMN
# WHl54H7lCPNO4o3S+zHrMtlUNCaDSlRKVzo/5ftWxgvBz0eG7VBRVsmeK5nNBDQ+
# HhSKjOdXLAVGlxXeYYklJiEps/ULO9Jbmcnk7wIOAeuaW3V24cEv0maJRt9q1VyC
# ZYoO4AYn/HBWGXAP9zBPyOBKTQ2x6HnvdbcXf2RBedTVlOG5aDY+uj5fYGZJn0n/
# KNufsa6vAO74iWJrX/Ghc2YMLMqJmkhf66oNZg+EGZlkrPRLk0yZ4G6IG6L3fmXr
# gR+jp4HJ1gjnetiGkDNMCvEJVOTgnzezqZK5xT4Yb8ft2D/tYJKwYZyWUv6tKTRS
# 1At2GdHAg+iRET3sax4kPXVMWLOyp45z9+AGae5vfSOoXWveQJETdSLH/TBhGE/9
# /GAmRica8Wy7ai06GtFS5ebkbHAJ3KnzdsXdo026MW90PXOVUu+JhOuTLUMFw8zQ
# rNRuDm/KEBQyKpx3cqXf9rAqCYEmGzg60JIf1nT6nXP6
# SIG # End signature block
