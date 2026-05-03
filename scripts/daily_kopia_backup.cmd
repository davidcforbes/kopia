@echo off
REM ============================================================
REM  Daily Kopia Backup — runs via Task Scheduler as user david
REM  Schedule: Daily at 03:00
REM  Requires: /RL HIGHEST for VSS shadow copy support
REM  v2 2026-04-15 — preflight checks, timeout guard, exit-code
REM                   logging at every step
REM ============================================================
setlocal enabledelayedexpansion

set KOPIA_BIN=C:\Users\david\go\bin\kopia.exe
set KOPIA_CFG=--config-file=C:\Users\david\AppData\Roaming\kopia\repository.config
set KOPIA_CFG_PATH=C:\Users\david\AppData\Roaming\kopia\repository.config
set KOPIA_REPO=D:\KopiaRepo
set LOG=C:\dev\kopia\logs\daily_kopia.log
set SCRIPT_DIR=C:\dev\kopia\scripts
set OVERALL_RC=0

REM Pin PowerShell to Windows PowerShell 5.1 - the toast helpers depend on
REM the [Type, Asm, ContentType=WindowsRuntime] WinRT loader which PS 7+
REM dropped. Bare powershell.exe resolves to PS 7 when it's installed
REM ahead of System32 in PATH, silently breaking toasts.
set PS_BIN=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe

REM Rotate log if over 1MB
for %%F in ("%LOG%") do if %%~zF GTR 1048576 (
    if exist "%LOG%.old" del "%LOG%.old"
    move "%LOG%" "%LOG%.old" >nul 2>&1
)

echo ======================================== >> "%LOG%"
echo %DATE% %TIME% — Daily Kopia backup start >> "%LOG%"
echo %DATE% %TIME% — Script: %~f0  v2 >> "%LOG%"
echo %DATE% %TIME% — Running as: %USERNAME% >> "%LOG%"

REM ---- Preflight: kopia binary ----
echo %DATE% %TIME% — [preflight] checking kopia binary >> "%LOG%"
if not exist "%KOPIA_BIN%" (
    echo %DATE% %TIME% — FATAL: kopia not found at %KOPIA_BIN% >> "%LOG%"
    echo ======================================== >> "%LOG%"
    exit /b 1
)
for /f "delims=" %%V in ('"%KOPIA_BIN%" --version 2^>^&1') do echo %DATE% %TIME% — [preflight] %%V >> "%LOG%"

REM ---- Preflight: certificate health for all signed helpers + kopia.exe ----
REM Bootstrap: verify the dedicated cert-check script exists and is signed
REM (Status=Valid). Then delegate to it for the rich publisher/timestamp
REM checks across kopia.exe + every signed .ps1 helper.
echo %DATE% %TIME% — [preflight] verifying helper certificates >> "%LOG%"
set VERIFY_PS=%SCRIPT_DIR%\verify_helpers_preflight.ps1
if not exist "%VERIFY_PS%" (
    echo %DATE% %TIME% — FATAL: missing %VERIFY_PS% >> "%LOG%"
    echo ======================================== >> "%LOG%"
    exit /b 1
)
"%PS_BIN%" -NoProfile -Command "$s=Get-AuthenticodeSignature '%VERIFY_PS%'; if($s.Status -ne 'Valid'){Write-Host \"verify_helpers_preflight.ps1(Status=$($s.Status))\"; exit 1}; exit 0" > "%TEMP%\kopia_sig_check.txt" 2>&1
set SIG_RC=%errorlevel%
if %SIG_RC% NEQ 0 (
    for /f "delims=" %%L in ('type "%TEMP%\kopia_sig_check.txt"') do echo %DATE% %TIME% — FATAL: bootstrap sig: %%L >> "%LOG%"
    del "%TEMP%\kopia_sig_check.txt" 2>nul
    echo ======================================== >> "%LOG%"
    exit /b 1
)
del "%TEMP%\kopia_sig_check.txt" 2>nul

"%PS_BIN%" -NoProfile -ExecutionPolicy Bypass -File "%VERIFY_PS%" -ScriptsDir "%SCRIPT_DIR%" -KopiaBin "%KOPIA_BIN%" >> "%LOG%" 2>&1
if errorlevel 1 (
    echo %DATE% %TIME% — FATAL: certificate preflight failed >> "%LOG%"
    echo ======================================== >> "%LOG%"
    exit /b 1
)
echo %DATE% %TIME% — [preflight] helpers signed, fresh, and from expected publisher >> "%LOG%"

