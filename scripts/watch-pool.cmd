@echo off
REM Watch kernel pool and handle counts every 30 seconds
REM Run from any prompt; Ctrl+C to stop
:loop
powershell -NoProfile -Command "$perf = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory; $h = (Get-Process | Measure-Object HandleCount -Sum).Sum; Write-Host ('{0:HH:mm:ss}  NP={1,5} MB  PP={2,5} MB  Handles={3,7:N0}' -f (Get-Date), [int]($perf.PoolNonpagedBytes/1MB), [int]($perf.PoolPagedBytes/1MB), $h)"
timeout /t 30 /nobreak >nul
goto loop
