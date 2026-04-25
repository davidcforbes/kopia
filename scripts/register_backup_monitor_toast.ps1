# Register backup-monitor.exe as the toast click target.
#
# Two pieces:
#   1. HKCU AppUserModelID entry — gives toasts a proper "Backup Monitor"
#      source name (and icon) instead of "Windows PowerShell".
#   2. `kopiamonitor:` URL protocol handler pointing at backup-monitor.exe —
#      lets toast launch/action attributes use activationType="protocol".
#
# Both are HKCU-only; no admin rights required. Re-running is idempotent.

param(
    [string]$AppId       = 'KopiaBackup.HealthCheck',
    [string]$DisplayName = 'Backup Monitor',
    [string]$ExePath     = 'C:\dev\backup-monitor\target\release\backup-monitor.exe',
    [string]$Protocol    = 'kopiamonitor'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ExePath)) {
    throw "Executable not found: $ExePath"
}

# 1. AppUserModelID — Windows uses this to brand the toast notification.
$aumidPath = "HKCU:\Software\Classes\AppUserModelId\$AppId"
if (-not (Test-Path $aumidPath)) { New-Item -Path $aumidPath -Force | Out-Null }
Set-ItemProperty -Path $aumidPath -Name 'DisplayName' -Value $DisplayName -Type String
Set-ItemProperty -Path $aumidPath -Name 'IconUri'     -Value $ExePath     -Type String
# ShowInSettings = 1 lets users tune the notification under Settings → Notifications.
Set-ItemProperty -Path $aumidPath -Name 'ShowInSettings' -Value 1 -Type DWord

# 2. URL protocol handler — `kopiamonitor:` launches backup-monitor.exe.
$protoPath = "HKCU:\Software\Classes\$Protocol"
if (-not (Test-Path $protoPath)) { New-Item -Path $protoPath -Force | Out-Null }
Set-ItemProperty -Path $protoPath -Name '(default)'   -Value "URL:$DisplayName" -Type String
Set-ItemProperty -Path $protoPath -Name 'URL Protocol' -Value '' -Type String

$cmdPath = "$protoPath\shell\open\command"
if (-not (Test-Path $cmdPath)) { New-Item -Path $cmdPath -Force | Out-Null }
# %1 receives the full URL ("kopiamonitor:open" etc.) — backup-monitor.exe can ignore it.
Set-ItemProperty -Path $cmdPath -Name '(default)' -Value "`"$ExePath`" `"%1`"" -Type String

Write-Output "Registered AppId        : $AppId  -> $DisplayName"
Write-Output "Registered protocol     : $Protocol`:  -> $ExePath"
Write-Output "Test from any shell     : Start-Process '$Protocol`:open'"
