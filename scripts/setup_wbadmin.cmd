@echo off
REM ============================================================
REM  Windows System Image — Daily Incremental Setup
REM  Run ONCE from an elevated prompt to configure wbadmin.
REM  Windows handles scheduling and retention automatically.
REM
REM  To check status:  wbadmin get status
REM  To list versions:  wbadmin get versions -backupTarget:D:
REM  To disable:  wbadmin disable backup
REM  To reset:  run reset_wbadmin.cmd
REM ============================================================
setlocal

echo.
echo === Windows System Image — Daily Incremental Setup ===
echo.
echo This configures wbadmin to run daily at 02:00.
echo First run creates a full image. All subsequent runs are
echo block-level incremental (only changed blocks stored).
echo Windows auto-prunes old restore points when space is low.
echo.
echo Target: D:
echo Source: C: (full volume, no exclusions)
echo Schedule: Daily at 02:00
echo.

wbadmin enable backup -addtarget:D: -include:C: -allCritical -schedule:02:00 -quiet

if errorlevel 1 (
    echo ERROR: wbadmin enable backup failed.
    exit /b 1
)

echo.
echo === Configuration complete ===
echo Windows will run the first full backup at 02:00 tonight.
echo Subsequent runs are incremental (only changed blocks).
echo.
echo Useful commands:
echo   wbadmin get status              Check current backup status
echo   wbadmin get versions -backupTarget:D:   List restore points
echo   wbadmin disable backup          Stop daily backups
echo   wbadmin start backup -backupTarget:D: -include:C: -allCritical   Run on-demand
echo.

endlocal
