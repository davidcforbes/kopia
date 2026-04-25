@echo off
REM ============================================================
REM  Forbes Asset Management — Backup Infrastructure Setup
REM  Run this ONCE from an elevated (Admin) command prompt.
REM  Idempotent: safe to re-run; skips steps already completed.
REM ============================================================
setlocal enabledelayedexpansion

set KOPIA_BIN=C:\Users\david\go\bin\kopia.exe
set KOPIA_REPO=D:\KopiaRepo
set KOPIA_CONFIG=%USERPROFILE%\.config\kopia\repository.config
set LOG_DIR=C:\dev\kopia\logs
set SCRIPT_DIR=C:\dev\kopia\scripts

echo.
echo === [1/6] Verify prerequisites ===

if not exist "%KOPIA_BIN%" (
    echo ERROR: Kopia binary not found at %KOPIA_BIN%
    echo Build it first:  cd C:\dev\kopia ^&^& go build -o kopia.exe .
    exit /b 1
)
echo   kopia.exe ............. OK

where wbadmin >nul 2>&1
if errorlevel 1 (
    echo ERROR: wbadmin not found. Windows Backup feature may need enabling.
    exit /b 1
)
echo   wbadmin ............... OK

if not exist D:\ (
    echo ERROR: Backup drive D: not accessible.
    exit /b 1
)
echo   D: drive .............. OK

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
echo   logs dir .............. OK

echo.
echo === [2/6] Initialize Kopia repository on D: ===

if not exist "%KOPIA_REPO%" mkdir "%KOPIA_REPO%"

REM Check if repo already exists
"%KOPIA_BIN%" repository status >nul 2>&1
if not errorlevel 1 (
    echo   Repository already connected. Skipping create.
    goto :REPO_DONE
)

echo   Creating new repository at %KOPIA_REPO% ...
echo   Enabling: AES256-GCM encryption, Reed-Solomon ECC, zstd compression, actions
"%KOPIA_BIN%" repository create filesystem --path "%KOPIA_REPO%" --ecc-overhead-percent=1 --enable-actions
if errorlevel 1 (
    echo ERROR: Repository creation failed.
    exit /b 1
)

:REPO_DONE
echo   Kopia repo ............ OK

REM Set maintenance ownership to this host
"%KOPIA_BIN%" maintenance set --owner=me
echo   Maintenance owner ..... OK

echo.
echo === [3/6] Set global Kopia policies ===

"%KOPIA_BIN%" policy set --global --keep-latest 30 --keep-daily 30 --keep-monthly 12 --keep-annual 3 --compression zstd --enable-volume-shadow-copy=when-available --max-parallel-file-reads=16
echo   Global retention ...... OK
echo   VSS shadow copy ....... when-available
echo   Parallel file reads ... 16

echo.
echo === [4/6] Verify .kopiaignore files ===

REM Kopia reads .kopiaignore files by default (like .gitignore).
REM These are already placed at C:\dev\.kopiaignore and C:\Users\david\.kopiaignore
REM for build artifacts, caches, toolchains, and temp files.

if exist C:\dev\.kopiaignore (
    echo   C:\dev\.kopiaignore ... OK
) else (
    echo   WARNING: C:\dev\.kopiaignore not found — create it manually
)
if exist C:\Users\david\.kopiaignore (
    echo   C:\Users\david\.kopiaignore OK
) else (
    echo   WARNING: C:\Users\david\.kopiaignore not found — create it manually
)

echo.
echo === [5/7] Configure wbadmin daily incremental system image ===

REM Disable any existing wbadmin schedule
wbadmin disable backup -quiet 2>nul
REM Enable daily incremental backup at 02:00 (excludes C:\dev and C:\Users\david)
wbadmin enable backup -addtarget:D: -include:C: -allCritical -exclude:C:\dev,C:\Users\david -schedule:02:00 -quiet
echo   wbadmin daily at 02:00  configured (Windows-managed, incremental)

echo.
echo === [6/7] Register Kopia scheduled tasks ===

REM Remove existing tasks if present (idempotent)
SCHTASKS /Delete /TN "Backup\MonthlySystemImage" /F >nul 2>&1
SCHTASKS /Delete /TN "Backup\WeeklySystemImage" /F >nul 2>&1
SCHTASKS /Delete /TN "Backup\DailyKopiaSnapshot" /F >nul 2>&1
SCHTASKS /Delete /TN "Backup\WeeklyBackupVerify" /F >nul 2>&1

REM Daily Kopia snapshot — every day at 03:00 (runs as current user, not SYSTEM)
SCHTASKS /Create /SC DAILY /TN "Backup\DailyKopiaSnapshot" /RL HIGHEST /ST 03:00 /TR "\"%SCRIPT_DIR%\daily_kopia_backup.cmd\"" /F
echo   DailyKopiaSnapshot .... registered

REM Weekly verification — every Saturday at 04:00 (runs as current user, not SYSTEM)
SCHTASKS /Create /SC WEEKLY /D SAT /TN "Backup\WeeklyBackupVerify" /RL HIGHEST /ST 04:00 /TR "\"%SCRIPT_DIR%\verify_backups.cmd\"" /F
echo   WeeklyBackupVerify .... registered

echo.
echo === [7/7] Take initial Kopia snapshots ===

echo   Snapshotting C:\dev ...
"%KOPIA_BIN%" snapshot create C:\dev --parallel=16
echo   Snapshotting C:\Users\david ...
"%KOPIA_BIN%" snapshot create C:\Users\david --parallel=16

echo.
echo ============================================================
echo  Setup complete. Scheduled backups:
echo.
echo    wbadmin system image        Daily  02:00  (Windows-managed incremental)
echo    Backup\DailyKopiaSnapshot   Daily  03:00  (Task Scheduler)
echo    Backup\WeeklyBackupVerify   Sat    04:00  (Task Scheduler)
echo.
echo  To run any task immediately:
echo    SCHTASKS /Run /TN "Backup\DailyKopiaSnapshot"
echo.
echo  Logs: %LOG_DIR%
echo ============================================================

endlocal
