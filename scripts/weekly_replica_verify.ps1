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
# MII9awYJKoZIhvcNAQcCoII9XDCCPVgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAEuTThO
# B8uVoxpoAAAAAS5NMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNTE5MTc1MjU4WhcNMjYwNTIy
# MTc1MjU4WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA0Z8gdyilROysNZkdgIEP
# Lz1IqP1KS2/+XMYQIbwpNyp10zpviET1ShNMSAh/h/XkR7EJPREFWlofoekpk8lS
# c3PtYKypZ99Azw3yUGslgpAGX9WmBNw8B9kYfodNKI0J8sj1uZLUMccozbhxQhwC
# RX//PO29bPPZx8blfjyZdhKXdFDe8j+6C1jL11SZxd1Yvh9Sq+hfNeFZhPNdxbMc
# Mgy1hAKRLTH7YP/c3eScqG48D0Rkqgz4NMQXKltb+tHVSr9z1p9Xpf5059ls2l2w
# vnZbnpBwkO4Emeq4VxIozsXS+V/DGa+B8pTWjb9nT7om7pIqzkc1bKYKzLPbetfw
# 3tVIBcHMBTUFMYraswP+plxwTtIay+PCdVqd9IkTZUIRiK/fkV7zAYuuLyV9L4Ol
# XBe9HH7j8/QN+AqJzzytGy37fxjBdkM0YGlJniomuhLqmXiHx9wueabZ7T912ods
# Z8g1G08yJ9nXf+zJe44Cfwht2Mw+wDQp0R0hiYFZvMJBAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBQ9h/vet312AcYL7wbnVxU8uRFV/jAfBgNVHSMEGDAWgBRrJUHe+2t8/RiA
# Ci1/j3ZdqnM9uDBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBBT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwNC5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEAf5B3djqFpt2lQ7lUR2C6XAGlcFjgR7JvPyy5PjrSX77ASsspgtYQh0BRk4az
# cjJXFi3lSKscmOy694Li9deSq9lbbFZQ932E4Nm8bP4jY/nKKSw10o9wGZHulkTI
# RSTNt4XS8X4o/7lkQmj02kCJ2BRwCZWjX2srYmxzbGzU9KnosOUWJ1QR/3Q5DHxF
# 1mQEHdvWoiIhEVr/yu0q5/GhDfuPvq83qg7+VASjgJwQRAGWhpVUrUcMOpPzGolg
# m55RrY8skp1V5wGKxTTIgHWQAglYZhQFyu0o4y3xVgbp/bhO9Rz0WwTMBz6ZWj3a
# bukOBglLXwGHtsCQMmsrN3MgTkXLIoDJhn/1Wmn9OCTvS3imjA8vDqSZOlllessn
# Dlfk6gmyFgLSUAhR0NWEUWBAB1/AIHaOUMwKmmakPDKy4b7KfS90urvZX9MeA3h4
# 7F6bpyTI9yThsNJcUy3/MiRjBNIOtvpXiS1lQesTsJSBzO4TohwGjfq4Pj//JmSs
# gJzkMfqqrJhKGNZFgD8ryr5lBljzmzJwvI9rDcmMJvcPfR16cVgJfigeaQwQovuC
# MxQWZ3smlwQc1JDVNMiv5kFs5v0EFocEpzLdLhcvh3Mk2N3bOlJrx9D7//pVvIX9
# TspIfWPvWTLKzg7Uilcv4pL16xQ787QfYv5TVBXAzyCI8eswggbFMIIEraADAgEC
# AhMzAAEuTThOB8uVoxpoAAAAAS5NMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNTE5MTc1MjU4
# WhcNMjYwNTIyMTc1MjU4WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA0Z8gdyil
# ROysNZkdgIEPLz1IqP1KS2/+XMYQIbwpNyp10zpviET1ShNMSAh/h/XkR7EJPREF
# Wlofoekpk8lSc3PtYKypZ99Azw3yUGslgpAGX9WmBNw8B9kYfodNKI0J8sj1uZLU
# MccozbhxQhwCRX//PO29bPPZx8blfjyZdhKXdFDe8j+6C1jL11SZxd1Yvh9Sq+hf
# NeFZhPNdxbMcMgy1hAKRLTH7YP/c3eScqG48D0Rkqgz4NMQXKltb+tHVSr9z1p9X
# pf5059ls2l2wvnZbnpBwkO4Emeq4VxIozsXS+V/DGa+B8pTWjb9nT7om7pIqzkc1
# bKYKzLPbetfw3tVIBcHMBTUFMYraswP+plxwTtIay+PCdVqd9IkTZUIRiK/fkV7z
# AYuuLyV9L4OlXBe9HH7j8/QN+AqJzzytGy37fxjBdkM0YGlJniomuhLqmXiHx9wu
# eabZ7T912odsZ8g1G08yJ9nXf+zJe44Cfwht2Mw+wDQp0R0hiYFZvMJBAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBQ9h/vet312AcYL7wbnVxU8uRFV/jAfBgNVHSMEGDAWgBRr
# JUHe+2t8/RiACi1/j3ZdqnM9uDBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwNC5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEAf5B3djqFpt2lQ7lUR2C6XAGlcFjgR7JvPyy5PjrSX77ASssp
# gtYQh0BRk4azcjJXFi3lSKscmOy694Li9deSq9lbbFZQ932E4Nm8bP4jY/nKKSw1
# 0o9wGZHulkTIRSTNt4XS8X4o/7lkQmj02kCJ2BRwCZWjX2srYmxzbGzU9KnosOUW
# J1QR/3Q5DHxF1mQEHdvWoiIhEVr/yu0q5/GhDfuPvq83qg7+VASjgJwQRAGWhpVU
# rUcMOpPzGolgm55RrY8skp1V5wGKxTTIgHWQAglYZhQFyu0o4y3xVgbp/bhO9Rz0
# WwTMBz6ZWj3abukOBglLXwGHtsCQMmsrN3MgTkXLIoDJhn/1Wmn9OCTvS3imjA8v
# DqSZOlllessnDlfk6gmyFgLSUAhR0NWEUWBAB1/AIHaOUMwKmmakPDKy4b7KfS90
# urvZX9MeA3h47F6bpyTI9yThsNJcUy3/MiRjBNIOtvpXiS1lQesTsJSBzO4TohwG
# jfq4Pj//JmSsgJzkMfqqrJhKGNZFgD8ryr5lBljzmzJwvI9rDcmMJvcPfR16cVgJ
# figeaQwQovuCMxQWZ3smlwQc1JDVNMiv5kFs5v0EFocEpzLdLhcvh3Mk2N3bOlJr
# x9D7//pVvIX9TspIfWPvWTLKzg7Uilcv4pL16xQ787QfYv5TVBXAzyCI8eswggco
# MIIFEKADAgECAhMzAAAAFjGSjZICZXuaAAAAAAAWMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjYwMzI2MTgxMTI5WhcNMzEwMzI2MTgxMTI5WjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDA0MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAylX6yNvoCTDP9G0OTlSjXbzgEsy21FDL17n/lZe2BrqH
# z2mR1aN4DBxeYp0/hjEqSHHyGfarV1NVBuvK8vLzW0LTi+DZt9In16aiNfgcogFi
# ztWE9Fp8xu1zzrqE3nlrDWb+RZo8QrEXgWb8s8swsl2W7tREHycVkx+Hm1MLQIlv
# a6jH/Xg4/8GIYhHzbXiVd2RXomw9s7Qh6/SYRXXfe125wh4EKEyKnNNl+cZUSrVB
# gWvvjrRwQY4if7sAZ805KruBY6WY0Hiba5nWvrq9Qk9o35ViAf8qZ+7u1fbb1vcC
# WyWLfx9hLSdBjjVsSWe0xLvI1j4p3Tjt5czz+1Lc0v5lQ1feB7nFmpbZrK2us0hv
# AaBCfOyDPEEm+735vzuNRYWJFL/PViI+REtjuJMcojEn3veQjIrwrmK0T9oSr8e3
# oDzK1oAwwZMTC4KymTvYUTVDJvL5N8OW/UqIBzsiVYcchZvGhV3yMYKgxeEtIOG4
# W4Z85Y5kpQi5bpjGXFxRg46RdrTaALt1RhRmLR7U0jVSr2aYAd2+Mp2qA5Gz3/lo
# OOdt47eFZ3mrAYGYQtbK2SNjQpwgQX4Iy6tOKahCgFhKIcltitvSkpJB77eVWhNW
# nN2LfqMojszEue7V8EAySxry4PzlxTtFTb3Mw53XyH12BMQf2m9j7jEsHeVSATsC
# AwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUayVB3vtrfP0YgAotf492XapzPbgwVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcw
# AoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIx
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEABtVQXlR01UQZY5XGQ9yIjMcD8jI0MizW
# hJ1buZjg5toUQSXx/BrASwE5qxwHPBeO45pOQp6VD4iILgm8OmfylY+A7KIqttvD
# UizC3sBXxjK4u7sDRiyEguXHKfL1HQAwxCLEtnRPkCPTsJA6b917lA+3foQIHC1X
# DDpdQLHxGbbGXp4Rr0mFK5vxbi6tAahBi/RlzOXPh6PavKPlZ/0vhlkDdsvoJETt
# ebNJCNOZ1Kav3Tg+K4va4FbOrYqRHdGGahoA/gmTYmmVqw0zkGzT53HdhfajrFGt
# tJomK7qE+T8CQGiPkEIkxNmSXjCTpDqc4U1IKlTGcGYnRFGSgqrnWnkANPFsJ5ED
# Hysh82lPI+PFC3FOIVMLzLL+30rqznvRgHUUAj7xfFnEiuaAx3vFVSTOLb+iigpv
# dR6i8fSWpgYESOkdkn2N57tuhBs57tKwoP++vc/MVpuD1XAtmWi+lZSlahadTbDf
# GKjMn+bfm2xlW9PZ6BSnCRv1MMhpcUZkAZX3gVEMef8rZc2c7BJ4ayRfX0wH43vI
# 9znV+ZRJ3j0xUC0Zb82RQalF5yHkCr93x0IwvZtn6P2dNQyCP6qd3fC4RlVFtAQh
# tOH0cByTR/Iqqghv6qHzL/pMptgMQQ5x8zYEYy+tCThYgYIrq7y4WEDYQfeSlqIx
# QOrIUJ4IJDEwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
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
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakTCC
# Go0CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENB
# IDA0AhMzAAEuTThOB8uVoxpoAAAAAS5NMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIAAqBn/95QFCzAEouDKBqIUf9aJ7XNGn09Pu9jMgi2TeMA0GCSqGSIb3
# DQEBAQUABIIBgDNcgYHTn4uhh7ao403X42s7NmAk2tWnisMJs30r1dyQ9gKCydbx
# PRoJX6oVSt9BLeGudAdmR12KrktZplUddjjZJeQM+OUtQ7E5wLXLmCVVwtHBBD8/
# iB5pl6WNLu/LkNaMOAewVND7nbvNGGaTs+XaV1bVBtnEJgRcTY0ofBuS+kGYoWLT
# ARJ0q8zVqX1YM8w7IaRcNLMXVQuJKTPPRwTr0cQmaLJ37WsjrN2KIX/HO7y7UqsU
# qZQF1bM5ukpVPqkPysBs/zj8QXo1EPHvtM039X5Xp8DpE7QUfQgoGp8JeVTZ5u5z
# QW+Rf5Ez5TK9dMifeepPywwkwstvM0aV77uDHxPN0xiWyg11K1KLHi8mE1zMcuK3
# gBU3AkG/j/Wn5Lsi3WHKXMm9jrhOJUhl6+gyJjAvNsamImaAh+f/d5IAyx0j6Zon
# 4ELnj3iDuQSK+oUc/fvmsCtOzacfDnRkaNn0wIjsPDalbpd6pd1qVlK7MKnIoi/C
# hJTMedlVoNV19qGCGBEwghgNBgorBgEEAYI3AwMBMYIX/TCCF/kGCSqGSIb3DQEH
# AqCCF+owghfmAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFiBgsqhkiG9w0BCRABBKCC
# AVEEggFNMIIBSQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDfOBUq
# 2CyimS+65PsP31E5eMwrElyX7lXOHelyPRGS/QIGaeiBMmQXGBMyMDI2MDUyMDA2
# MTEzNy4zMDZaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRp
# b25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAz
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
# yX4lhthsGHumaABdWzCCB5cwggV/oAMCAQICEzMAAABV2d1pJij5+OIAAAAAAFUw
# DQYJKoZIhvcNAQEMBQAwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGlt
# ZXN0YW1waW5nIENBIDIwMjAwHhcNMjUxMDIzMjA0NjQ5WhcNMjYxMDIyMjA0NjQ5
# WjCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UE
# CxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVs
# ZCBUU1MgRVNOOjdEMDAtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBAL25H5IeWUiz9DAlFmn2sPymaFWbvYkMfK+ScIWb3a1I
# vOlIwghUDjY0Gp6yMRhfYURiGS0GedIB6ywvuH6VBCX3+bdOFcAclgtv21jrpOjZ
# mk4fSaT2Q3BszUfeUJa8o3xI7ZfoMY9dszTxHQAz6ZVX87fHGEVhQcfxW33IdPJO
# j/ae419qtYxT21MVmCfsTshgtWioQxmOW/vMC9/b+qgtBxSMf798vm3qfmhF6KCv
# FaHlivrM32hY16PGE3L0PFC+LM7vRxU7mTb+r76CeybvqOWk4+dbKYftPhV1t/E5
# S/6wwXeYmu/Y7JC7Tnh2w45G5Y4pcM3oHMb/YuPRdOWa0v+RC2QgmNVWqjuxDiyl
# WscXQDuaMtb29AcdGUVV9ZsRY2M2sthAtOdZOshiR5ufMtaHtiCkWv0jNfgUxrHu
# rxzYuUNneWZ6EfQDgFAw8CSCKkSOK2c9jEop4ddVq10xvbqxdrqMneVXvvIcXrPQ
# AXj9j2ECpV2EwMb3Wnmpw00P78JpzPsk3Fs61ZvOGd/F1RcOBu6f2TWdp7HL7+rq
# 7tgHr13MldbfIWu4lpoYYE1gTQa1Yrg5XN4j7zs9klT2z3qocmPzV8DWQgIHNh+a
# Ts7bujMEMQyI7Xt1zPxZCgcR6H0tmmzU/9BxvsWbRalCQ2sYGyWupTdc4e7KY7kP
# AgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQUVgRfEG3cCAPwyL+pyRbKwdesZbYwHwYD
# VR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBhoF+gXYZb
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIw
# UHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNybDB5Bggr
# BgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0
# YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEGDCsGAQQB
# gjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqGSIb3DQEB
# DAUAA4ICAQBSHuGSVHvalCnFnlsqXIQefH1xP2SFr9g+Vz+f5P7QeywjfQb5jUlS
# md1XnJUDPe/MHxL7r3TEElL+mNtG6CDPAytStSFPXD9tTBtBMYh8Wqo64pH9qm36
# 1yIqeBH979mzWCkMQsTd0nM6dUl9B+7qiti+ToXwxIl39eYqLuYYfhD2mqqePXMz
# UKSQzkf73yYIVHP6nLJQz4aAmaWcfG9jg78sBkDV8KpW7JgktuLhphJEN1B+SVHj
# enPdcmrFXIUu/K4jK5ukfWaQIjuaXzSjBlNjC5tQN6adPfA3GxUwHPeR4ekL5If/
# 9vBf13tmzBW+gy+0sNGTveb9IL9GU8iX8UvywsX62nhCCPRUhTigDBKdczRUrNrn
# tBhowbfchBDFML8avRMRc9Gmc2JvIryX336SFQ51//q1UU2HMSJEMhWLJSIWJVhf
# UowsOa+PampIzETYfFvTu2mqKJUlWZXkGYxrdCvCczJcqeoadpW1ul6kcdnDh228
# SQ8ZhDc6IRlM4iNd5SNoNgX+aom3wuGyjUaSaPZWxPB1G2NKiYhPLt0lPHg0Gskj
# 1zhISY8UQkMMDr3o2JgRuT+wnJEDQUp55ddvhSkSoD6I9DL/s+TjIY/c9jLaW5xy
# wJHqdKHUApRMsghv7kebSua1upmR+TquelFktDSOjVdSRkuya4uoxTGCB0Mwggc/
# AgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjACEzMAAABV2d1pJij5+OIAAAAAAFUwDQYJYIZIAWUDBAIBBQCgggSc
# MBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MDUyMDA2MTEzN1owLwYJKoZIhvcNAQkEMSIEIKV3
# iO/F6d/by/xGRaTIpIGmrScvHyyJQbIzJEnPp6bSMIG5BgsqhkiG9w0BCRACLzGB
# qTCBpjCBozCBoAQg2Lk8l2SGYru/ff7+D2qrJnkswcYdK6pGKu7GGGr4/s0wfDBl
# pGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENB
# IDIwMjACEzMAAABV2d1pJij5+OIAAAAAAFUwggNeBgsqhkiG9w0BCRACEjGCA00w
# ggNJoYIDRTCCA0EwggIpAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjdEMDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUAHTtUAYJlv7bgWVeRBo4X7FeHDeqg
# ZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDtt0CwMCIYDzIwMjYwNTE5MjAwNDAw
# WhgPMjAyNjA1MjAyMDA0MDBaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO23QLAC
# AQAwBwIBAAICBnUwBwIBAAICE0UwCgIFAO24kjACAQAwNgYKKwYBBAGEWQoEAjEo
# MCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG
# 9w0BAQsFAAOCAQEAmbjrux/idm60fBzDYipIb53jEhU8zxEhkhhdcxIaYUuzJy/+
# eg7Es6x9mpVU8631zsXpbkltl5o8xgDq/qiQSEKJLJYXYBi9q5gSu+jvrJYXh2n3
# yi/PMOu8S1yWFHDRc1lRgUp2sFmHLYFZTU+obzL5yZ9Sm9ElVqQRhmc/4Z7iMjxJ
# ilJrkYAnNVnq3YkBjXj+S8M0IAUYA6tMdmjEbuEVDQS9DLPNt7hWF54Q07lQ2n27
# sGndfmQGIajF9BOhKESZWbSbYskefUPMCu1jYIBHKCSzdpoXNorB+pFyPh44LZoO
# PnFggSWfg0TU4sXXZvPHRsSuBH/AOCkoXHXT4jANBgkqhkiG9w0BAQEFAASCAgCa
# RYqhXpvifsQnlPv627a0nxdf2qwOUstXQTfmCyDQ2UDdU6WNDq7XmdAyAF1GI5/w
# sG9KEwaNPh1EW9cYnkYAc6e3JmTPQLiYD0g7ch8F4prX+Nj7HYcQYTwP8wvZoW/P
# PFfCLccPGRlaXdYeyIcJyMEbt7LsHKfncoedh1w+cyF9XWXxsNunIs+3hTJGlc3p
# uH4eJtJXyXXuJIrLQhtNVYIDWJo/qcb9Q8AkTZHNWWArxCqGqnxOJ9U/pBzJlGYC
# QNlTNL99VnerOClpwgljf0LaD0UHWzEcZHPByTNdkhCP4IVElH5SlgFv31ybrkzl
# 4uCjfC01VlOVWVrOv/uaAYs7A8ZQ1Gx5thrlEiZor1gO8VNeLGP6lVh9iw/D2rEb
# CyIHn1nRm+bfiidK2/gB1zxCA1jWLrrI684KGuU8o88DjIdUUjdOo9Yrxq98/wt9
# OCVM5vfWRXUKsy0OesWpRh7+RAdDy0rhdYziD5lsU4G/hAXIQs9x+Q6HWoKOMFK3
# neWPVwNfoER8zmpHBzl+Fw3TM0YWFXeQJ7JrI0biwpAfGyRUnFkA6gmpXoDgiaaf
# nrW+d56mkt7NP8TNX0Bj6Q5NMVtMuPol3eqEpV2cAWedil8sNF2HQa4eGKb8r5uZ
# jng96sZZ9jYjL7qEdg2eRlexhYC4Dm20CLH0M0EfVQ==
# SIG # End signature block
