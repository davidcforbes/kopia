$a = New-ScheduledTaskAction -Execute "C:\dev\kopia\scripts\daily_kopia_backup.cmd"
$t = New-ScheduledTaskTrigger -Daily -At "3:00AM"
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
$p = New-ScheduledTaskPrincipal -UserId "david" -RunLevel Highest -LogonType S4U
Unregister-ScheduledTask -TaskPath "\Backup\" -TaskName "DailyKopiaSnapshot" -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskPath "\Backup\" -TaskName "DailyKopiaSnapshot" -Action $a -Trigger $t -Settings $s -Principal $p -Description "Daily Kopia backup with VSS"
