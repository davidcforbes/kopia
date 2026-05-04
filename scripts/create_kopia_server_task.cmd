@echo off
REM Install (or re-install) the \Backup\KopiaServer scheduled task from XML.
REM
REM Must be run from an ELEVATED terminal (Administrator). The XML defines
REM S4U logon + boot trigger which schtasks /Create command-line args alone
REM can't express, so we import the XML directly.
REM
REM The task is created DISABLED. Enable it as part of the cutover sequence
REM (epic kopia-7s7 task 7s7.5).

SET XML=%~dp0KopiaServer.task.xml
SET TN=\Backup\KopiaServer

if not exist "%XML%" (
    echo ERROR: XML not found: %XML%
    exit /b 1
)

echo Installing task %TN% from %XML% ...
SCHTASKS /Create /TN %TN% /XML "%XML%" /F
if errorlevel 1 (
    echo ERROR: schtasks /Create failed. Are you running elevated?
    exit /b 1
)

REM Belt-and-braces: the XML sets Enabled=false but make sure.
SCHTASKS /Change /TN %TN% /DISABLE >nul 2>&1

echo.
echo Task installed (disabled). Verify with:
echo   schtasks /Query /TN %TN% /FO LIST
echo.
echo Cutover (enable + start) lives in epic kopia-7s7 task 7s7.5.
