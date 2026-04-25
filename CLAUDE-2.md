@'
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
   - Also fixed unrelated workspace dep: `crates/d2d-ui/Cargo