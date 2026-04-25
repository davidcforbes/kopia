@echo off
REM ============================================================
REM  Reset Windows System Image Backup
REM  Run from elevated prompt to disable, wipe, and reconfigure.
REM ============================================================
setlocal

echo.
echo === Reset Windows System Image Backup ===
echo WARNING: This will delete ALL system image backups on D:
echo.
set /p CONFIRM="Type YES to proceed: "
if /i not "%CONFIRM%"=="YES" (
    echo Aborted.
    exit /b 1
)

echo Disabling scheduled backup...
wbadmin disable backup -quiet 2>nul

echo Deleting WindowsImageBackup on D:...
rd /s /q "D:\WindowsImageBackup" 2>nul

echo Re-enabling daily incremental backup...
wbadmin enable backup -addtarget:D: -include:C: -allCritical -schedule:02:00 -quiet

echo.
echo Reset complete. Fresh full backup will run at 02:00 tonight.

endlocal
