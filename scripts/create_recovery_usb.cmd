@echo off
REM ============================================================
REM  Create Windows 11 Recovery USB (E:)
REM  Run from elevated (Admin) command prompt.
REM
REM  Prerequisites:
REM    - Windows 11 ISO downloaded to C:\dev\kopia\iso\
REM      Download from: https://www.microsoft.com/software-download/windows11
REM      Select "Download Windows 11 Disk Image (ISO)"
REM    - USB drive inserted (E:, will be WIPED)
REM
REM  Result: UEFI-bootable USB with full Windows Recovery
REM  Environment (System Image Recovery, Command Prompt,
REM  Startup Repair, drivers, etc.)
REM ============================================================
setlocal enabledelayedexpansion

set ISO_DIR=D:
set USB_DISK=2
set USB_LETTER=E

echo.
echo === Forbes Asset Management — Recovery USB Creator ===
echo.
echo WARNING: This will ERASE all data on Disk %USB_DISK% (E:)
echo.
REM --- Locate Windows 11 ISO ---
set ISO_FILE=
for %%f in (%ISO_DIR%\Win11*.iso %ISO_DIR%\windows11*.iso) do (
    set ISO_FILE=%%f
)
if "%ISO_FILE%"=="" (
    echo ERROR: No Windows 11 ISO found in %ISO_DIR%
    echo.
    echo Download from: https://www.microsoft.com/software-download/windows11
    echo   1. Scroll to "Download Windows 11 Disk Image (ISO)"
    echo   2. Select "Windows 11 (multi-edition ISO for x64 devices)"
    echo   3. Save to D:\
    echo.
    if not exist "%ISO_DIR%" mkdir "%ISO_DIR%"
    exit /b 1
)
echo   ISO found: %ISO_FILE%

REM --- Confirm before wiping ---
echo.
echo   Target: Disk %USB_DISK% ^(USB, will be reformatted^)
echo.
set /p CONFIRM="Type YES to proceed: "
if /i not "%CONFIRM%"=="YES" (
    echo Aborted.
    exit /b 1
)

echo.
echo === [1/4] Formatting USB as UEFI-bootable (GPT + FAT32) ===

REM Create diskpart script
set DP_SCRIPT=%TEMP%\recovery_usb_diskpart.txt
(
    echo select disk %USB_DISK%
    echo clean
    echo convert gpt
    echo create partition primary
    echo format fs=fat32 quick label="RECOVERY"
    echo assign letter=%USB_LETTER%
    echo exit
) > "%DP_SCRIPT%"

diskpart /s "%DP_SCRIPT%"
del "%DP_SCRIPT%"

if not exist %USB_LETTER%:\ (
    echo ERROR: USB drive %USB_LETTER%: not accessible after format.
    exit /b 1
)
echo   USB formatted ......... OK

echo.
echo === [2/4] Mounting Windows 11 ISO ===

REM Mount the ISO and find the drive letter
REM Use PowerShell to mount ISO and get drive letter
for /f "tokens=*" %%D in ('powershell -Command "(Mount-DiskImage -ImagePath '%ISO_FILE%' -PassThru | Get-Volume).DriveLetter"') do (
    set ISO_DRIVE=%%D
)

if "%ISO_DRIVE%"=="" (
    echo ERROR: Failed to mount ISO.
    exit /b 1
)
echo   ISO mounted at %ISO_DRIVE%:

echo.
echo === [3/4] Copying files to USB ===

REM Check if install.wim exceeds FAT32 4GB limit (4294967295 bytes)
REM Using PowerShell for reliable large-number comparison
set SPLIT_NEEDED=0
for /f %%S in ('powershell -Command "(Get-Item '%ISO_DRIVE%:\sources\install.wim').Length -gt 4294967295"') do (
    if /i "%%S"=="True" set SPLIT_NEEDED=1
)

REM Copy everything EXCEPT install.wim first
echo   Copying boot files and metadata (this takes a few minutes)...
robocopy %ISO_DRIVE%:\ %USB_LETTER%:\ /E /XF install.wim /NFL /NDL /NJH /NJS /NP

if "%SPLIT_NEEDED%"=="1" (
    echo   install.wim exceeds 4 GB — splitting for FAT32 compatibility...
    dism /Split-Image /ImageFile:%ISO_DRIVE%:\sources\install.wim /SWMFile:%USB_LETTER%:\sources\install.swm /FileSize:3800
) else (
    echo   Copying install.wim — under 4 GB, no split needed...
    copy %ISO_DRIVE%:\sources\install.wim %USB_LETTER%:\sources\install.wim
)

echo.
echo === [4/4] Cleanup and verification ===

REM Dismount ISO
powershell -Command "Dismount-DiskImage -ImagePath '%ISO_FILE%'"
echo   ISO dismounted ........ OK

REM Verify key files exist on USB
set PASS=1
if not exist %USB_LETTER%:\sources\boot.wim (
    echo   ERROR: boot.wim missing
    set PASS=0
)
if not exist %USB_LETTER%:\efi\boot\bootx64.efi (
    echo   ERROR: bootx64.efi missing
    set PASS=0
)

if %PASS%==1 (
    echo   Boot files verified ... OK
) else (
    echo   WARNING: Some boot files are missing. USB may not boot correctly.
)

echo.
echo ============================================================
echo  Recovery USB created on %USB_LETTER%:
echo.
echo  To use for bare-metal recovery:
echo    1. Insert USB and boot from it (F12 at Dell splash)
echo    2. Select language, click Next
echo    3. Click "Repair your computer" (lower left)
echo    4. Troubleshoot ^> Advanced ^> System Image Recovery
echo    5. Select image from D:\WindowsImageBackup (or F:)
echo.
echo  Also available from the recovery USB:
echo    - Startup Repair
echo    - Command Prompt (diskpart, bcdboot, bcdedit, etc.)
echo    - System Restore
echo    - UEFI Firmware Settings
echo ============================================================

endlocal
