# check_backup_health.ps1 -- Parse the latest daily_kopia backup run and emit a
# Windows toast notification (PASS/FAIL) under the KopiaBackup.HealthCheck AUMID.
#
# Scheduled daily at 08:00 by \Backup\KopiaBackupHealthCheck.
[CmdletBinding()]
param(
    [string]$LogFile      = 'C:\dev\kopia\logs\daily_kopia.log',
    [string]$HeartbeatLog = 'C:\dev\kopia\logs\heartbeat.log',
    [string]$Aumid        = 'KopiaBackup.HealthCheck',
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
# MII9bQYJKoZIhvcNAQcCoII9XjCCPVoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAROtnXgEQlD9jH
# V9EeLwtYMLwwbVa31JPNARBf0tzK6KCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakzCC
# Go8CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENB
# IDAzAhMzAAEFiZv8E6F66OgKAAAAAQWJMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIFKJp1Dd/VtdPIxsEIF+1dEIgyWqriOD0bsiIRkhr9NQMA0GCSqGSIb3
# DQEBAQUABIIBgG1zbwzfCtmoL+pVc/NfHSBMWpAD0xKtwrTCuVObT3TRjV6n3fNx
# hUP9WuHttY+p3vuJHTrErYd/eTHb0CfwGUs9j3XAsuLHmgTS38SgN+hi17eBid4a
# kJiq/Us6mrU+4bMD9Bj5gq6jeXIaxQ973x2Has3u6IHdvHgPvbSYXX5f/dvyjsPX
# ib6tSmaxv5ORTk5MHtUjOjO8D0/clZPT5I4Tduw8CmNZ20OF8pi5Fn75ioIbhddX
# 61nElZrMjLg4MqA0viOUGkYXRwoj2ey+krp37+oPKZI05ba5fu04uQAMC2lRJCx4
# J8/4LfKLEAuqwWm3pjZd0erDF9ROR4iObAi/l3PFei16IBadODhayajfoJlmDDrd
# 7tuQWT9OE+N/vyv3BFIyk8HyBSQj2//aGbmwFvLPHTZhPTntxe3twQvZ1htgwzrp
# yXtiCEKCXs4CJNt3OarkbQjsZEcyL6ESzGkMsheGxcX1L1eljvufOr4pExTaWwEj
# HKcu7kB6SmGaLKGCGBMwghgPBgorBgEEAYI3AwMBMYIX/zCCF/sGCSqGSIb3DQEH
# AqCCF+wwghfoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFhBgsqhkiG9w0BCRABBKCC
# AVAEggFMMIIBSAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAoSSzU
# jnqQsGkHKH1aZp5Sbj4agzn4i4xGwIISEu34pQIGaeddl/1QGBIyMDI2MDUxMjIw
# MTI0MS43OVowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
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
# BgkqhkiG9w0BCQUxDxcNMjYwNTEyMjAxMjQxWjAvBgkqhkiG9w0BCQQxIgQg2HLL
# MrBpIEIkd4dYBIARUFDUXTHRiaMMRqrp2JJBH5wwgbkGCyqGSIb3DQEJEAIvMYGp
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
# Q0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2ti2gwIhgPMjAyNjA1MTIxMTIwMDha
# GA8yMDI2MDUxMzExMjAwOFowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7a2LaAIB
# ADAKAgEAAgIhNAIB/zAHAgEAAgISgzAKAgUA7a7c6AIBADA2BgorBgEEAYRZCgQC
# MSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqG
# SIb3DQEBCwUAA4IBAQBXnX06cZSMU3vQd8vnNLcuo/Nn8nEEqIpnm80xYVdqG0pl
# zuTVKv65FBENJmjoM2Caff07t2TcILc6oB1tgekxvuKVXihRtMZNuWPD/KfmfLG9
# vJjOh8K6gB6KGGc2ewoBt08Z4DzOmwlsoRmb/nhIFxTWM7V7opu0BL02Ss9P2Nk3
# Hzi86k2Em7n3ikjdqvIeQr7HY18odqf+LNbpZ7ssWHVYGj89lbFb/k1efnuoPa9Q
# poCnL6j6N4E/D8NuJKd6JiOppdPSPyAiGqI+UflNngUkECbJBsRiPD085lD3/F19
# k9t0sJUxNeyct37LQYGXBex4WSVfGQOjR6ixhzZyMA0GCSqGSIb3DQEBAQUABIIC
# AHfxeUYizZOUefW7iKdmfNUqPg29v7Akz05HRB7ds8JNICQNQd/hgYhHZ1G7cLEL
# RFCu6lUX834TGfQ0valvaQpw2oMMN+CmZCAeTuw9bfVqAYpkwgjjNzhJu4T/G+iQ
# 2jWwNcYnOBNEkVUzIryogqnDzRvkur1jTVB66w15GkNLoAFq8Cqabe4JAkT1FJp/
# GGnBqf6V03LubwI34YoX6nCJL6CEaInMQBXxlJ/ew2JtTJW7Ev0TPGqMs4M6lnD+
# HEVHs2W195hrbx6iAAiKpanejnuxxZOOJWNt7EdGWqTx8ITnGgD9/Ziq5B9hyhyp
# J3lucdARkBXasZEG69h/Y11tcSwGbxemuphR7QEAtpd5JfHHwJRd7miaoXngvYGu
# +uzc1Y3Ye6+V4dpNr4y63Ji+RTGO3YqB7hbl0ecADigvFMBX8oNkBrhS/9zOVBE2
# cvtOj18PNIg01n+AqLUi3ybpTHigW2iYv3cGr23o6QyykrMyOJtlQgdRzbV7Rxfi
# zYgpEUF4MkumxqS4khEtxA8V/FRnJyscjSYy4lOuXBb/5aWP1BmY11W6TnbhuoQ+
# 4h5ZSKWU77Jbqd2lNTDODp0iYncU6IXtKl8QtbYbb2apKPRC+nKLXmshJhaJW1cf
# +XHMM5tAE+K85MLT73A0pFbpY/34dfxvcmiO18D4V+QY
# SIG # End signature block
