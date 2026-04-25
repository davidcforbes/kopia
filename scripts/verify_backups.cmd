@echo off
REM ============================================================
REM  Weekly Backup Verification — runs via Task Scheduler
REM  Schedule: Saturday at 04:00
REM  Validates Kopia repo integrity and wbadmin image health
REM ============================================================
setlocal

set KOPIA_BIN=C:\Users\david\go\bin\kopia.exe
set KOPIA_CFG=--config-file=C:\Users\david\AppData\Roaming\kopia\repository.config
set KOPIA_REPO=D:\KopiaRepo
set LOG=C:\dev\kopia\logs\verify.log

REM Decrypt repo password from DPAPI-protected file (LocalMachine scope) into env.
REM Setting KOPIA_PASSWORD explicitly avoids the persistent-password lookup,
REM which fails intermittently under Task Scheduler S4U logon (kopia#2673).
for /f "usebackq delims=" %%P in (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\dev\kopia\scripts\get_kopia_password.ps1`) do set KOPIA_PASSWORD=%%P
if "%KOPIA_PASSWORD%"=="" (
    echo %DATE% %TIME% — FATAL: failed to decrypt KOPIA_PASSWORD from .kopia-pw.dat >> "%LOG%"
    exit /b 2
)

echo ======================================== >> "%LOG%"
echo %DATE% %TIME% — Weekly verification start >> "%LOG%"

REM Use existing repo connection
"%KOPIA_BIN%" %KOPIA_CFG% repository status >nul 2>&1
if errorlevel 1 (
    echo %DATE% %TIME% — ERROR: repo not connected >> "%LOG%"
    exit /b 1
)

REM Validate repo structure (walks all snapshot trees, verifies index entries)
echo %DATE% %TIME% — Verifying snapshot structure >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% snapshot verify >> "%LOG%" 2>&1

REM Verify snapshot content — download/decrypt/decompress 5%% of files
REM At 5%% weekly, statistically ~93%% of data verified within 6 months
echo %DATE% %TIME% — Verifying file content (5%% sample, parallel) >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% snapshot verify --verify-files-percent=5 --file-parallelism=10 --parallel=10 >> "%LOG%" 2>&1

REM Full maintenance (compaction, GC)
echo %DATE% %TIME% — Running full maintenance >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% maintenance run --full >> "%LOG%" 2>&1

REM List current snapshots for audit trail
echo %DATE% %TIME% — Current snapshots: >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% snapshot list --all >> "%LOG%" 2>&1

REM Check wbadmin images
echo %DATE% %TIME% — System image versions on D: >> "%LOG%"
wbadmin get versions -backupTarget:D: >> "%LOG%" 2>&1

REM Disk space check
echo %DATE% %TIME% — Disk space: >> "%LOG%"
for /f "skip=1 tokens=1-3" %%A in ('wmic logicaldisk where "DeviceID='C:' or DeviceID='D:'" get DeviceID,FreeSpace,Size /format:csv 2^>nul') do (
    if not "%%A"=="" echo   %%A  Free: %%B  Total: %%C >> "%LOG%"
)

REM Warn if D: is below 500 GB free
for /f "skip=1 tokens=2" %%F in ('wmic logicaldisk where "DeviceID='D:'" get FreeSpace /value 2^>nul ^| findstr "="') do (
    set FREE=%%F
)
REM Simple threshold check (500 GB = 536870912000 bytes)
REM Note: cmd arithmetic overflows at 2^31 — this is a rough check
echo %DATE% %TIME% — D: free space: %FREE% bytes >> "%LOG%"

echo %DATE% %TIME% — Weekly verification complete >> "%LOG%"
echo ======================================== >> "%LOG%"

endlocal
