# Clone V2 task config, register under canonical name, unregister V2.

$ErrorActionPreference = 'Stop'

$v2 = Get-ScheduledTask -TaskName 'DailyKopiaSnapshotV2' -TaskPath '\Backup\' -ErrorAction SilentlyContinue
if (-not $v2) {
    Write-Host 'FATAL: V2 task not found'
    exit 1
}

Write-Host ('V2 found: ' + $v2.TaskName + ' state=' + $v2.State)
Write-Host ('  Principal: UserId=' + $v2.Principal.UserId + ' LogonType=' + $v2.Principal.LogonType + ' RunLevel=' + $v2.Principal.RunLevel)

# Try to register canonical name alongside
try {
    Register-ScheduledTask `
        -TaskName 'DailyKopiaSnapshot' `
        -TaskPath '\Backup\' `
        -Action $v2.Actions `
        -Trigger $v2.Triggers `
        -Settings $v2.Settings `
        -Principal $v2.Principal `
        -Description $v2.Description `
        -Force `
        | Out-Null
    Write-Host 'OK: created \Backup\DailyKopiaSnapshot'
} catch {
    Write-Host ('FAIL create: ' + $_.Exception.Message)
    exit 2
}

# Verify
$new = Get-ScheduledTask -TaskName 'DailyKopiaSnapshot' -TaskPath '\Backup\' -ErrorAction SilentlyContinue
if (-not $new) {
    Write-Host 'FATAL: created task did not appear on Query'
    exit 3
}
Write-Host ('Verified: ' + $new.TaskName + ' state=' + $new.State + ' next=' + ($new | Get-ScheduledTaskInfo).NextRunTime)

# Unregister V2
try {
    Unregister-ScheduledTask -TaskName 'DailyKopiaSnapshotV2' -TaskPath '\Backup\' -Confirm:$false
    Write-Host 'OK: V2 deleted'
} catch {
    Write-Host ('FAIL delete V2: ' + $_.Exception.Message)
    exit 4
}

Write-Host ''
Write-Host '=== Final state of \Backup\ ==='
Get-ScheduledTask -TaskPath '\Backup\' | Select-Object TaskName, State | Format-Table -AutoSize | Out-String | Write-Host
