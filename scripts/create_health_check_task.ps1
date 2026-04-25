# Register the daily Kopia backup health-check task. Runs as the logged-in
# user (not SYSTEM) so the toast notification appears in the user's Action
# Center. powershell.exe (PS 5.1) is required — the script uses WinRT APIs
# that PowerShell 7 (pwsh.exe) does not expose.
$a = New-ScheduledTaskAction `
    -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\dev\kopia\scripts\check_backup_health.ps1'
$t = New-ScheduledTaskTrigger -Daily -At '8:00AM'
$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
$p = New-ScheduledTaskPrincipal -UserId 'david' -LogonType Interactive -RunLevel Limited
Unregister-ScheduledTask -TaskPath '\Backup\' -TaskName 'KopiaBackupHealthCheck' `
    -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskPath '\Backup\' -TaskName 'KopiaBackupHealthCheck' `
    -Action $a -Trigger $t -Settings $s -Principal $p `
    -Description 'Daily Kopia backup health check; posts Windows toast PASS/FAIL.'
