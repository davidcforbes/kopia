@echo off
REM ============================================================
REM  Kopia Restore Helper — interactive CLI restore workflow
REM  Usage: restore.cmd [mount|restore|list]
REM ============================================================
setlocal

set KOPIA_BIN=C:\Users\david\go\bin\kopia.exe
set KOPIA_REPO=D:\KopiaRepo

REM Use existing repo connection (already configured via setup_all.cmd)

if "%1"=="" goto :USAGE
if /i "%1"=="list" goto :LIST
if /i "%1"=="mount" goto :MOUNT
if /i "%1"=="restore" goto :RESTORE
if /i "%1"=="unmount" goto :UNMOUNT
if /i "%1"=="wbadmin" goto :WBADMIN
goto :USAGE

:LIST
echo.
echo === Available Snapshots ===
"%KOPIA_BIN%" snapshot list --all
goto :EOF

:MOUNT
if "%2"=="" (
    echo Usage: restore.cmd mount ^<snapshot-id^> [drive-letter]
    echo   Default mount point: R:
    echo   Get snapshot IDs from: restore.cmd list
    goto :EOF
)
set SNAP_ID=%2
set MNT=%3
if "%MNT%"=="" set MNT=R:
echo Mounting snapshot %SNAP_ID% to %MNT% ...
"%KOPIA_BIN%" mount %SNAP_ID% %MNT%
echo.
echo Browse %MNT% in Explorer or cmd to copy files.
echo When done: restore.cmd unmount %MNT%
goto :EOF

:UNMOUNT
set MNT=%2
if "%MNT%"=="" set MNT=R:
echo Unmounting %MNT% ...
"%KOPIA_BIN%" mount --unmount %MNT%
echo Done.
goto :EOF

:RESTORE
if "%2"=="" (
    echo Usage: restore.cmd restore ^<snapshot-id^> ^<target-dir^> [--overwrite-files]
    echo   Example: restore.cmd restore k1a2b3c4 C:\Restore\dev
    goto :EOF
)
set SNAP_ID=%2
set TARGET=%3
set FLAGS=%4
echo Restoring snapshot %SNAP_ID% to %TARGET% %FLAGS% ...
"%KOPIA_BIN%" restore %SNAP_ID% "%TARGET%" %FLAGS%
echo Done. Files restored to %TARGET%.
goto :EOF

:WBADMIN
if "%2"=="" (
    echo Usage: restore.cmd wbadmin ^<file-path^> [output-dir]
    echo   Pulls a single file from the most recent wbadmin system image VHDX.
    echo   Requires an elevated prompt.
    echo   Example: restore.cmd wbadmin "C:\dev\EUC\.pencil\EUC.pen"
    goto :EOF
)
set WB_FILE=%~2
set WB_OUT=%~3
set PS_ARGS=-NoProfile -ExecutionPolicy Bypass -File "%~dp0restore_wbadmin_file.ps1" -FilePath "%WB_FILE%"
if not "%WB_OUT%"=="" set PS_ARGS=%PS_ARGS% -OutputDir "%WB_OUT%"
powershell.exe %PS_ARGS%
goto :EOF

:USAGE
echo.
echo Kopia Restore Helper
echo ====================
echo.
echo Commands:
echo   restore.cmd list                                    List all kopia snapshots
echo   restore.cmd mount ^<snap-id^> [drive]                Mount kopia snapshot read-only (default: R:)
echo   restore.cmd unmount [drive]                         Unmount kopia mount (default: R:)
echo   restore.cmd restore ^<snap-id^> ^<target^> [flags]   Restore kopia snapshot to directory
echo   restore.cmd wbadmin ^<file-path^> [output-dir]       Pull one file from latest wbadmin image (elevated)
echo.
echo System image restore (full bare-metal):
echo   1. Boot from Windows 11 USB
echo   2. Repair your computer ^> Troubleshoot ^> System Image Recovery
echo   3. Select image from D:\WindowsImageBackup
echo.
echo Manual wbadmin VHD mount fallback (if 'restore.cmd wbadmin' fails):
echo   diskpart
echo     select vdisk file="D:\WindowsImageBackup\...\backup.vhdx"
echo     attach vdisk readonly
echo     list volume
echo     select volume ^<N^>
echo     assign letter=V
echo     exit
echo   (browse V: then detach: diskpart ^> select vdisk ^> detach vdisk)

:EOF
endlocal