REM ---- Preflight: check if wbadmin is still running ----
echo %DATE% %TIME% — [preflight] checking for active wbadmin >> "%LOG%"
tasklist /fi "imagename eq wbengine.exe" /nh 2>nul | findstr /i "wbengine" >nul
if not errorlevel 1 (
    echo %DATE% %TIME% — WARNING: wbengine.exe still running, waiting up to 60 min >> "%LOG%"
    set /a WC=0
    :wb_wait
    timeout /t 60 /nobreak >nul
    set /a WC+=1
    tasklist /fi "imagename eq wbengine.exe" /nh 2>nul | findstr /i "wbengine" >nul
    if not errorlevel 1 (
        if !WC! LSS 60 (
            echo %DATE% %TIME% — [preflight] wbadmin still running ^(!WC! min^) >> "%LOG%"
            goto wb_wait
        ) else (
            echo %DATE% %TIME% — WARNING: wbadmin still running after 60 min, proceeding >> "%LOG%"
        )
    ) else (
        echo %DATE% %TIME% — [preflight] wbadmin finished after !WC! min >> "%LOG%"
    )
) else (
    echo %DATE% %TIME% — [preflight] no active wbadmin >> "%LOG%"
)

REM ---- Preflight: wait for any other CLI kopia.exe (e.g. WeeklyBackupVerify) ----
REM Filters by ExecutablePath so the always-on kopia-ui server does not match.
echo %DATE% %TIME% — [preflight] checking for active kopia CLI process >> "%LOG%"
"%PS_BIN%" -NoProfile -Command "exit (Get-CimInstance Win32_Process -Filter \"Name='kopia.exe'\" | Where-Object { $_.ExecutablePath -eq '%KOPIA_BIN%' } | Measure-Object).Count"
if !errorlevel! GTR 0 (
    echo %DATE% %TIME% — WARNING: another kopia CLI is running, waiting up to 60 min >> "%LOG%"
    set /a KC=0
    :kopia_wait
    timeout /t 60 /nobreak >nul
    set /a KC+=1
    "%PS_BIN%" -NoProfile -Command "exit (Get-CimInstance Win32_Process -Filter \"Name='kopia.exe'\" | Where-Object { $_.ExecutablePath -eq '%KOPIA_BIN%' } | Measure-Object).Count"
    if !errorlevel! GTR 0 (
        if !KC! LSS 60 (
            echo %DATE% %TIME% — [preflight] kopia CLI still running ^(!KC! min^) >> "%LOG%"
            goto kopia_wait
        ) else (
            echo %DATE% %TIME% — WARNING: kopia CLI still running after 60 min, proceeding >> "%LOG%"
        )
    ) else (
        echo %DATE% %TIME% — [preflight] kopia CLI finished after !KC! min >> "%LOG%"
    )
) else (
    echo %DATE% %TIME% — [preflight] no other kopia CLI active >> "%LOG%"
)

REM ---- Preflight: repo lock files ----
echo %DATE% %TIME% — [preflight] checking repo dir for locks >> "%LOG%"
dir /b "%KOPIA_REPO%\*.lock" "%KOPIA_REPO%\kopia.repository.l*" 2>nul >> "%LOG%"
if errorlevel 1 (
    echo %DATE% %TIME% — [preflight] no lock files >> "%LOG%"
) else (
    echo %DATE% %TIME% — [preflight] lock file^(s^) present ^(may be normal^) >> "%LOG%"
)

REM ---- Verify repo connection (120s timeout via PowerShell) ----
echo %DATE% %TIME% — [repo-check] verifying repo connection ^(120s timeout^) >> "%LOG%"
"%PS_BIN%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\repo_status_check.ps1" -KopiaBin "%KOPIA_BIN%" -ConfigFile "%KOPIA_CFG_PATH%" -LogFile "%LOG%" -TimeoutSec 120
set REPO_RC=%errorlevel%
echo %DATE% %TIME% — [repo-check] exit code: %REPO_RC% >> "%LOG%"
if %REPO_RC% EQU 99 (
    echo %DATE% %TIME% — FATAL: repo status hung for 120s — possible stale lock >> "%LOG%"
    echo %DATE% %TIME% — Try: kopia repository disconnect / reconnect >> "%LOG%"
    echo ======================================== >> "%LOG%"
    exit /b 1
)
if %REPO_RC% NEQ 0 (
    echo %DATE% %TIME% — FATAL: repo status failed ^(rc=%REPO_RC%^). Run setup_all.cmd >> "%LOG%"
    echo ======================================== >> "%LOG%"
    exit /b 1
)
echo %DATE% %TIME% — [repo-check] repo connected OK >> "%LOG%"

REM ---- Snapshot C:\dev ----
echo %DATE% %TIME% — [snapshot] C:\dev starting >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% snapshot create C:\dev --parallel=16 >> "%LOG%" 2>&1
set SNAP1_RC=!errorlevel!
echo %DATE% %TIME% — [snapshot] C:\dev finished ^(rc=!SNAP1_RC!^) >> "%LOG%"
if !SNAP1_RC! NEQ 0 set OVERALL_RC=1

REM ---- Snapshot C:\Users\david ----
echo %DATE% %TIME% — [snapshot] C:\Users\david starting >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% snapshot create C:\Users\david --parallel=16 >> "%LOG%" 2>&1
set SNAP2_RC=!errorlevel!
echo %DATE% %TIME% — [snapshot] C:\Users\david finished ^(rc=!SNAP2_RC!^) >> "%LOG%"
if !SNAP2_RC! NEQ 0 set OVERALL_RC=1

