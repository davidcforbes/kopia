@echo off
REM ============================================================
REM  Apply Lean Sysmon Config
REM  Forbes Asset Management — 2026-04-15
REM
REM  Must be run from an ELEVATED prompt.
REM  Takes before/after pool memory snapshots and backs up the
REM  current config for rollback.
REM ============================================================
setlocal

set CFG=C:\dev\kopia\scripts\sysmon-lean.xml
set LOGDIR=C:\dev\kopia\logs
set TS=%DATE:/=-%_%TIME::=-%
set TS=%TS: =0%
set TS=%TS:~0,19%

echo ======================================== 
echo Sysmon Config Swap — %DATE% %TIME%
echo ======================================== 

REM Check admin
net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: Must run from elevated prompt
    pause
    exit /b 1
)

echo.
echo --- BEFORE ---
powershell -NoProfile -Command "$perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory; Write-Output ('  Pool Nonpaged: ' + [math]::Round($perf.PoolNonpagedBytes/1MB) + ' MB'); Write-Output ('  Pool Paged:    ' + [math]::Round($perf.PoolPagedBytes/1MB) + ' MB'); Write-Output ('  Handles:       ' + (Get-Process | Measure-Object HandleCount -Sum).Sum)"

echo.
echo Backing up current config to %LOGDIR%\sysmon-config-before-%TS%.txt
C:\Windows\Sysmon.exe -c > "%LOGDIR%\sysmon-config-before-%TS%.txt" 2>&1

echo.
echo Applying lean config from %CFG%
C:\Windows\Sysmon.exe -c "%CFG%"
if errorlevel 1 (
    echo ERROR: Sysmon -c returned %errorlevel%
    exit /b 1
)

echo.
echo Waiting 10 seconds for config to take effect...
timeout /t 10 /nobreak >nul

echo.
echo --- AFTER ---
powershell -NoProfile -Command "$perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory; Write-Output ('  Pool Nonpaged: ' + [math]::Round($perf.PoolNonpagedBytes/1MB) + ' MB'); Write-Output ('  Pool Paged:    ' + [math]::Round($perf.PoolPagedBytes/1MB) + ' MB'); Write-Output ('  Handles:       ' + (Get-Process | Measure-Object HandleCount -Sum).Sum)"

echo.
echo NOTE: Pool memory that has already been allocated will NOT
echo release immediately — existing kernel objects remain in pool
echo until their owner frees them. A reboot will clear accumulated
echo pool bloat. The new config prevents future growth.
echo.
echo Rollback command (if needed):
echo   C:\Windows\Sysmon.exe -c [path to old .xml]
echo.
endlocal
