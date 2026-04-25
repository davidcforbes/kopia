@echo off
setlocal enabledelayedexpansion
REM Safe rename: create canonical name FIRST, then delete V2.

echo === Clean up probe tasks ===
for /f "tokens=2 delims=:" %%A in ('schtasks /Query /FO LIST 2^>nul ^| findstr /i "TaskName.*_probe_"') do (
    set N=%%A
    set N=!N: =!
    echo Deleting probe task: !N!
    schtasks /Delete /TN "!N!" /F >nul 2>&1
)

echo.
echo === Create canonical \Backup\DailyKopiaSnapshot (alongside V2) ===
schtasks /Create /TN "\Backup\DailyKopiaSnapshot" ^
    /TR "C:\dev\kopia\scripts\daily_kopia_backup.cmd" ^
    /SC DAILY /ST 03:00 ^
    /RU "%USERDOMAIN%\%USERNAME%" ^
    /RL HIGHEST ^
    /F
set CREATE_RC=%errorlevel%
echo Create ERRORLEVEL=%CREATE_RC%

if %CREATE_RC% NEQ 0 (
    echo FATAL: could not create canonical task. V2 left intact.
    exit /b %CREATE_RC%
)

echo.
echo === Verify canonical task ===
schtasks /Query /TN "\Backup\DailyKopiaSnapshot" /V /FO LIST | findstr /i "TaskName Status Logon Next"

echo.
echo === Delete V2 ===
schtasks /Delete /TN "\Backup\DailyKopiaSnapshotV2" /F
echo V2 delete ERRORLEVEL=%errorlevel%

echo.
echo === Final state ===
schtasks /Query /TN "\Backup\" /FO LIST 2>nul | findstr /i "TaskName DailyKopia"
