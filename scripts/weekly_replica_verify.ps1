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
# MII9agYJKoZIhvcNAQcCoII9WzCCPVcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDi5ij2BJdX4L9q
# ErbRkoi7YBA2JAcTYG8qSbz2EUb4oKCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAEWi3g6
# g8Ba7npPAAAAARaLMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwHhcNMjYwNTE2MTc1MTUwWhcNMjYwNTE5
# MTc1MTUwWjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAikJVvZlEx3n7x1bD5dZi
# EOr/Fk4zy09mH4hbP3AQtlpfDHJwLsRGMQXNV5lqd/02jafy0D6Ua5NIS+IePLSu
# Qp6knY2jbyzGa4avZ3LCiLRk82+THpZJ5xcb/lcCKMEZQQkMxQfAXxfSE1WflYiC
# yovpz4tduQaKdid+woBlvdVyskkjnpKdHijnrbXkmQ2odIQM7GxbYgViCq8z1XYx
# U7WiUHUkjqMifFHMbnJIoSGPxjUVRcnCIGGhZHt3fYGoBCBGGw8h+Jta0vrYFLzz
# VPWfsHIQzAKmyT1u/FzBba14G1A1qp3Fh2n/ovMBntuQx1K0Pk6pdg3l43j+wPIN
# +KTaH8uWm4is2o1MLAYGm0eLK94qcjahFSeKrq0czNJjXlvU4lOAhm7Bommd31Ni
# vNT6EbOBfWh2pQOXNKKVAe4wfVcR3VbSQxDaGW9JZ4p9kkC90Z7Bla/3neIwPm76
# cXwopzjMpnstHs2mpFvfaHoZ/wXJNlzxgt8PlnWfch3rAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBS3SBdEnJiYpRhpxaP8hwPVPPlHiDAfBgNVHSMEGDAWgBSkQwx/dlqlhec+
# jSgPDBeiRWlwxjBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBBT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwMy5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEAn1sB7M9NE6XiaAxFkmb0ZLl2cETch2I9y2lM/rkuUSTaly8bs7Izg8bSElSk
# xIdD+q6pq2ryFBF8vuleaj+QgMN/xeZn8gJhxs3WoFf4WAqvTGkPuszgOzir3ZAB
# 3i1xp32306NWFO2dlcM2VA+joi4e9yKxgWy6/2P6ibIdyvZmEydDP/37TYkIWYrP
# YmWpw50maE1IijzhnsTzYeuA57+ca9tE0AqyitFVE0wSzz8lVXmvRS5qo2GjHOO0
# M4MRKGgdcE7sH03VA4UI6dvquK5RfpE/lproqX6sEcrktJ9E6WKASptFPeZe+NMR
# HyTwsU/DOJms3j72mJtkZKTFPXtWHjhaDbYcD2DmCeyMbl0LZ5tAXkf9u3L2MlIN
# 5aep6PFEnVEfKYcQIoxbMoWPyUw59lhUYk1S1EuKoBUNXLjb0k0m69nWnHE+ieli
# TIJzBtY5Lb2aaBOYFr+mqYcqOxyumxFmaW0V5Fkl9lKdUqjJ/9UyWLUqxVNieL/2
# lT7tzG05dNl8sICKtCde4wiwx4nWRuPBEB70RwA1+vX4/da1BfN6cUc3mMA4hik7
# VhZOB570fhelDZjUvRLr3giggUp4HgdkUkiWtp87NFWQookf0Q3mRw58rB3i8oVO
# DX7kRMtoxSpcmV+tsDNkQVWZbFKSA8uPZCoRhaQO0LcIah0wggbFMIIEraADAgEC
# AhMzAAEWi3g6g8Ba7npPAAAAARaLMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwHhcNMjYwNTE2MTc1MTUw
# WhcNMjYwNTE5MTc1MTUwWjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAikJVvZlE
# x3n7x1bD5dZiEOr/Fk4zy09mH4hbP3AQtlpfDHJwLsRGMQXNV5lqd/02jafy0D6U
# a5NIS+IePLSuQp6knY2jbyzGa4avZ3LCiLRk82+THpZJ5xcb/lcCKMEZQQkMxQfA
# XxfSE1WflYiCyovpz4tduQaKdid+woBlvdVyskkjnpKdHijnrbXkmQ2odIQM7Gxb
# YgViCq8z1XYxU7WiUHUkjqMifFHMbnJIoSGPxjUVRcnCIGGhZHt3fYGoBCBGGw8h
# +Jta0vrYFLzzVPWfsHIQzAKmyT1u/FzBba14G1A1qp3Fh2n/ovMBntuQx1K0Pk6p
# dg3l43j+wPIN+KTaH8uWm4is2o1MLAYGm0eLK94qcjahFSeKrq0czNJjXlvU4lOA
# hm7Bommd31NivNT6EbOBfWh2pQOXNKKVAe4wfVcR3VbSQxDaGW9JZ4p9kkC90Z7B
# la/3neIwPm76cXwopzjMpnstHs2mpFvfaHoZ/wXJNlzxgt8PlnWfch3rAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBS3SBdEnJiYpRhpxaP8hwPVPPlHiDAfBgNVHSMEGDAWgBSk
# Qwx/dlqlhec+jSgPDBeiRWlwxjBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwMy5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEAn1sB7M9NE6XiaAxFkmb0ZLl2cETch2I9y2lM/rkuUSTaly8b
# s7Izg8bSElSkxIdD+q6pq2ryFBF8vuleaj+QgMN/xeZn8gJhxs3WoFf4WAqvTGkP
# uszgOzir3ZAB3i1xp32306NWFO2dlcM2VA+joi4e9yKxgWy6/2P6ibIdyvZmEydD
# P/37TYkIWYrPYmWpw50maE1IijzhnsTzYeuA57+ca9tE0AqyitFVE0wSzz8lVXmv
# RS5qo2GjHOO0M4MRKGgdcE7sH03VA4UI6dvquK5RfpE/lproqX6sEcrktJ9E6WKA
# SptFPeZe+NMRHyTwsU/DOJms3j72mJtkZKTFPXtWHjhaDbYcD2DmCeyMbl0LZ5tA
# Xkf9u3L2MlIN5aep6PFEnVEfKYcQIoxbMoWPyUw59lhUYk1S1EuKoBUNXLjb0k0m
# 69nWnHE+ieliTIJzBtY5Lb2aaBOYFr+mqYcqOxyumxFmaW0V5Fkl9lKdUqjJ/9Uy
# WLUqxVNieL/2lT7tzG05dNl8sICKtCde4wiwx4nWRuPBEB70RwA1+vX4/da1BfN6
# cUc3mMA4hik7VhZOB570fhelDZjUvRLr3giggUp4HgdkUkiWtp87NFWQookf0Q3m
# Rw58rB3i8oVODX7kRMtoxSpcmV+tsDNkQVWZbFKSA8uPZCoRhaQO0LcIah0wggco
# MIIFEKADAgECAhMzAAAAGA3rkVWpigCYAAAAAAAYMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjYwMzI2MTgxMTMyWhcNMzEwMzI2MTgxMTMyWjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDAzMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAyIDaYDRWoon9lVnlj+SOj5xV8Sf5Qd+3yUeeRgr0exi2
# QTJAYo24ilcIKQSN8TOZ3+POM5x/6p3Cfjgqust44J0FvkfGXe1Puy45a5nLJGpc
# 0kNIITMRKZwVvPxx7NlfGSc0JOhz/kg7G77C+y3ZR/3jtpeJpJ4QwcK9Gf0Peuk7
# xLYeW/JAsY9b6oleGDbYSxkamUfbtnyv8gTFrvN6ejuLqNhHYPvoBHsOSC+7555y
# hapkof0fbzyct1hdWHGXsAFMfLF2TVJ8d2YVYOfZdi6YrT4sMxOhTKiLKmhL1Xtz
# M7hXdmv7lg2R+lWw8lIkSu/JiINQ0GAPcwxMsgRXDSPp8VUs4Jby+ruz0bjaoHFd
# 7H+hC8cPPcrEDP2eEdYURVl0acjliigCrXwR05NFJzYj3MZizDGLPI3lIzonX1T4
# 0yK8v1FcJ8MXZZCvOXGXwRDGGfwwTTsHaJj+OfWNZ/IsypG4bGvqeJcPnEFcQEwR
# cfYIEe/R4a8k+xw5qTy75CbwWeMFuAlt9lE9kjMg3tvJyDlN5voXx5VXinCwUHMp
# uVaEQ4yHAlSO7qoBltjzTBNHH3ovMwsAsuhwrLLCVhUu3oP2GxYZwEyXMlnzK5Db
# gGzHzDfDaYPHK0uo1VaMMg9Bhuc3YIvrkFXEiv+t/JgNcRGCt6ZyKEIDtPbrgwcC
# AwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUpEMMf3ZapYXnPo0oDwwXokVpcMYwVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcw
# AoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIx
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEAcccgVvl+poXUYksA/TzDFnBlAJ8ef0FM
# Jzb2XRRhF/uA0QyK/VgoeAvO8B7cPpYNQ97sytdA7LT19CxSwRQAt71jGF+CJl8K
# C4aEdMZTfJlHaKyd24J6QiVriNed9WdawsD7lK0pAcXziBg5N6dhAm9x6P8R4uT0
# UkfzlK1rkB8F4mlzE7l7tyES3s8FZGaRZjcGEQ+e0fTcdhf8jO7czmNB4dIRgmmB
# Ct/P+ha0tEl2nV1sg1An5+VzhgAkY1Apx8fiUFBtH+Ehw/om5aQCNIJfmR51ZnV1
# 8R02Xk2tAmAiIRcSj9vdtrNIOsy5nolddy1lJrbf1Be061l6TItv9FDZ4mg6B+65
# zxkVecVV/Ll8uLGYouGrMM6jzO2O/ps3K2p6mfBI2ZOYIy4UNwNrGWqa5TrvAmkZ
# sn3CIlR+81X4AL5vNTFlxc4gH+5su0Dr58hBTxnXavDEnz7X0csP1Kt7h+iqaGiT
# SHz2B+n3HmUoud0WrdQPYKxMat0To4YUqU3HIbgSLQDDVT8aCjW1Jvokf1915C/v
# VkIIp48h3voVy3JWPLwBlxQ9aeND6jCKQGLJhCQRSlvXX+P/9TeaEA6/xWPSASZf
# 6Ekve/Yua7U+zWc/Sr2K2gj0QRrNEAsvrFr4EGtHKDO9ECVS3lcJksVDv9KHdMPU
# K8u20i68RqAwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
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
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakDCC
# GowCAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENB
# IDAzAhMzAAEWi3g6g8Ba7npPAAAAARaLMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIEy15vW261JGx+wvU2hEK/URmwhhNrpdgiG1q0WKMYjEMA0GCSqGSIb3
# DQEBAQUABIIBgHxsVsXMF4FRQJcDwKoyYIvzims7r4UZX/xYG/aRlyNqiSq5BIxO
# joH+iUKzNgtiFxh20iI7yo4c4JZTajrhBe+AMfpwcHTodGdywEANJi9k7qsmNzqA
# o1yT6IJEDzV5HVcsOOgh5KxswihcZBEebz67MuEBgoeNBYRxa6UFi0pQjQ3TjUHV
# sZTKWX8OcFWo3kya9XXHb2YYNyQkQE7u+VBYIJwESRr9PZdQRcO3Yl7K6kljMh3h
# yQDRo7aUEUxyLdKqeUqwZQR2MEVbkIgpmKPa83d5Jp2RoA/MSjvshG+o+Hf70mgs
# KlMiXToI1DxinzIvTIM4FYMFWn6SpV0vzk9L8dQY1macZKxxV1a1wek67jZ2rpR0
# Wiwj5r5NO4ZIH2EyTaGpSvMZkOn6tljLWkFZerU7ynXnUUZ3X0gAsZJY1PYpNTLI
# 8aPDMk7HBgDvCSqXv/XX/35KCMcy9Hk+Yf9u8O/SAidKSTbOB2LuGVMxy0WZE5Y9
# tjjli3trPT0LMqGCGBAwghgMBgorBgEEAYI3AwMBMYIX/DCCF/gGCSqGSIb3DQEH
# AqCCF+kwghflAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFhBgsqhkiG9w0BCRABBKCC
# AVAEggFMMIIBSAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAnitV2
# p06j/hC2X0Gvqncf4opv3dLD2BqbpP5pkapwewIGaeddo/6RGBIyMDI2MDUxNzA2
# MzEwMy4zMVowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlv
# bnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNTAwLTA1RTAtRDk0NzE1MDMG
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
# fiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFZ+j51YCI7pYAAAAAAAVjAN
# BgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTFaFw0yNjEwMjIyMDQ2NTFa
# MIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046QTUwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJs
# aWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAtKWfm/ul027/d8Rlb8Mn/g0QUvvLqY2Vsy3tI8U2tFSs
# pTZomZOD3BHT8LkR+RrhMJgb1VjAKFNysaK9cLSXifPGSIBrPCgs9P4y24lrJEmr
# V6Q5z4BmqMhIPrZhEvZnWpCS4HO7jYSei/nxmC7/1Er+l5Lg3PmSxb8d2IVcARxS
# w1B4mxB6XI0nkel9wa1dYb2wfGpofraFmxZOxT9eNht4LH0RBSVueba6ZNpjS/0g
# tfm7qiIiyP6p6PRzTTbMnVqsHnV/d/rW0zHx+Q+QNZ5wUqKmTZJB9hU853+2pX5r
# DfK32uNY9/WBOAmzbqgpEdQkbiMavUMyUDShmycIvgHdQnS207sTj8M+kJL3tOda
# hPuPqMwsaCCgdfwwQx0O9TKe7FSvbAEYs1AnldCl/KHGZCOVvUNqjyL10JLe0/+G
# D9/ynqXGWFpXOjaunvZ/cKROhjN4M5e6xx0b2miqcPii4/ii2ZheKallJET7CKlp
# FShs3wyg6F/fojQxQvPnbWD4Nyx6lhjWjwmoLcx6w1FSCtavLCly33BLRSlTU4qK
# Uxaa8d7YN7Eqpn9XO0SY0umOvKFXrWH7rxl+9iaicitdnTTksAnRjvekdKT3lg7l
# RMfmfZU8vXNiN0UYJzT9EjqjRm0uN/h0oXxPhNfPYqeFbyPXGGxzaYUz6zx3qTcC
# AwEAAaOCAcswggHHMB0GA1UdDgQWBBS+tjPyu6tZ/h5GsyLvyz1H+FNIWjAfBgNV
# HSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6Bdhlto
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQ
# dWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsG
# AQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3Rh
# bXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAww
# CgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGC
# N0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEM
# BQADggIBAA4DqAXEsO26j/La7Fgn/Qifit8xuZekqZ57+Ye+sH/hRTbEEjGYrZgs
# qwR/lUUfKCFpbZF8msaZPQJOR4YYUEU8XyjLrn8Y1jCSmoxh9l7tWiSoc/JFBw35
# 6JAmzGGxeBA2EWSxRuTr1AuZe6nYaN8/wtFkiHcs8gMadxXBs6DxVhyu5YnhLPQk
# fumKm3lFftwE7pieV7f1lskmlgsC6AeSGCzGPZUgCvcH5Tv/Qe9z7bIImSD3Suzh
# OIwaP+eKQTYf67TifyJKkWQSdGfTA6Kcu41k8LB6oPK+MLk1jbxxK5wPqLSL62xj
# K04SBXHEJSEnsFt0zxWkxP/lgej1DxqUnmrYEdkxvzKSHIAqFWSZul/5hI+vJxvF
# PhsNQBEk4cSulDkJQpcdVi/gmf/mHFOYhDBjsa15s4L+2sBil3XV/T8RiR66Q8xY
# vTLRWxd2dVsrOoCwnsU4WIeiC0JinCv1WLHEh7Qyzr9RSr4kKJLWdpNYLhgjkojT
# mEkAjFO774t3xB7enbvIF0GOsV19xnCUzq9EGKyt0gMuaphKlNjJ+aTpjWMZDGo+
# GOKsnp93Hmftml0Syp3F9+M3y+y6WJGUZoIZJq227jDjjEndtpUrh9BdPdVIfVJD
# /Au81Rzh05UHAivorQ3Os8PELHIgiOd9TWzbdgmGzcILt/ddVQERMYIHQzCCBz8C
# AQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjANBglghkgBZQMEAgEFAKCCBJww
# EQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAc
# BgkqhkiG9w0BCQUxDxcNMjYwNTE3MDYzMTAzWjAvBgkqhkiG9w0BCQQxIgQgGT0x
# T3fmpSAPhNyvgM8FhxGyc3XTWPwL3jG2oIRJMm8wgbkGCyqGSIb3DQEJEAIvMYGp
# MIGmMIGjMIGgBCC2DDMlTaTj8JV3iTg5Xnpe4CSH60143Z+X9o5NBgMMqDB8MGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjCCA14GCyqGSIb3DQEJEAISMYIDTTCC
# A0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTUwMC0wNUUwLUQ5
# NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcg
# QXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD/c/cpFSqQWYBeXggyRJ2ZbvYEEaBn
# MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2zeigwIhgPMjAyNjA1MTYyMzIwMDha
# GA8yMDI2MDUxNzIzMjAwOFowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA7bN6KAIB
# ADAHAgEAAgItCjAHAgEAAgISZzAKAgUA7bTLqAIBADA2BgorBgEEAYRZCgQCMSgw
# JjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3
# DQEBCwUAA4IBAQBQT/WyXoXIVt9erd3FT3ei7mM4RSzRFFiEy2AUubvxeDxdy1Kl
# umTGiVk4FHpW/7fL9oF3G9cRWyagFle3jrgk3xS2BHRjiQ3GYhh1TqNe4rWwCi/1
# 0pMGSSU7Lp2ZuJnZiFuzVI7+ndYr8GwqQhCIF6hjtlmEe19d3MU1bXIdBCJe4y7p
# I0ktzZB1Tgb5RWYys0iIvw41mdbCclgmokYzWSKGQQmHp2O1Br3M7lHnRGyR5Oyv
# JpW9+0VEh729COEJy0h/iOmrpmipcuTLzyUgP/ji+FNEr+0eKX12i4mZmQaWc5Qj
# LXZE+5kpUfsTNexiwfPCRM05a9iYyZ9V8NeJMA0GCSqGSIb3DQEBAQUABIICAGPO
# GZ4JRlzFmkTZt6TpeedViQYZtgrtU0bh22AyxQgvpj4w0BgwOOM9b9Gm5QqA3xNH
# wKD1ckXv+Xe5Z++7RuK1Xe0a70q2AGY8zu5pCjjjFYqdbvUddu7RdWvC2R9/IIkW
# vcK8hSxSbRpLx5LLgJ+sayHS74Q8paDhNi5b9V2Skdkg1jTQXAPZQbIwElQ6fGro
# NcKGnTGrABxMRlUYXkgyDYX+ND91x/Ce0AYe8QdpN8peywUrMlJFFkSVA090TacF
# uLB65RuQg/TNFG0O696sKzWdAWjcSdFW1eNDlLLWzTX5s7P0QyT+b244HC8mccz2
# 5pIGPMk5z+p/Ggn6TaFsfYxXgs0Zv9aq5+0ZsOcS11CiPxHecaETDIUHSxHZMl2z
# K4vPKR2BapkKZ95V8+qrl72dvn71I44/Gzl+/LeiAgNDbtR+Nvlhw5YZPTfOTUSv
# kjfXWvEpUITHL6YcJewaLiAv646TUPD9+jFUrL6cgYloTPxbRYHzZWzhd6/S39zY
# zV0IGzmHMO0IVaBcE3t0O3Gxh0JaZMk3GjIdjkiByiKr2bCmfKRE9DcqO3gXpLpI
# DX9yDiu/qW7uAVDMkifJW2Xhw8AMYeuGNopKXczXiUOrvvUjJ0o65FkPg5CEhH3L
# cSC8VkRHg8vFHVr3D8Q9ypmnChpih0DOChV7UbZD
# SIG # End signature block
