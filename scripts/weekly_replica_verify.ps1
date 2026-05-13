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
# MII9bQYJKoZIhvcNAQcCoII9XjCCPVoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBPK3y/X14njols
# 98T5WotLLh+1ket6i/HhjvT6k2/BRqCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAD5lfAL
# +yA2/46OAAAAAPmVMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwHhcNMjYwNTEzMTc1NzIwWhcNMjYwNTE2
# MTc1NzIwWjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAi98JwlC98Y0AtqXxNX2n
# ecyTKIY/oel5f58idJvku0DgUkYslyQ7zyeURKP6632ePmiSoC00j1jmURiD2Tma
# LkudfTiHaBrhGW3K8fhX6kxj1hCHDZ26IGmnUBeHjmFl4orAuocfBkTSO2JfngTO
# gQHsQBphyuDlRpURZ33RxtuiCK5AA9FKRVdynmMNBdpvNB1fCqYs9e4SGQ6l3p2Y
# 2J9empJ9riNykbc+FINGKoLlA4CfJ0KiVDZptYqWhaNvAf0DSKg1nqy1nkpjZ08s
# hF1Tqa2i7BTvCo0nO0r+X+0H3c4jiGaW7ZOJqHlF+rqzeb8qvmAyBA0wEcemKxAH
# LaXmqFvu216ppK5BKjlDeM+w8ERwKvdJNqSmTmsnjmsJU8d2tiOpf2O71dzo/Rep
# Nnq8cDct3nd2xbaYi8YLumxSoegHrZhGjLWA83VuxXAavpVKxQTzMFtsY1GKT0L6
# IZaGqV03oowWpkpbJib2d0lPNJKxDRrfVUr6FSjfqnv/AgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBQ2Bxo++FXH8hPOME4h2m+qIOF3HzAfBgNVHSMEGDAWgBSkQwx/dlqlhec+
# jSgPDBeiRWlwxjBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBBT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwMy5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEAMCjLSLS3ojqK5IDK04L5xhwUkDnon4e5lkEwtvSx8EDzjgfjKlsvxalI+hGV
# th03FHiKUncK6WspFmnNnhP0Z1aaCF6EkdGy3OybYbg8RRq/QTwgirSeF6nAmpXZ
# 39rmkNlvRuLWUUEt1PW/jXe1hku9YCszJuA+IM7dPuRoJcy7VQXJvFvMLk/o50vi
# qpglry+YEl+VHg169iNtbeYw2bgVDzPxWasjPg7m9iy1qLQJtkKpfOMxs8AgU5Nf
# 9ihWcEmwEKU6nrBNOaou6x8srt0CQoSSfkiW1L8JccNkaqoqBeNaKTCeaPZBWGIk
# 3nmBH9xZS5Cch9qrufovfFbvwvcbmRLkCbEYVqf9QkwGt97uNwg9lFXDGFcE5bqR
# GG/uQVzn7BBBM1skzxp0C/qdJt5DQ9ltIdYCbxuVzIhgRBiXiYhcPxINkmrkr5eq
# DhVCBXw/C1PjiFeo78eo1Yb1MsYlWDpkyaeCK64CgYmWYMMDBxpTSQATC1RDGTkl
# ne3IYPisaWnCIaXwYe2sdphZ3BWSfyEIHVOODBQ1Wocuanp9QHZqu3YoWclPsOMD
# NmYCj23nSftR+EG6YVaqMJMvJ4tIiQP9r2gkldD69mKZerw4Q3IghwzV/4FsC8hB
# YCfTeMicWiQFPSscFwg/OKT6LscWGuQKZu/1Fllhtcgy5SUwggbFMIIEraADAgEC
# AhMzAAD5lfAL+yA2/46OAAAAAPmVMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwHhcNMjYwNTEzMTc1NzIw
# WhcNMjYwNTE2MTc1NzIwWjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAi98JwlC9
# 8Y0AtqXxNX2necyTKIY/oel5f58idJvku0DgUkYslyQ7zyeURKP6632ePmiSoC00
# j1jmURiD2TmaLkudfTiHaBrhGW3K8fhX6kxj1hCHDZ26IGmnUBeHjmFl4orAuocf
# BkTSO2JfngTOgQHsQBphyuDlRpURZ33RxtuiCK5AA9FKRVdynmMNBdpvNB1fCqYs
# 9e4SGQ6l3p2Y2J9empJ9riNykbc+FINGKoLlA4CfJ0KiVDZptYqWhaNvAf0DSKg1
# nqy1nkpjZ08shF1Tqa2i7BTvCo0nO0r+X+0H3c4jiGaW7ZOJqHlF+rqzeb8qvmAy
# BA0wEcemKxAHLaXmqFvu216ppK5BKjlDeM+w8ERwKvdJNqSmTmsnjmsJU8d2tiOp
# f2O71dzo/RepNnq8cDct3nd2xbaYi8YLumxSoegHrZhGjLWA83VuxXAavpVKxQTz
# MFtsY1GKT0L6IZaGqV03oowWpkpbJib2d0lPNJKxDRrfVUr6FSjfqnv/AgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBQ2Bxo++FXH8hPOME4h2m+qIOF3HzAfBgNVHSMEGDAWgBSk
# Qwx/dlqlhec+jSgPDBeiRWlwxjBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwMy5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEAMCjLSLS3ojqK5IDK04L5xhwUkDnon4e5lkEwtvSx8EDzjgfj
# KlsvxalI+hGVth03FHiKUncK6WspFmnNnhP0Z1aaCF6EkdGy3OybYbg8RRq/QTwg
# irSeF6nAmpXZ39rmkNlvRuLWUUEt1PW/jXe1hku9YCszJuA+IM7dPuRoJcy7VQXJ
# vFvMLk/o50viqpglry+YEl+VHg169iNtbeYw2bgVDzPxWasjPg7m9iy1qLQJtkKp
# fOMxs8AgU5Nf9ihWcEmwEKU6nrBNOaou6x8srt0CQoSSfkiW1L8JccNkaqoqBeNa
# KTCeaPZBWGIk3nmBH9xZS5Cch9qrufovfFbvwvcbmRLkCbEYVqf9QkwGt97uNwg9
# lFXDGFcE5bqRGG/uQVzn7BBBM1skzxp0C/qdJt5DQ9ltIdYCbxuVzIhgRBiXiYhc
# PxINkmrkr5eqDhVCBXw/C1PjiFeo78eo1Yb1MsYlWDpkyaeCK64CgYmWYMMDBxpT
# SQATC1RDGTklne3IYPisaWnCIaXwYe2sdphZ3BWSfyEIHVOODBQ1Wocuanp9QHZq
# u3YoWclPsOMDNmYCj23nSftR+EG6YVaqMJMvJ4tIiQP9r2gkldD69mKZerw4Q3Ig
# hwzV/4FsC8hBYCfTeMicWiQFPSscFwg/OKT6LscWGuQKZu/1Fllhtcgy5SUwggco
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
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakzCC
# Go8CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENB
# IDAzAhMzAAD5lfAL+yA2/46OAAAAAPmVMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIKlec9m7LL6u9KqsGZzCMGPpuDqeBOATffntw3TeVdCXMA0GCSqGSIb3
# DQEBAQUABIIBgDYKMyLmE3dVEwLT3eD91CT7xQv7Va4lZluBDQIXXLe92boXbKQ4
# /JLgvdm4S6dFMTfHSMNshykDrPfMVojcpwMDEX4wy+vXsbF6VRRZRcRaVeNQnKnk
# uRHd3I7XNfMPNNTmCTgpd4y+0fJbx1Tn/Bn8FONaP1roigypsafgMesxxZbC7zDb
# Oxx5vuwJr9rk3IwoRwn1aeILbeZOLTvRPlweBtqYANGD2Mc5WFj+jcV/0bEVqno3
# ovDfxRTHauMAiL769OKGYDQzqPpRAAE4DZCLsZgKVpd7UHg/wBZjg3DWVJhw5tPp
# y8854GrFoJlLdOT/8ScBY96p9zH4qrrn1DqISVDKCcnhqLXBIs+SBBJW4ePMTtBu
# 56OQs4MLIQqgsrmRrA3yOpVxyp49N0b/vrZ7D3w9g5+g2aenYRcvVvSAQjZ2/MLW
# NvNoTl+N9JoGSac5WQZHx//KPQi34rkfSl7AczzLImJCV6ac/GwgePvBNpUg29BP
# fiXLwn7FgK6tSaGCGBMwghgPBgorBgEEAYI3AwMBMYIX/zCCF/sGCSqGSIb3DQEH
# AqCCF+wwghfoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFhBgsqhkiG9w0BCRABBKCC
# AVAEggFMMIIBSAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCD7+JAt
# j/Ut/b/LXO9RZen6nwr2nTJ3Dk6ZuR6uvOU/zAIGaeddmzRLGBIyMDI2MDUxMzE4
# NDAzMi41OFowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
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
# /Au81Rzh05UHAivorQ3Os8PELHIgiOd9TWzbdgmGzcILt/ddVQERMYIHRjCCB0IC
# AQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjANBglghkgBZQMEAgEFAKCCBJ8w
# EQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAc
# BgkqhkiG9w0BCQUxDxcNMjYwNTEzMTg0MDMyWjAvBgkqhkiG9w0BCQQxIgQg1jYV
# hKU89glCIe/7ZfIgD+Me9maJy+fLMDIqjPv+UUEwgbkGCyqGSIb3DQEJEAIvMYGp
# MIGmMIGjMIGgBCC2DDMlTaTj8JV3iTg5Xnpe4CSH60143Z+X9o5NBgMMqDB8MGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjCCA2EGCyqGSIb3DQEJEAISMYIDUDCC
# A0yhggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTUwMC0wNUUwLUQ5
# NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcg
# QXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD/c/cpFSqQWYBeXggyRJ2ZbvYEEaBn
# MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2u3OgwIhgPMjAyNjA1MTMxMTIwMDha
# GA8yMDI2MDUxNDExMjAwOFowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7a7c6AIB
# ADAKAgEAAgIjzgIB/zAHAgEAAgISIDAKAgUA7bAuaAIBADA2BgorBgEEAYRZCgQC
# MSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqG
# SIb3DQEBCwUAA4IBAQBteLyRoEfxypfNXLvZpMFWrO85CckSPlZmNtmq/W9QUPMA
# 4TlO0mCMSWB8KUkEWJhayXM+lA5i6i/4V4b7mYIG6aFVNIAjU7+BJ8bu3BZ9bE7+
# 6MmDy+8mlnbydgqTyyQpWBuYfjVxC1j1e6JqQjfEj9jFDxQdvltJ3nOhjPXhKzYT
# dzrZ4Z+in7qLeRtSzILYo1CPUprA672akuIzviu5T2sdExQfyVj66tfDipWCfc6c
# b1OS3Xcpc33Av5IHLfmZoXq8rfeYd5gvSIdeb6YRKmFqlQNDNUu5fyxEtCE3lsJ3
# oLjGMmVb5HYtorZujf1X8NWFDY0Txqb1m8h5/a2hMA0GCSqGSIb3DQEBAQUABIIC
# AF6a/Xq0dwwpEk3nKjGlXDl5hcH8OjbDLGAdVqXDmkouycFvJ98cnPir37k5q9AD
# qd0JP/eemHzBovjaSVX/odOYFbNj8Tl7ANGGsXJ7kJte8pgg+M0PYlNMfuiaq/4d
# YDRbUdlA9Td3QgV1kotUirCAbTyjuIJu1GzmjE6N31SEcGOfGQATscaGOdSrAFOy
# UwIUEiVOqK7QiwER1iyJSLnlDviLS3RDPlC9Av9BkthTiqBmilzJQDE/UUlODIwQ
# xQPoQsBycRC6FyvguzqFWG51ulPSxfqwiuyz/xPbKcn6W6Yuaovt0eV3XB+PAv9E
# WyctigeWj9qP8f19bBNwtUiml6baKJr6k3rovw+Edl4AIqLYEWSkw3LLKMnQknYC
# 1T5u243UMM3Wh3qHiUAKH/NlSVXA99kNPLuI5Geay+VZ+j0JKZqX837mXJBmyniW
# okNI3vDbOfqvzoc/YKLhd2xd09lF2BiM6UakGiG0BtIcKU2BUUn9j8f9JDz3opES
# vBdhkrFMNapBMzS/BZIZ8QDFmh6ltG8nTmBFhtSuVkKtlVa9bjYvjjXoSFLYwjhK
# X7YOfO0NREZcRgR3Ctq5JbmP6SKH/H5Ogpo94dlcu4F/bluo4GkjIZLLlrcE8tyP
# Cw8kz430YAgRo4xLzqLdyFMVmpKWXRYWF70cINOF1pa+
# SIG # End signature block
