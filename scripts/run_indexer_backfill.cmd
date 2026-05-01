@echo off
REM ============================================================
REM  One-shot: backfill all historical kopia snapshots + wbadmin
REM  backup sets into D:\BackupMonitorIndex.
REM  Run this once after deploying backup-indexer. Nightly
REM  daily_kopia_backup.cmd handles incremental updates after that.
REM  Must run ELEVATED so the wbadmin VHDX mount succeeds.
REM ============================================================
setlocal

REM Decrypt repo password from DPAPI-protected file (LocalMachine scope) into env.
REM Mirrors verify_backups.cmd:17 — never bake the literal into a tracked file.
for /f "usebackq delims=" %%P in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\dev\kopia\scripts\get_kopia_password.ps1`) do set KOPIA_PASSWORD=%%P
if "%KOPIA_PASSWORD%"=="" (
    echo FATAL: failed to decrypt KOPIA_PASSWORD from .kopia-pw.dat
    exit /b 2
)

set INDEXER=C:\dev\backup-monitor\target\release\backup-indexer.exe

if not exist "%INDEXER%" (
    echo ERROR: indexer not built at %INDEXER%
    exit /b 1
)

echo Backfilling kopia snapshots (this takes several minutes)...
"%INDEXER%" --kopia --backfill --index-dir=D:\BackupMonitorIndex

echo.
echo Backfilling wbadmin backup sets (requires admin)...
"%INDEXER%" --wbadmin --backfill --index-dir=D:\BackupMonitorIndex

echo.
echo Pruning orphaned indexes...
"%INDEXER%" --prune --index-dir=D:\BackupMonitorIndex

echo.
echo Done. Index files are in D:\BackupMonitorIndex

endlocal
