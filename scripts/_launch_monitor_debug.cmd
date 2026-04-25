@echo off
taskkill /IM backup-monitor.exe /F 2>nul
timeout /t 1 /nobreak >nul
start "" "C:\dev\Rust-DeskApp\target\debug\backup-monitor.exe"
timeout /t 2 /nobreak >nul
tasklist /FI "IMAGENAME eq backup-monitor.exe"
