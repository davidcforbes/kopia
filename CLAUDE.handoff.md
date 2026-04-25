# CLAUDE.md — Kopia Backup Troubleshooting Handoff

## Context

Working on `C:\dev\kopia` (Chris's fork of kopia with custom patches on branch `fix/workshare-deadlock-prevention`). This is a handoff from Claude.ai (chat interface, non-elevated tools) to Claude Code running in an **elevated PowerShell**. Continue from where the chat session left off.

User: Chris (CISO at Forbes Asset Management). Machine: `ChrisLaptop2`, user `david`. Prefers direct, peer-level technical responses — no filler, no condescension.

## URGENT — do first

**The kopia repository password was exposed in the previous session's terminal scrollback. It must be rotated before any other work.** See "Immediate next steps" below.

## What's been done

1. **Diagnosed this morning's backup failures** — D: drive went offline between 4/20 05:17 AM and 4/21 02:01 AM; both wbadmin (02:00) and Kopia (03:00) failed because D: was unreachable. D: was rebooted and is back online.

2. **wbadmin backup completed successfully** — manually triggered by user at 19:03:07 on 4/21, finished at 22:53:00. Event ID 4 logged. 3h 50m total. First full image post-cleanup (~3 TB written to `D:\WindowsImageBackup\ChrisLaptop2\`).

3. **Backup Monitor progress-indicator feature applied and built.** Files modified under `C:\dev\Rust-DeskApp\crates\backup-monitor\`:
   - `Cargo.toml` — added `Win32_System_SystemInformation` feature
   - `src/data.rs` — added `live_elapsed`/`live_phase` to `KopiaRun`, `live_elapsed`/`live_size` to `WbadminRun`; phase tracking in Kopia log parser; `load_status` now populates live fields with 5-min staleness detection; helper functions (SYSTEMTIME parsing, directory size, human-readable formatting) appended at EOF
   - `src/components/kopia_table.rs` — Duration cell shows `{elapsed} {phase}` for Running rows in accent color
   - `src/components/wbadmin_table.rs` — End cell shows `live_size`, Duration shows `live_elapsed`, accent color
   - Built successfully at `C:\dev\Rust-DeskApp\target\release\backup-monitor.exe` (0.37 MB)
   - Also fixed unrelated workspace dep: `crates/d2d-ui/Cargo.toml` and `crates/d2d-ui/src/controls/mermaid_display.rs` updated from `markview` → `editmark` (folder `C:\dev\markview` was renamed to `C:\dev\editmark`, crate renamed `markview-mermaid` → `editmark-mermaid`)

4. **Scheduled task recovery**:
   - Original `\Backup\DailyKopiaSnapshot` task got lost (some ghost registration blocking re-creation; Task Scheduler has a phantom reservation on that exact name that survives registry cleanup — needs `Restart-Service Schedule -Force` OR a reboot to clear)
   - Replacement task created: **`\Backup\DailyKopiaSnapshotV2`** with identical config except `LogonType=InteractiveToken`. XML at `$env:TEMP\DailyKopiaSnapshot.xml`.

5. **Missing scripts restored from Kopia snapshot `kb02693c5998c7ad0e9d334f301838a68` (4/20 03:00)**:
   - `C:\dev\kopia\scripts\daily_kopia_backup.cmd` (5981 B, restored)
   - `C:\dev\kopia\scripts\backup_status.cmd` (2146 B, restored)
   - `C:\dev\kopia\scripts\create_scheduled_task.ps1` (657 B, restored)
   - These were never committed to git. Reason they disappeared is still unknown — USN journal showed active writes to `daily_kopia.log` at 23:20:51 but the delete event wasn't captured in our filtered query. No Bitdefender events. Possibly an earlier run of the script's own log-rotate path corrupted things, possibly something else. **Open question.**

6. **DPAPI password file created** at `C:\dev\kopia\scripts\.kopia-pw.dat` (230 B, machine-scope encrypted, ACL = Administrators:R + SYSTEM:R only). Decryption helper at `C:\dev\kopia\scripts\get_kopia_password.ps1`. This is because `daily_kopia_backup.cmd` running under Task Scheduler's S4U/InteractiveToken logon cannot access the user-scope kopia credential in Windows Credential Manager. Password-file approach bypasses that.

## Current blocker

`daily_kopia_backup.cmd` calls `kopia repository status` in the `[repo-check]` step via `repo_status_check.ps1`. Under Task Scheduler context, kopia can't find the repo password (Credential Manager entry is user-scope DPAPI, S4U/InteractiveToken tokens can't decrypt) and exits 9059 in ~10ms.

Partial fix in progress: set `KOPIA_PASSWORD` env var from the DPAPI file before invoking kopia. The edit to `daily_kopia_backup.cmd` was drafted but NOT YET APPLIED. Draft insert point: right after `set OVERALL_RC=0`. Content of the insert:

```cmd

REM ---- Load kopia password from machine-scope DPAPI file ----
set PS51=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
for /f "usebackq delims=" %%K in (`"%PS51%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\get_kopia_password.ps1"`) do set KOPIA_PASSWORD=%%K
if "!KOPIA_PASSWORD!"=="" (
    echo %DATE% %TIME% - FATAL: could not decrypt kopia password file >> "%LOG%"
    echo ======================================== >> "%LOG%"
    exit /b 2
)
```

Why the full PS path: `cmd /c` couldn't resolve bare `powershell.exe` — Windows App Execution Alias points to `C:\Program Files\PowerShell\7\powershell.exe` which doesn't exist on this box. Full path to Windows PowerShell 5.1 at `$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe` works.

## Immediate next steps (in order)

### 1. Rotate exposed kopia password (URGENT, do FIRST)

```powershell
& 'C:\Users\david\go\bin\kopia.exe' repository change-password
# Prompts for new password twice. Choose a NEW strong password.
```

### 2. Re-encrypt the new password into the DPAPI file

```powershell
Add-Type -AssemblyName System.Security
$pw = Read-Host -AsSecureString 'NEW Kopia repo password'
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw)
$plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
$enc = [Security.Cryptography.ProtectedData]::Protect(
    [Text.Encoding]::UTF8.GetBytes($plain), $null,
    [Security.Cryptography.DataProtectionScope]::LocalMachine)
[IO.File]::WriteAllBytes('C:\dev\kopia\scripts\.kopia-pw.dat', $enc)
Remove-Variable plain, pw
```

### 3. Update the Credential Manager kopia entry so interactive kopia still works

```powershell
& 'C:\Users\david\go\bin\kopia.exe' repository disconnect
& 'C:\Users\david\go\bin\kopia.exe' repository connect filesystem --path D:\KopiaRepo
# Enter the new password when prompted
```

### 4. Apply the pending daily_kopia_backup.cmd patch

Read `C:\dev\kopia\scripts\daily_kopia_backup.cmd`, insert the KOPIA_PASSWORD loader block shown above after the `set OVERALL_RC=0` line. Verify the edit preserves the v2 comment header and the log-rotation block that follows.

### 5. Fire and verify

```powershell
schtasks /Run /TN '\Backup\DailyKopiaSnapshotV2'
Start-Sleep 8
Get-Content C:\dev\kopia\logs\daily_kopia.log -Tail 25
```

Success = log shows `[repo-check] repo connected OK` followed by `[snapshot] C:\dev starting` and keeps writing. Full run expected to take 8–15 min (first post-gap run, a few days of deltas to catch up).

## Deferred work (after step 5 succeeds)

### A. Rewrite `repo_status_check.ps1` to use async stream capture

Current file uses `.StandardOutput.ReadToEnd()` synchronously, which deadlocks when the child blocks on filesystem I/O (this is what caused the original 4/21 03:00 hang). Replace with `OutputDataReceived`/`ErrorDataReceived` async handlers + `BeginOutputReadLine`/`WaitForExit(timeout)`. This makes the 120s timeout actually enforce.

### B. Add disk-preflight gate to `daily_kopia_backup.cmd`

Before the kopia binary check, verify D: is mounted and the repo marker exists. Exit codes: 10 = VOLUME_MISSING, 11 = VOLUME_READONLY, 12 = REPO_MARKER_MISSING. Lets Backup Monitor differentiate "skipped due to missing disk" from "real failure".

```cmd
REM ---- Disk preflight ----
if not exist D:\ (
    echo %DATE% %TIME% - FATAL: D: volume not present >> "%LOG%"
    echo ======================================== >> "%LOG%"
    exit /b 10
)
if not exist "%KOPIA_REPO%\kopia.repository.f" (
    echo %DATE% %TIME% - FATAL: repo marker missing at %KOPIA_REPO% >> "%LOG%"
    echo ======================================== >> "%LOG%"
    exit /b 12
)
```

Put this before the `[preflight] checking kopia binary` block.

### C. Add zombie reaper to script startup

Scan the log for a prior `Daily Kopia backup start` with no matching completion; if found, append a synthetic FATAL line so the Backup Monitor parser doesn't show a dangling "Running" row. Prevents the 03:00/08:43 zombie pattern we saw.

### D. Rename task back to `DailyKopiaSnapshot` after a reboot

After next reboot the phantom name reservation clears. Recreate at canonical name:

```powershell
# After reboot:
$tmp = "$env:TEMP\DailyKopiaSnapshot.xml"  # XML still in temp dir — inline it if not
schtasks /Create /TN '\Backup\DailyKopiaSnapshot' /XML $tmp /F
schtasks /Delete /TN '\Backup\DailyKopiaSnapshotV2' /F
```

Inline XML for rebuild if temp file is gone: (see XML block at bottom of this doc).

### E. Investigate the file-deletion mystery

`daily_kopia_backup.cmd`, `backup_status.cmd`, `create_scheduled_task.ps1`, `daily_kopia_backup.log`, and the original `DailyKopiaSnapshot` task all vanished within a short window after 23:20 on 4/21. Not in Recycle Bin. No Defender/Bitdefender detections in their event logs. Not in any Bitdefender quarantine check we ran. USN journal showed writes but not the deletes (filter was too tight). Worth a proper `fsutil usn readjournal` filtered for `FILE_DELETE` reason code to identify the deleter. If it's Bitdefender's silent rollback, will need allowlisting.

### F. Launch and verify the new Backup Monitor

```powershell
& 'C:\dev\Rust-DeskApp\target\release\backup-monitor.exe'
```

Expected: Duration column populates with live elapsed + phase for running kopia runs; End column populates with live size for running wbadmin runs; both in accent color; updates every 60s. With the current zombie log state there may be a stale `Running` row at top showing `stalled ·` prefix — that's expected behavior, the stale detection working.

## Reference: current task XML

Stored at `$env:TEMP\DailyKopiaSnapshot.xml`. Reconstruct if gone:

```xml
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>david</Author>
    <Description>Daily Kopia snapshot backup</Description>
    <URI>\Backup\DailyKopiaSnapshot</URI>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-04-22T03:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>ChrisLaptop2\david</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <ExecutionTimeLimit>PT4H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>C:\dev\kopia\scripts\daily_kopia_backup.cmd</Command></Exec>
  </Actions>
</Task>
```

## Reference: system state at handoff

- Kopia repo: `D:\KopiaRepo`, 741.7 GB data, 484.9 GB packed, 34.6% compression
- Last successful Kopia snapshot: `kb02693c5998c7ad0e9d334f301838a68` at 4/20 03:00 PDT
- Last successful wbadmin: 4/21 22:53 (tonight's manual run)
- D: volume: 7.45 TB total, ~2.6 TB free (post-wbadmin)
- C: volume: 3.8 TB total, ~0.95 TB free
- System last booted: 4/21 07:02:25 AM (credential loss tied to this reboot)
- KopiaUI server: running since 7:06 AM PID 45888 — holds its own repo connection, don't disturb
