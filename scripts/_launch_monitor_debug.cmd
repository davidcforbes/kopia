@echo off
taskkill /IM rustback-monitor.exe /F 2>nul
timeout /t 1 /nobreak >nul
start "" "C:\dev\Rust-DeskApp\target\debug\rustback-monitor.exe"
timeout /t 2 /nobreak >nul
tasklist /FI "IMAGENAME eq rustback-monitor.exe"
