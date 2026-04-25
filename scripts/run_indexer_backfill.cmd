@echo off
REM ============================================================
REM  One-shot: backfill all historical kopia snapshots + wbadmin
REM  backup sets into D:\BackupMonitorIndex.
REM  Run this once after deploying backup-indexer. Nightly
REM  daily_kopia_backup.cmd handles incremental updates after that.
REM  Must run ELEVATED so the wbadmin VHDX mount succeeds.
REM ============================================================
setlocal

set KOPIA_PASSWORD=[REDACTED-LEAKED-PW-2026-04]
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
