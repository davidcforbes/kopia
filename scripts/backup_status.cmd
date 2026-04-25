@echo off
REM ============================================================
REM  Backup Status — quick health check (run anytime)
REM ============================================================
setlocal

set KOPIA_BIN=C:\Users\david\go\bin\kopia.exe
set KOPIA_REPO=D:\KopiaRepo

echo.
echo === Backup Health ===
set ALERT_FILE=C:\dev\kopia\logs\BACKUP_ERRORS.flag
if exist "%ALERT_FILE%" (
    echo   *** WARNING ***
    type "%ALERT_FILE%"
    echo   Run kopia_errors.cmd for details.
) else (
    echo   All clear — no backup errors flagged.
)

echo.
echo === Kopia Repository ===
"%KOPIA_BIN%" repository status 2>&1
echo.
echo === Latest Snapshots ===
"%KOPIA_BIN%" snapshot list --all 2>&1
echo.
echo === Repository Content Stats ===
"%KOPIA_BIN%" content stats 2>&1
echo.
echo === Maintenance Info ===
"%KOPIA_BIN%" maintenance info 2>&1
echo.
echo === System Image Versions (D:) ===
wbadmin get versions -backupTarget:D: 2>&1
echo.
echo === Disk Space ===
wmic logicaldisk where "DeviceID='C:' or DeviceID='D:' or DeviceID='F:'" get DeviceID,FreeSpace,Size,VolumeName /format:list 2>&1
echo.
echo === Scheduled Tasks ===
echo -- wbadmin (Windows-managed daily incremental):
wbadmin get status 2>&1 | findstr /i "backup status"
echo.
echo -- Kopia tasks:
SCHTASKS /Query /TN "Backup\DailyKopiaSnapshot" /FO LIST /V 2>nul | findstr /i "Task Name Status Last Run Next Run"
SCHTASKS /Query /TN "Backup\WeeklyBackupVerify" /FO LIST /V 2>nul | findstr /i "Task Name Status Last Run Next Run"

echo.
echo === Recent Log Entries ===
echo -- daily_kopia.log (last 5 lines):
if exist C:\dev\kopia\logs\daily_kopia.log (
    powershell -Command "Get-Content C:\dev\kopia\logs\daily_kopia.log -Tail 5"
) else (
    echo   [no log yet]
)
echo.
echo -- system_image.log (last 5 lines):
if exist C:\dev\kopia\logs\system_image.log (
    powershell -Command "Get-Content C:\dev\kopia\logs\system_image.log -Tail 5"
) else (
    echo   [no log yet]
)
echo.
echo -- verify.log (last 5 lines):
if exist C:\dev\kopia\logs\verify.log (
    powershell -Command "Get-Content C:\dev\kopia\logs\verify.log -Tail 5"
) else (
    echo   [no log yet]
)

endlocal