REM ---- Maintenance ----
echo %DATE% %TIME% — [maintenance] starting >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% maintenance run >> "%LOG%" 2>&1
set MAINT_RC=!errorlevel!
echo %DATE% %TIME% — [maintenance] finished ^(rc=!MAINT_RC!^) >> "%LOG%"

REM ---- Index newly-created snapshots so backup-monitor's Find & Restore
REM      page sees today's (latest-1) snapshot. Failures here are NON-fatal:
REM      a stale search index is not a backup failure and must not flip
REM      OVERALL_RC. wbengine.exe was already drained in preflight, so the
REM      wbadmin VHDX target on D: is safe to read.
set INDEXER=C:\dev\backup-monitor\target\release\backup-indexer.exe
set INDEX_DIR=D:\BackupMonitorIndex
if exist "!INDEXER!" (
    echo %DATE% %TIME% — [indexer] kopia incremental starting >> "%LOG%"
    "!INDEXER!" --kopia --index-dir=!INDEX_DIR! >> "%LOG%" 2>&1
    set IDX_K_RC=!errorlevel!
    echo %DATE% %TIME% — [indexer] kopia finished ^(rc=!IDX_K_RC!^) >> "%LOG%"
    if !IDX_K_RC! NEQ 0 echo %DATE% %TIME% — WARNING: kopia indexer rc=!IDX_K_RC! ^(search may be stale^) >> "%LOG%"

    echo %DATE% %TIME% — [indexer] wbadmin incremental starting >> "%LOG%"
    "!INDEXER!" --wbadmin --index-dir=!INDEX_DIR! >> "%LOG%" 2>&1
    set IDX_W_RC=!errorlevel!
    echo %DATE% %TIME% — [indexer] wbadmin finished ^(rc=!IDX_W_RC!^) >> "%LOG%"
    if !IDX_W_RC! NEQ 0 echo %DATE% %TIME% — WARNING: wbadmin indexer rc=!IDX_W_RC! ^(search may be stale^) >> "%LOG%"

    echo %DATE% %TIME% — [indexer] prune starting >> "%LOG%"
    "!INDEXER!" --prune --index-dir=!INDEX_DIR! >> "%LOG%" 2>&1
    echo %DATE% %TIME% — [indexer] prune finished ^(rc=!errorlevel!^) >> "%LOG%"
) else (
    echo %DATE% %TIME% — WARNING: indexer not found at !INDEXER! ^(search will be stale^) >> "%LOG%"
)

REM ---- Snapshot list and stats ----
echo %DATE% %TIME% — Snapshot list: >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% snapshot list --all >> "%LOG%" 2>&1

echo %DATE% %TIME% — Repo stats: >> "%LOG%"
"%KOPIA_BIN%" %KOPIA_CFG% content stats >> "%LOG%" 2>&1

REM ---- Error check ----
set ALERT_FILE=C:\dev\kopia\logs\BACKUP_ERRORS.flag
for /f %%N in ('"%PS_BIN%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\check_backup_errors.ps1" "%LOG%"') do set ERR_COUNT=%%N
if "!ERR_COUNT!"=="" set ERR_COUNT=0
if !ERR_COUNT! GTR 0 (
    echo %DATE% %TIME% — WARNING: !ERR_COUNT! unexpected errors detected >> "%LOG%"
    echo %DATE% %TIME% — !ERR_COUNT! unexpected errors. Run kopia_errors.cmd for details. > "!ALERT_FILE!"
    set OVERALL_RC=1
) else (
    if exist "!ALERT_FILE!" del "!ALERT_FILE!"
    echo %DATE% %TIME% — No unexpected errors detected >> "%LOG%"
)

REM ---- Toast notification ----
REM Post a Windows toast summarizing this run, reading the structured
REM "snapshot summary ..." lines kopia emits per source (added on master
REM in commit 1f5c6604). Aggregates errors/files/bytes across sources
REM into one PASS/FAIL/UNKNOWN toast. Independent of the existing error-
REM count flag-file mechanism above.
echo %DATE% %TIME% — [toast] posting summary >> "%LOG%"
"%PS_BIN%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\post_summary_toast.ps1" -LogFile "%LOG%" >> "%LOG%" 2>&1

REM ---- Summary ----
echo %DATE% %TIME% — Exit codes: repo=%REPO_RC% snap1=!SNAP1_RC! snap2=!SNAP2_RC! maint=!MAINT_RC! errors=!ERR_COUNT! >> "%LOG%"
echo %DATE% %TIME% — Daily Kopia backup complete ^(overall rc=!OVERALL_RC!^) >> "%LOG%"
echo ======================================== >> "%LOG%"

endlocal
exit /b %OVERALL_RC%
