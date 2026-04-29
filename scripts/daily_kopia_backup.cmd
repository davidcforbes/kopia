@echo off
REM ============================================================
REM  Daily Kopia Backup — runs via Task Scheduler as SYSTEM
REM  Schedule: Daily at 03:00
REM  Requires: /RL HIGHEST for VSS shadow copy support
REM ============================================================
setlocal

set KOPIA_BIN=C:\Users\david\go\bin\kopia.exe
set KOPIA_CFG=--config-file=C:\Users\david\AppData\Roaming\kopia\repository.config
set KOPIA_REPO=D:\KopiaRepo
set LOG=C:\dev\kopia\logs\daily_kopia.log

REM Decrypt repo password from DPAPI-protected file (LocalMachine scope) into env.
REM Setting KOPIA_PASSWORD explicitly avoids the persistent-password lookup,
REM which fails intermittently under Task Scheduler S4U logon (kopia#2673).
for /f "usebackq delims=" %%P in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\dev\kopia\scripts\get_kopia_password.ps1`) do set KOPIA_PASSWORD=%%P
if "%KOPIA_PASSWORD%"=="" (
    echo %DATE% %TIME% — FATAL: failed to decrypt KOPIA_PASSWORD from .kopia-pw.dat >> "%LOG%"
    exit /b 2
)

REM Rotate log if over 1MB
for %%F in ("%LOG%") do if %%~zF GTR 1048576 (
    if exist "%LOG%.old" del "%LOG%.old"
    move "%LOG%" "%LOG%.old" >nul 2>&1
)

echo ======================================== >> "%LOG%"
echo %DATE% %TIME% — Daily Kopia backup start >> "%LOG%"

REM Verify repo connection (SYSTEM user needs explicit config path)
"%KOPIA_BIN%" %KOPIA_CFG% repository status >nul 2>&1
if errorlevel 1 (
    echo %DATE% %TIME% — ERROR: repo not connected. Run setup_all.cmd first. >> "%LOG%"
    exit /b 1
)

REM Snapshot C:\dev
echo %DATE% %TIME% — Snapshotting C:\dev >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% snapshot create C:\dev --parallel=16 >> "%LOG%" 2>&1

REM Snapshot C:\Users\david
echo %DATE% %TIME% — Snapshotting C:\Users\david >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% snapshot create C:\Users\david --parallel=16 >> "%LOG%" 2>&1

REM Run quick maintenance
echo %DATE% %TIME% — Running maintenance >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% maintenance run >> "%LOG%" 2>&1

REM Log completion and repo size
echo %DATE% %TIME% — Snapshot list: >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% snapshot list --all >> "%LOG%" 2>&1

echo %DATE% %TIME% — Repo stats: >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% content stats >> "%LOG%" 2>&1

REM Build Backup Monitor search indexes (kopia latest-1 per source + wbadmin
REM newest backup set + prune orphans). Indexer inherits KOPIA_PASSWORD from
REM this script's env and VHDX mount needs this task's /RL HIGHEST elevation.
REM Failure here does not block the main backup — indexer errors are logged
REM but exit code is not propagated.
set INDEXER=C:\dev\backup-monitor\target\release\backup-indexer.exe
if exist "%INDEXER%" (
    echo %DATE% %TIME% — Building search indexes >> "%LOG%"
    "%INDEXER%" >> "%LOG%" 2>&1
) else (
    echo %DATE% %TIME% — WARNING: indexer not found at %INDEXER%, skipping >> "%LOG%"
)

REM Post a Windows toast immediately, summarizing this run from the
REM structured "snapshot summary ..." lines kopia emits per source.
REM The script also writes/clears BACKUP_ERRORS.flag based on errors=N.
echo %DATE% %TIME% — Posting backup summary toast >> "%LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\dev\kopia\scripts\post_summary_toast.ps1 -LogFile "%LOG%" >> "%LOG%" 2>&1

echo %DATE% %TIME% — Daily Kopia backup complete >> "%LOG%"
echo ======================================== >> "%LOG%"

endlocal
