# Register the daily wbadmin health-check task. Runs as the logged-in user
# at high integrity (RunLevel Highest) so wbadmin and the Microsoft-Windows-
# Backup event log are accessible. Toasts post into the user's session.
# powershell.exe (PS 5.1) is required — the script uses WinRT APIs that
# PowerShell 7 (pwsh.exe) does not expose.
$a = New-ScheduledTaskAction `
    -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\dev\kopia\scripts\check_wbadmin_health.ps1'
$t = New-ScheduledTaskTrigger -Daily -At '8:30AM'
$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
$p = New-ScheduledTaskPrincipal -UserId 'david' -LogonType Interactive -RunLevel Highest
Unregister-ScheduledTask -TaskPath '\Backup\' -TaskName 'WbadminHealthCheck' `
    -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskPath '\Backup\' -TaskName 'WbadminHealthCheck' `
    -Action $a -Trigger $t -Settings $s -Principal $p `
    -Description 'Daily wbadmin (Windows Server Backup) freshness check; posts Windows toast PASS/STALE/FAIL.'
