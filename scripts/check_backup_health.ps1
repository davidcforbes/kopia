# check_backup_health.ps1 -- Parse the latest daily_kopia backup run and emit a
# Windows toast notification (PASS/FAIL) under the RustBack.HealthCheck AUMID.
#
# Scheduled daily at 08:00 by \Backup\KopiaBackupHealthCheck.
[CmdletBinding()]
param(
    [string]$LogFile      = 'C:\dev\kopia\logs\daily_kopia.log',
    [string]$HeartbeatLog = 'C:\dev\kopia\logs\heartbeat.log',
    [string]$Aumid        = 'RustBack.HealthCheck',
    # Treat the run as stale (FAIL) if newer than this many hours hasn't completed.
    [int]$StaleHours          = 30,
    # Treat an in-progress run as STALL (FAIL) if heartbeat-line is older
    # than this. epic kopia-bcp: with --heartbeat-interval=60s, three missed
    # ticks is the minimum-confidence "really gone" signal.
    [int]$HeartbeatStaleSec   = 180
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $LogFile)) {
    $title  = 'Kopia Backup: NO LOG'
    $body   = "Log file missing: $LogFile"
    $status = 'FAIL'
} else {
    $lines = Get-Content -Path $LogFile

    $startIdx = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match 'Daily Kopia backup start') { $startIdx = $i; break }
    }

    if ($startIdx -lt 0) {
        $status = 'FAIL'; $title = 'Kopia Backup: NO RUN FOUND'; $body = 'No "Daily Kopia backup start" line in log.'
    } else {
        $run = $lines[$startIdx..($lines.Count - 1)]
        # Pull the timestamp from the start line (format: "Mon MM/DD/YYYY  HH:MM:SS.ff -- Daily Kopia backup start")
        $startTime = $null
        if ($run[0] -match '^[A-Za-z]{3}\s+(\d{2}/\d{2}/\d{4})\s+(\d{2}:\d{2}:\d{2})') {
            $startTime = [datetime]::ParseExact("$($Matches[1]) $($Matches[2])", 'MM/dd/yyyy HH:mm:ss', $null)
        }

        $exitLine     = ($run | Where-Object { $_ -match 'Exit codes: repo=' } | Select-Object -Last 1)
        $completeLine = ($run | Where-Object { $_ -match 'Daily Kopia backup complete' } | Select-Object -Last 1)
        $fatalLine    = ($run | Where-Object { $_ -match 'FATAL:' } | Select-Object -First 1)

        if ($fatalLine) {
            $status = 'FAIL'
            $title  = 'Kopia Backup: FAIL'
            $body   = ($fatalLine -replace '^[A-Za-z]{3}\s+\S+\s+\S+\s+--\s+', '').Trim()
        }
        elseif (-not $completeLine) {
            $age = if ($startTime) { [int]((Get-Date) - $startTime).TotalHours } else { 999 }
            # Heartbeat-staleness check (epic kopia-bcp.4): if the upstream
            # server's heartbeat-line is older than $HeartbeatStaleSec, the
            # in-progress run is presumed dead -- fail fast instead of waiting
            # the 30h StaleHours window.
            $hbStale = $true
            $hbAgeSec = -1
            if (Test-Path $HeartbeatLog) {
                $hbAgeSec = [int]((Get-Date) - (Get-Item $HeartbeatLog).LastWriteTime).TotalSeconds
                $hbStale = $hbAgeSec -gt $HeartbeatStaleSec
            }
            if ($age -ge $StaleHours) {
                $status = 'FAIL'; $title = 'Kopia Backup: STALE'
                $body   = "Last run started $age h ago, never completed."
            } elseif ($hbStale) {
                $status = 'FAIL'; $title = 'Kopia Backup: STALL'
                $body   = "Run from $startTime in progress but upstream server heartbeat is $hbAgeSec s old (>$HeartbeatStaleSec s)."
            } else {
                $status = 'PENDING'; $title = 'Kopia Backup: RUNNING'
                $body   = "Run from $startTime is still in progress (heartbeat $hbAgeSec s old)."
            }
        }
        else {
            # Parse "Exit codes: repo=N snap1=N snap2=N maint=N errors=N"
            $rc = @{}
            if ($exitLine -match 'repo=(\d+)\s+snap1=(\d+)\s+snap2=(\d+)\s+maint=(\d+)\s+errors=(\d+)') {
                $rc.repo=[int]$Matches[1]; $rc.snap1=[int]$Matches[2]; $rc.snap2=[int]$Matches[3]
                $rc.maint=[int]$Matches[4]; $rc.errors=[int]$Matches[5]
            }
            $bad = ($rc.Values | Where-Object { $_ -ne 0 } | Measure-Object).Count
            if ($bad -eq 0) {
                $status = 'PASS'; $title = 'Kopia Backup: PASS'
                $body   = "Completed $startTime  (all stages rc=0, 0 errors)"
            } else {
                $status = 'FAIL'; $title = 'Kopia Backup: FAIL'
                $body   = "Completed $startTime  (repo=$($rc.repo) snap1=$($rc.snap1) snap2=$($rc.snap2) maint=$($rc.maint) errors=$($rc.errors))"
            }
        }
    }
}

