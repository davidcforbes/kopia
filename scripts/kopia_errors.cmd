@echo off
REM ============================================================
REM  Kopia Log Error Summary
REM  Usage: kopia_errors.cmd [logfile]
REM  Default: parses the latest snapshot-create log
REM ============================================================
setlocal

set LOG_DIR=C:\Users\david\AppData\Local\kopia\cli-logs

if not "%~1"=="" (
    set LOG_FILE=%~1
    goto :FOUND
)

REM Find the latest snapshot-create log
for /f "delims=" %%f in ('dir /b /o-d "%LOG_DIR%\kopia-*-snapshot-create.0.log" 2^>nul') do (
    set LOG_FILE=%LOG_DIR%\%%f
    goto :FOUND
)
echo No snapshot logs found in %LOG_DIR%
exit /b 1

:FOUND
echo.
echo === Kopia Error Summary ===
echo Log: %LOG_FILE%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\dev\kopia\scripts\kopia_errors.ps1 "%LOG_FILE%"

endlocal
