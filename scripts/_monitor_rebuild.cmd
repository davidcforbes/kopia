@echo off
taskkill /IM backup-monitor.exe /F 2>&1
timeout /t 1 /nobreak >nul
pushd C:\dev\Rust-DeskApp
cargo build --release -p backup-monitor 2>&1
set BUILD_RC=%errorlevel%
popd
echo BUILD_RC=%BUILD_RC%
if %BUILD_RC% EQU 0 (
    start "" "C:\dev\Rust-DeskApp\target\release\backup-monitor.exe"
    timeout /t 2 /nobreak >nul
    tasklist /FI "IMAGENAME eq backup-monitor.exe"
)
