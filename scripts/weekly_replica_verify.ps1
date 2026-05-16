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

# SIG # Begin signature block
# MII9awYJKoZIhvcNAQcCoII9XDCCPVgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBErGZTZEzukKPc
# RoGqYtZ88S0lklKmlL8aT96FfkFm0aCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAEQB7Jf
# AW3AtcBgAAAAARAHMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNTE1MTc1MDQ1WhcNMjYwNTE4
# MTc1MDQ1WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAr2LJ61/gYnFRuY9peqbv
# go3sQvA7PRqazQn16PSaFdy16sJ9KKjR8jmqyFDiueZVUuRh94tt3m7Wqry34dhF
# p1Xf+grajrMdQNkh3QmevtT9oKXSv27N7P/rjjGdAyx2F5Nd9I2Tf2ArfHmHWpQx
# uCDjk+UuV19xcF9GIa8HkgJS6jEaKcaJ5QR2Hi1Rr9lIv3GmOEB8Au+Jz6AAzSdZ
# HcYFYTMwv+QUO7lg7Suuze/JbdtfUyHjK4V746uTJuNCOW8LPgq/5qYeDjFuv/W3
# 33rHFbYoIyGR8pbmmnT97tpRxvRQpp4pfrqazUqbPOF7TDlgaEpsE0ThX3Q1wkuY
# sJakywElLOc6rJilkawNUUI4iIXyelKg/+c8LGb9mK2PTdZvYrAGP2+aKw6/3FvD
# BCvCZmNCiUxr1niEykzFN6BdHA09pMKZT4smdkx0w8g2PUlk1QnI+tqe07PXI4NZ
# DsK+rWnMGrzPIeTv8n5qtBZQFL+uhdXcYPPj6mPgxpWpAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBQwat2ukhyLpm/JD4NOfdCL6xZXADAfBgNVHSMEGDAWgBRrXqU0wwXFYkoh
# Wo6rc2Bi1KxjhTBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBFT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwMy5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEArGmHo6zVXEkxr5MsyaHWDPauCXLIx8XUhC6/+Mw1/e/Mlxh5U1Pw5yFc3BRs
# pQQbxgCcL4TTaIW5o34jGcWd2zZDrCou0pISfQ5KY01aUu24j2wIujKS6pinrpl8
# oo62+kXirCNKB5bq/Rn8dIi/AikuZHXxP5iud2gq+wk/jOyAdUX7qQjEMG7EVMb4
# petMTcQHWam6YGvFQEKY4ZZuToB7Ar6fTLKenLQizKgg/We67BRkBdArzQxv3rVx
# yoS52KVlQMBro41hYdWQxjeT0ybYAxIo3FhtOq5vnaHPJd/8horVuAg38yTjuzRa
# e8FoibJhrjydFO1V5vqAbLLlQX+RGRO79c7XtAIzicE6cXJIMAQh0Q107F+qYx5e
# aDdYjbXTSO7oyiA47ls/ZsAOBKkh41IgPB9/1D3fa3XwDQmImuqNIzr+UAcNL1lC
# wuXycdne4KSuPXtsJIVTbiwvodXDZFZGlXew+ChCx3rpfOtlE+t7SyMlDvUujkR7
# y3/ouyTJkUX63KMjm5Y+9GKRoN1/vdw+lOm68i597EqHsEueK5sq67JBNhbZ+OmG
# dzj10XS0u6EDYhfqxkCuLGhCgB/2DV9HRkIeWquHy08P7yKoAiz4znF0XBHq1K7N
# xAZocQ6UU/0vAOUwDTcFdWOv7baX4LcXolyRNv5qQ98CXAowggbFMIIEraADAgEC
# AhMzAAEQB7JfAW3AtcBgAAAAARAHMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDMwHhcNMjYwNTE1MTc1MDQ1
# WhcNMjYwNTE4MTc1MDQ1WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAr2LJ61/g
# YnFRuY9peqbvgo3sQvA7PRqazQn16PSaFdy16sJ9KKjR8jmqyFDiueZVUuRh94tt
# 3m7Wqry34dhFp1Xf+grajrMdQNkh3QmevtT9oKXSv27N7P/rjjGdAyx2F5Nd9I2T
# f2ArfHmHWpQxuCDjk+UuV19xcF9GIa8HkgJS6jEaKcaJ5QR2Hi1Rr9lIv3GmOEB8
# Au+Jz6AAzSdZHcYFYTMwv+QUO7lg7Suuze/JbdtfUyHjK4V746uTJuNCOW8LPgq/
# 5qYeDjFuv/W333rHFbYoIyGR8pbmmnT97tpRxvRQpp4pfrqazUqbPOF7TDlgaEps
# E0ThX3Q1wkuYsJakywElLOc6rJilkawNUUI4iIXyelKg/+c8LGb9mK2PTdZvYrAG
# P2+aKw6/3FvDBCvCZmNCiUxr1niEykzFN6BdHA09pMKZT4smdkx0w8g2PUlk1QnI
# +tqe07PXI4NZDsK+rWnMGrzPIeTv8n5qtBZQFL+uhdXcYPPj6mPgxpWpAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBQwat2ukhyLpm/JD4NOfdCL6xZXADAfBgNVHSMEGDAWgBRr
# XqU0wwXFYkohWo6rc2Bi1KxjhTBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwMy5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEArGmHo6zVXEkxr5MsyaHWDPauCXLIx8XUhC6/+Mw1/e/Mlxh5
# U1Pw5yFc3BRspQQbxgCcL4TTaIW5o34jGcWd2zZDrCou0pISfQ5KY01aUu24j2wI
# ujKS6pinrpl8oo62+kXirCNKB5bq/Rn8dIi/AikuZHXxP5iud2gq+wk/jOyAdUX7
# qQjEMG7EVMb4petMTcQHWam6YGvFQEKY4ZZuToB7Ar6fTLKenLQizKgg/We67BRk
# BdArzQxv3rVxyoS52KVlQMBro41hYdWQxjeT0ybYAxIo3FhtOq5vnaHPJd/8horV
# uAg38yTjuzRae8FoibJhrjydFO1V5vqAbLLlQX+RGRO79c7XtAIzicE6cXJIMAQh
# 0Q107F+qYx5eaDdYjbXTSO7oyiA47ls/ZsAOBKkh41IgPB9/1D3fa3XwDQmImuqN
# Izr+UAcNL1lCwuXycdne4KSuPXtsJIVTbiwvodXDZFZGlXew+ChCx3rpfOtlE+t7
# SyMlDvUujkR7y3/ouyTJkUX63KMjm5Y+9GKRoN1/vdw+lOm68i597EqHsEueK5sq
# 67JBNhbZ+OmGdzj10XS0u6EDYhfqxkCuLGhCgB/2DV9HRkIeWquHy08P7yKoAiz4
# znF0XBHq1K7NxAZocQ6UU/0vAOUwDTcFdWOv7baX4LcXolyRNv5qQ98CXAowggco
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
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakTCC
# Go0CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENB
# IDAzAhMzAAEQB7JfAW3AtcBgAAAAARAHMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIOEvN4/15y6X64RBPzDlSlegPFsTqM2tGuaUXjEdbLRcMA0GCSqGSIb3
# DQEBAQUABIIBgFoBvWae9WN4Np0hAukufOHg//2TQCj0tvzjcuJyoM97JT6dTuGx
# 9pjqsTqlhCziZab0r/64OKnXtipAU7pdKDhVgL+Vxkb3wD6CQbkDjYmueOS7fg2l
# jzKyDFPELMAB+1bxDL7JWroeNYQ0Vj3jhnel/06PTynYnwq8OZhg80W+XJNtBnVQ
# L30PP0D2dvsxaWIboYNeBBNfZBdH8L1R+rtPgEsRmRkDxRV9QE5gHYVEVGxZ5BBQ
# Aec7ChdaE+YO2oZEvyHZPgsJJHfIYCfefgxbHumoOUHzjUVPbEpCoRoBpbUweER+
# htI8M/auBIysfj0srJ1RTYhCDqNHkMNFYhZ18DjNwzR2sYJiumghZINA0mv3viH8
# AZKflJ63F5ffPRbtvLVop6j/u9Oo2vXFk5lQuSzpcxkulCgM5DGyi14eMf9eVu/T
# ohPtnztyr3ab03b15NIu0fe+0Mol2TbkBDXSbcKRyJ2yyhXxG/XNAkmvYcPqrh/w
# y5YMAr7BCoPAv6GCGBEwghgNBgorBgEEAYI3AwMBMYIX/TCCF/kGCSqGSIb3DQEH
# AqCCF+owghfmAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFiBgsqhkiG9w0BCRABBKCC
# AVEEggFNMIIBSQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAhQZms
# mjGCn+0UXpqoU6vaO1zE/at1kSSp1QvCVr03lwIGaeddoz10GBMyMDI2MDUxNjE0
# NDE0NC4wOTJaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
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
# Q/wLvNUc4dOVBwIr6K0NzrPDxCxyIIjnfU1s23YJhs3CC7f3XVUBETGCB0Mwggc/
# AgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjACEzMAAABWfo+dWAiO6WAAAAAAAFYwDQYJYIZIAWUDBAIBBQCgggSc
# MBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MDUxNjE0NDE0NFowLwYJKoZIhvcNAQkEMSIEIOSs
# KwOrf9Ho3490EZMMAx/iEw/j9BGSqRMvsfXN4n47MIG5BgsqhkiG9w0BCRACLzGB
# qTCBpjCBozCBoAQgtgwzJU2k4/CVd4k4OV56XuAkh+tNeN2fl/aOTQYDDKgwfDBl
# pGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENB
# IDIwMjACEzMAAABWfo+dWAiO6WAAAAAAAFYwggNeBgsqhkiG9w0BCRACEjGCA00w
# ggNJoYIDRTCCA0EwggIpAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkE1MDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUA/3P3KRUqkFmAXl4IMkSdmW72BBGg
# ZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDtstFoMCIYDzIwMjYwNTE2MTEyMDA4
# WhgPMjAyNjA1MTcxMTIwMDhaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO2y0WgC
# AQAwBwIBAAICK6MwBwIBAAICEhowCgIFAO20IugCAQAwNgYKKwYBBAGEWQoEAjEo
# MCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG
# 9w0BAQsFAAOCAQEAdbajHJXDPs1gw9BuRBX67Xog1RJpc3Apz5tuF5cDI4Lf7BlD
# 2MxKbFrRUZejjUU8HX0ZOLJJ6LeMeZiOe5lqOQ7Y8eQ9LkMmoTlLkvgGnivgCfUY
# hxGmi+Uay1tE7in1ZdilSRbcPO0Y5oRrg33PKmCi/DQrzHVkL3pAhIl+FsvEwPb8
# 9csQ7j5ubRJFFRTm80z1iZrTWTN2sgY7l9lV8CfTkHBEfj7zsfqLWQuB0nX3jmyc
# /EpN79qfTMzBfr7u7DynspPhjLINdQ0bvISCyAUl6SCrFjXnFJj0pjy6K1YZuNL2
# 6A+whs3DaKtgDmS3K0aZ5oxGPv7mwGYv2GahgjANBgkqhkiG9w0BAQEFAASCAgBi
# Utg8dwwwAt2JHeCdCElq5ywo9wtesp9onzs9nsvRdw4NccJL2ewf0vDGnaWLmlAp
# gRPToqA1IgLs36bUZNpKK09uVwN2zI36Z9+Vnrt7+zV6vZErVptPk7Y3E7H7ofAQ
# MIIy9KFDKDMila5Txv9unvjrHsCVX6QE9/VJWLsmoAc0uokvHIBvhLfgZk/H5Ays
# q7ls6NXKZVr9tr7sSDJUyeNYouoMyZ9jmPptXT9+fxRKbu1PnFji6uvfi/KCX/5L
# uOa0/Gogxyev8gv4T0soAArQQa841PpHHtUfj37PypouCO1FLKo4BtkEqXBh2CdL
# WkJxmicQ14Mk69a1IrHcKTgyNBZO3LpXLFodxxPCKw5+5qd1n5wgH5dUeMM8yLXA
# Vm/cFlvUlO/PRIzKKGbL0HV9YPC06gO2QLETHv3j8cvgXDU0N8PmjAAFUqlx1qK4
# PySyqDv91i1bxtMTu6OMo0k3FlzlzoE2lQbNyuv5BTnOSCNzsMJ04QLNqjAG2H4i
# SwAKQ54nHGu4Id0LSwwlfT9hYEPF/MP2gkysXrViEDpdJ8kVUL3DZ8efeYdAfSjP
# CVp2cpW6rIv5wtcRN7bUcmYWuDxoEm4QlFzNMjiz5uFlVpV359w6zedUtDnGj5Ie
# NqzYQV43ceHmtr3A4QVGHI8l4oP9u/U3zu+aTdYV6w==
# SIG # End signature block