# Emit toast via the registered AUMID. Uses the WinRT XML APIs directly; no
# external module dependency (BurntToast, etc).
# Silent on PASS: watchdogs only toast when something is wrong.
if ($status -ne 'PASS') {
    $null = [Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime]

    $xml = @"
<toast>
  <visual>
    <binding template='ToastGeneric'>
      <text>$([System.Security.SecurityElement]::Escape($title))</text>
      <text>$([System.Security.SecurityElement]::Escape($body))</text>
    </binding>
  </visual>
</toast>
"@

    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast    = [Windows.UI.Notifications.ToastNotification]::new($doc)
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Aumid)
    $notifier.Show($toast)
}

Write-Host "$status -- $title -- $body"
if ($status -eq 'FAIL') { exit 1 } else { exit 0 }
# SIG # Begin signature block
# MII9awYJKoZIhvcNAQcCoII9XDCCPVgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCACUqXejG0C2+hm
# HFD/Fe3jFnpQOLX4kntGRat10zYd56CCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAEtbKm3
# Mu04MYwNAAAAAS1sMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNTE4MTc1MjI4WhcNMjYwNTIx
# MTc1MjI4WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAteMeWV4qcDkjDU9o8Vsf
# +8aimerhkD7QjnYhPuOA0ooqKzdC58dLkrEmEngklAOBFzhT05bKkbCtCEwT+q1+
# 5yJGmda3uwPhIm6r9jCBK9q44FYLBSOH+xuAk54raSZE/nVtWwpnTkYh0nw1TNne
# wH4TZA5W6vSGLNuksKfj0CwW9zWMI7+clSuUucu1VB9n+HyZcH+AjRbPruelh3x2
# PSjH9orDlH+quvnRJZm2DIE9pb8LS//wPWZA/59lfyU367z5imRf5NuYcK6EoBj1
# wVTwLh3xhDdCZ88DVE6SydHnTzUQpntLle0+jQ4lkXvS9PHIBTHcXkfOy/IIDUp+
# WrQrm99A1dy1eexUFdgvf+bkxzeMAqZfPfuHS/r4Si6xIp0MCPfouKUEkOXWWrJH
# WMI/Dtp+5cJfLVtd9b0dBwstKLJXaEs5WWSL5TQAHKHAQx+rbDDyhJxOuGKzKxEY
# X+NPcsxVXYkXS3LE0nWL7R3wthxaFPtNaP7lUx/fGOvFAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBSP044ig9IeEbOQyK4ZzyoAsjD99jAfBgNVHSMEGDAWgBSa8VR3dQyHFjdG
# oKzeefn0f8F46TBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBFT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwNC5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEALqQI6Ju6qI2FRjasZ6+rVyH15siAEE/zv83AoQ8ToGXYOaVT3TE4/hEptEKW
# vu8AgmiW70NHvYfGygfCuVrSjgakNd4Fx+fDLJJJ4OuQPizZKu5SIWjfAs0kXNCZ
# NymzpG5YB09tyzkT4C8/31DdMCWrOr5+6ZZoD+S40BLT1L+cS63SsHs3poK2/HAF
# V3Iv75jBKUqDKi2ApNupto68I/piqWjSyMCLMaGZigZBahkIxi1vJeSOmMd1ef43
# npvSqfuauHvp6unuJ8gj4+qXCu41GxVcYMxIDwkyKzs41fMKNVK9pRJl+3bs8ZGz
# Nz/lWc06i7dYP0K6wCJUmrJQw6a3n80Il9C3mlqabg/mDmZsDb7uk9LNYfPigNwL
# dq1xQkPPn3a0w4fanG3NrQNhJqvNKAJ7op+mr6w9BPdKCw69MfoOzyrD2S5w/kAD
# 4P1X1v1HNPbWhY8CS64N2ySn2ri8sxGCMZ5so4SBaZoKVYqGmIAAy+IZWXhF5RxA
# hgZPUNuanx5ygMqAxbgwN41j7ybUOGhBrl6HFVW5SNd0oD9hOu6dcmCH5KqZXWkH
# BzWG4ZlTW1mhWaIwdR1vIGPCjhqe2YoLuVaBhdKX/8gb5OFYB4Y7X4Z26l4WMHKC
# w+Lf+bMKjBRYBPrtJIYaaE0dFvlMGqJ20XTmFhG5KTjm8kcwggbFMIIEraADAgEC
# AhMzAAEtbKm3Mu04MYwNAAAAAS1sMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYwNTE4MTc1MjI4
# WhcNMjYwNTIxMTc1MjI4WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAteMeWV4q
# cDkjDU9o8Vsf+8aimerhkD7QjnYhPuOA0ooqKzdC58dLkrEmEngklAOBFzhT05bK
# kbCtCEwT+q1+5yJGmda3uwPhIm6r9jCBK9q44FYLBSOH+xuAk54raSZE/nVtWwpn
# TkYh0nw1TNnewH4TZA5W6vSGLNuksKfj0CwW9zWMI7+clSuUucu1VB9n+HyZcH+A
# jRbPruelh3x2PSjH9orDlH+quvnRJZm2DIE9pb8LS//wPWZA/59lfyU367z5imRf
# 5NuYcK6EoBj1wVTwLh3xhDdCZ88DVE6SydHnTzUQpntLle0+jQ4lkXvS9PHIBTHc
# XkfOy/IIDUp+WrQrm99A1dy1eexUFdgvf+bkxzeMAqZfPfuHS/r4Si6xIp0MCPfo
# uKUEkOXWWrJHWMI/Dtp+5cJfLVtd9b0dBwstKLJXaEs5WWSL5TQAHKHAQx+rbDDy
# hJxOuGKzKxEYX+NPcsxVXYkXS3LE0nWL7R3wthxaFPtNaP7lUx/fGOvFAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBSP044ig9IeEbOQyK4ZzyoAsjD99jAfBgNVHSMEGDAWgBSa
# 8VR3dQyHFjdGoKzeefn0f8F46TBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwNC5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEALqQI6Ju6qI2FRjasZ6+rVyH15siAEE/zv83AoQ8ToGXYOaVT
# 3TE4/hEptEKWvu8AgmiW70NHvYfGygfCuVrSjgakNd4Fx+fDLJJJ4OuQPizZKu5S
# IWjfAs0kXNCZNymzpG5YB09tyzkT4C8/31DdMCWrOr5+6ZZoD+S40BLT1L+cS63S
# sHs3poK2/HAFV3Iv75jBKUqDKi2ApNupto68I/piqWjSyMCLMaGZigZBahkIxi1v
# JeSOmMd1ef43npvSqfuauHvp6unuJ8gj4+qXCu41GxVcYMxIDwkyKzs41fMKNVK9
# pRJl+3bs8ZGzNz/lWc06i7dYP0K6wCJUmrJQw6a3n80Il9C3mlqabg/mDmZsDb7u
# k9LNYfPigNwLdq1xQkPPn3a0w4fanG3NrQNhJqvNKAJ7op+mr6w9BPdKCw69MfoO
# zyrD2S5w/kAD4P1X1v1HNPbWhY8CS64N2ySn2ri8sxGCMZ5so4SBaZoKVYqGmIAA
# y+IZWXhF5RxAhgZPUNuanx5ygMqAxbgwN41j7ybUOGhBrl6HFVW5SNd0oD9hOu6d
# cmCH5KqZXWkHBzWG4ZlTW1mhWaIwdR1vIGPCjhqe2YoLuVaBhdKX/8gb5OFYB4Y7
# X4Z26l4WMHKCw+Lf+bMKjBRYBPrtJIYaaE0dFvlMGqJ20XTmFhG5KTjm8kcwggco
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
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakTCC
# Go0CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENB
# IDA0AhMzAAEtbKm3Mu04MYwNAAAAAS1sMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIF3OCSedY4TVNsXl3pFxLwO4FfdgWXGOJffddOp9rEXRMA0GCSqGSIb3
# DQEBAQUABIIBgKQYRJSTZloBh/EZoFSoQ/ZV0iMeLz8EIsl/e+7fwjktWrSK3blI
# Fq8kzoLa4SmxIuClGrhgGJcx9pmDxR9D1BCL5cw35B+CpWEQYOsecgOIG4YWoeuy
# nI21iWDDIOpLBphvPshz09b+T0AFK2DozckNJfzLmA/osfsSc7gLVVl06MbJa804
# mLlvTF8Wz+PlXtN9O9JyeFt2RXXHTOMog7J3xau5D7kZDSPrn9S+as0SaxdNdczw
# x0bFIHRh8l/PIWkUqJr4E6Cf0Pi0WU2Zmt184c09XV9PuYSD+uL6ycnjXAEknZm4
# Z0uu3vJm/lMorst38NX8lX8qnU3JpJUTmLuw7KWm2MI6D8ZWTdQTTcdjHCcbRY9J
# nDU7RlvPSOilik9bIvXUWkpa9uj4Z+S4VsjLn8Fik5cQIuRIMXyfk6jkIQUeHkfJ
# I3/mYut70FW7QTThmctc6KkpL90vOfJ/Oc+6AoQVeRoesJC+aZFTC3kupPT6fyIs
# y0omRVEixpZOlqGCGBEwghgNBgorBgEEAYI3AwMBMYIX/TCCF/kGCSqGSIb3DQEH
# AqCCF+owghfmAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFiBgsqhkiG9w0BCRABBKCC
# AVEEggFNMIIBSQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCma/A4
# CjtDKL8CikroPazMVCmiYI1Tsbq3e99Dq0RnNwIGaedYijHDGBMyMDI2MDUxOTAw
# MzEzNS42ODRaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRp
# b25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5NDcxNTAz
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
# yX4lhthsGHumaABdWzCCB5cwggV/oAMCAQICEzMAAABXJNOV4KLpyTEAAAAAAFcw
# DQYJKoZIhvcNAQEMBQAwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGlt
# ZXN0YW1waW5nIENBIDIwMjAwHhcNMjUxMDIzMjA0NjUzWhcNMjYxMDIyMjA0NjUz
# WjCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UE
# CxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVs
# ZCBUU1MgRVNOOjc4MDAtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALFspQqTCH24syS2NZD1ztnJl9h0Vr0WwJnikmeXse/4
# wspnVexGqfiHNoqkbVg5CinuYC+iVfNMLZ+QtqhySz8VGBSjRt1JB5ACNtTKAjfm
# Fp4U/Cv2Lj4m+vuve9I3W3hSiImTFsHeYZ6V/Sd43rXrhHV26fw3xQSteSbg9yTs
# 1rhdrLkAj4KmI0D5P4KavtygirVyUW10gkifWLSE1NiB8Jn3RO5dj32deeMNONaa
# Pnw3k49ICTs3Ffyb+ekNDPsNfYwCqPyOTxM6y1dSD0J5j+KK9V+EWyV5PDjV8jjn
# 1zsStlS6TcYJJStcgHs2xT9rs6ooWl5FtYfRkCxhDShEp3s8IHUWizTWmLZvAE/6
# WR2Cd+ZmVapGXTCHJKUByZPxdX0i8gynirR+EwuHHNxEilDICLatO2WZu+CQrH4Z
# q0NYo1TQ4tUpZ/kAWpoAu1r4mW5EJ3HkEavQ2PuoQDcDq2rAGVIla9pD7o9Yxwzl
# 81BuDvUEyu9D/6F0qmQDdaE791HxfCUxpgMYPpdWTzs+dDGPehwQ8P92yP8ARjby
# 5Ony1Z68RjeQebpxf5WL441myFHcgT1UJzzil7tPEkR22NfTNR6Fl+jzWb/r80nq
# lXllhynSowtxo1Y22xqYviS24smikUsBKqOPbSS77uvXEO3VrG5LGouE1EZ1Y9pj
# AgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQUjoPJXi01DgIJSGfm416Yg+0SkqcwHwYD
# VR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBhoF+gXYZb
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIw
# UHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNybDB5Bggr
# BgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0
# YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEGDCsGAQQB
# gjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqGSIb3DQEB
# DAUAA4ICAQBydcB2POmZOUlAQz2NuXf7vWCVWmjWu9bsY1+HMjv1yeLjxDQkjsJE
# U5zaIDy8Uw9BYN8+ExX/9k/9CBUsXbVlbU44c65/liyJ83kWsFIUwhVazwSShFlb
# IZviIO/5weyWyTfPPpbSJgWy+ZE9UrQS3xulJLAHA2zUkMMPdAlF4RrngcZZ0r45
# AF9aIYjdestWwdrNK70MfArHqZdgrgXn03w6zBs1v7czceWGitg/DlsHqk1mXBpS
# TuGI2TSPN3E60IIXx5f/AFzh4/HFi98BBZbUELNsXkWAG9ynZ5e6CFiil1mgWCWO
# T90D7Igvg0zKe3o3WCk629/en94K/sC/zLOf2d7yFmTySb9fKjcONH1Db3kZ8MzE
# J8fHTNmxrl10Gecuz/Gl0+ByTKN+PambZ+F0MIlBPww6fvjFC9JII73fw3qO169+
# 9TxTz2G+E26GYY1dcffsAhw6DqTQgbflbl1O/MrSXSs0NSb9nBD9RfR/f8Ei7DA1
# L1jBO7vZhhJTjw2TzFa/ALgRLi3W00hHWi8LGQaZc8SwXIMYWfwrN9MgYbhN0Iak
# 9WA2dqWuekXsTwNkmrD3E6E+oCYCehNOgZmds0Ezb1jo7OV0Kh22Ll3KHg3MHtlG
# guxAzhg/BpixPS4qrULLkAjO7+yNsUfrD2U9gMf/OR4yJDPtzM0ytTGCB0Mwggc/
# AgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjACEzMAAABXJNOV4KLpyTEAAAAAAFcwDQYJYIZIAWUDBAIBBQCgggSc
# MBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MDUxOTAwMzEzNVowLwYJKoZIhvcNAQkEMSIEIIT4
# XtafkooG2PKhHP0jtBoouWG9smxnNd6ErdvFqb2gMIG5BgsqhkiG9w0BCRACLzGB
# qTCBpjCBozCBoAQg9TyfZLUFbkxliGyizuH9VVDpVFNvQEQhKQ2ZhUx421IwfDBl
# pGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENB
# IDIwMjACEzMAAABXJNOV4KLpyTEAAAAAAFcwggNeBgsqhkiG9w0BCRACEjGCA00w
# ggNJoYIDRTCCA0EwggIpAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjc4MDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUA/S8xOZxCUQFBNkrN8Wiij1x5y8Og
# ZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDtthgKMCIYDzIwMjYwNTE4MjI1ODE4
# WhgPMjAyNjA1MTkyMjU4MThaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO22GAoC
# AQAwBwIBAAICGPswBwIBAAICEqwwCgIFAO23aYoCAQAwNgYKKwYBBAGEWQoEAjEo
# MCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG
# 9w0BAQsFAAOCAQEAuT3GseCi6UxhoLJDyq5+oE3a+bIcmAp/eriMAUJRFPZmBddf
# XSQBqlnFjvBrLzlQxZklz7f3LrG8m4P2AKOq2g+1UbrhlOEFj3Xquuy/agQXdAFe
# PzHaCxdDIL1ChKhnVc1ex0hQRWPETIU2PCqnfwOJx2Hgl9Kxlu+7ta1VT5ywElFD
# LMk9eCAaA4Xz/yIPvUvxknHzoetLA7ibMaD8svCg8eTidnqSj9z2aby+OGYwegrI
# V6CFtA8c/VID/lRaZzR57pUsvzyBOBWN3EweqyUSqICHHamRI8ajG9o9kgLc3RF1
# JoyFMolA2oBXmxFbIhouBjX440EFlpnn9gFX4jANBgkqhkiG9w0BAQEFAASCAgAC
# J76JxFZIjB2oKRBI7CrAPXNq+oS3BBS8LTZaH57xgeI/++OARBrNvoCPRwTjJtSQ
# 2SIDD0NDS2kqSDQbbBFmsUnhgA5b5aHL4t6Rebv6Zx7WNjwZ5Ze3RJqQgT1DWut9
# oUYvf6UEw78N33PXo0lfRYBQrWqwn2sMR5w42538A9LTi/j1AmL5mFQ1NCCYWHS/
# MgDToIPigMl7WvIworf6HzP+vWSP7eDrUyhDH8KW8ywr5vNpJ+lRlDyCbgJz7JoC
# TbyNtVJ9RMf24m8eAoZw7casJ2kZp/b6sGh5MMYhZpcaGrYbPlWT1c53Ws23kK8U
# 2PbJeIv3s2KDAstBSKtHkyix1cCb3AsdGvHseahfzKhxbGdXi6/pklmbp9vZnvvM
# vf4PgDYSI5vUIZJ2HO6iIzE392VKi5tZaf6g4cVkWIYPeXv5qMAy3OGjenWrlwo/
# p3a6qCR/NVXhtzOtIfUTVLinYobRsI3Y+D6giuhrwZ3GJaV0Paar49oZDOXH7RQl
# J+iipi2XPCQ7VGefBP5NJcyrzJ9/q1Q5744dk4G2/NqjsjKKllgEWjPozeDxGtAM
# b+XHVrnxRIbmVcxDwKLBwJBTiqK/mWCATrIjjPpA5CfRtk+C6ugwHRIJDynbaT5B
# MfyJZnz5pjp2bz8i74he2iO8gdc5ZTBmMcl/uSFeaQ==
# SIG # End signature block
