# Personal backup automation scripts

Local Windows automation around this Kopia fork — **not for upstream**.
Tracked on `master` of the fork at `davidcforbes/kopia` since
2026-04-29 (previously isolated on a `personal/automation` branch
that was retired). Push to `fork` only; never propose upstream.

## Layout

| File | Purpose |
|---|---|
| `setup_all.cmd` | One-time elevated setup — creates Kopia repo, registers scheduled tasks, configures wbadmin. |
| `daily_kopia_backup.cmd` | Nightly 03:00 task — `C:\dev` and `C:\Users\david` snapshots, quick maintenance, backup-indexer. Decrypts `KOPIA_PASSWORD` from `.kopia-pw.dat` via DPAPI LocalMachine scope. |
| `verify_backups.cmd` | Weekly Saturday 04:00 task — `snapshot verify` + 5% file content sample + full maintenance. Same DPAPI password loader. |
| `get_kopia_password.ps1` | Reads `.kopia-pw.dat` (gitignored), runs `ProtectedData.Unprotect` LocalMachine, writes plaintext to stdout. |
| `repo_status_check.ps1` | Hard-timeout wrapper around `kopia repository status` for monitoring. |
| `post_summary_toast.ps1` | Called inline by `daily_kopia_backup.cmd` after the last snapshot. Reads kopia's structured `snapshot summary ...` lines from the log, aggregates errors/files/bytes across sources, posts a single PASS/FAIL/UNKNOWN toast within seconds of the run finishing. Requires kopia built from master commit `1f5c6604` or later. |
| `check_backup_health.ps1` | Daily 08:00 watchdog. Stays silent on success (the inline toast already spoke); fires only if the daily task didn't run, the log is missing, or no `snapshot summary` line was ever written. |
| `check_wbadmin_health.ps1` | Daily 08:30 task — parses `wbadmin get versions`, asserts newest backup is < 26h old, peeks `Microsoft-Windows-Backup` event log for failures since then. Posts toast PASS/STALE/FAIL/UNKNOWN. Writes `WBADMIN_HEALTH_FAIL.flag`. |
| `check_backup_errors.ps1` | Older error-counting helper, retained for ad-hoc use. |
| `kopia_errors.ps1` | On-demand drilldown when `errors=N>0`: lists per-folder error counts and unique failed paths from a snapshot log. |
| `register_backup_monitor_toast.ps1` | One-time HKCU registration: `KopiaBackup.HealthCheck` AppId + `kopiamonitor:` URL protocol pointing at `backup-monitor.exe`. |
| `create_scheduled_task.ps1` | Registers the daily 03:00 Kopia task. S4U logon + RunLevel Highest. |
| `create_health_check_task.ps1` | Registers the daily 08:00 watchdog. Interactive logon. |
| `create_wbadmin_health_check_task.ps1` | Registers the daily 08:30 wbadmin freshness check. Interactive logon + RunLevel Highest. |
| `kopia_errors.cmd` / `.ps1` | On-demand `errors:N` summary across recent snapshots. |
| `pre_backup_scan.ps1` | Inventory of about-to-be-backed-up state. |
| `restore.cmd` | One-shot `kopia snapshot restore` wrapper. |
| `setup_wbadmin.cmd` / `reset_wbadmin.cmd` | Windows Backup configuration helpers. |
| `run_indexer_backfill.cmd` | Manually trigger a backup-indexer run outside the nightly. |
| `apply-sysmon-lean.cmd` + `sysmon-lean.xml` | Sysinternals Sysmon config tuned for backup observability. |
| `create_recovery_usb.cmd` | Build a Windows recovery USB. |
| `watch-pool.cmd` | Tail workshare pool diagnostics during a snapshot. |
| `zombie_reaper.ps1` | Kill orphaned `kopia.exe` processes. |
| `_*.{cmd,ps1}` | Internal helpers used by the scripts above. |

## Secrets handling

`.kopia-pw.dat` is the DPAPI-protected repository password. **Gitignored.**
Recreate on a fresh machine:

```powershell
$pw = Read-Host -AsSecureString "Kopia repo password"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw)
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
$bytes = [Text.Encoding]::UTF8.GetBytes($plain)
$enc = [Security.Cryptography.ProtectedData]::Protect(
    $bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
[IO.File]::WriteAllBytes('C:\dev\kopia\scripts\.kopia-pw.dat', $enc)
```

Apply restrictive ACLs (`icacls .kopia-pw.dat /inheritance:r /grant:r SYSTEM:F Administrators:F`).

## Notification architecture

Three independent toast channels, one shared `KopiaBackup.HealthCheck` AppId:

1. **Inline kopia toast** — fires within seconds of `daily_kopia_backup.cmd`
   finishing, via `post_summary_toast.ps1`. Reads structured `snapshot
   summary ...` lines kopia emits per source. Primary signal for the day.
2. **08:00 missed-run watchdog** (`check_backup_health.ps1`) — silent on
   success; toasts only when the daily task skipped a run or kopia.exe
   lacks the structured-summary patch. Runs as a separate task because
   the inline toast cannot fire if the daily task itself never started.
3. **08:30 wbadmin freshness check** (`check_wbadmin_health.ps1`) —
   independent of kopia. Catches the system-image backup going stale.

Failure flag files in `C:\dev\kopia\logs\`: `BACKUP_ERRORS.flag` (kopia
inline), `BACKUP_HEALTH_FAIL.flag` (watchdog), `WBADMIN_HEALTH_FAIL.flag`
(wbadmin). Each is written on its respective failure path and removed
when that channel returns to PASS.

## Failure modes

**Ad-hoc `kopia snapshot create` produces no toast.** The inline toast is
posted by `daily_kopia_backup.cmd`, which is the only path that writes
`daily_kopia.log`. If you snapshot manually outside the wrapper, no toast
fires. To get a toast on a manual run, invoke the wrapper:
`scripts\daily_kopia_backup.cmd`.

**Verify scheduled tasks are registered before relying on the daily flow.**
The 2026-04-28 silent failure happened because no kopia tasks were
registered on this host (`schtasks /query | findstr /I kopia` returned
nothing) — neither the 03:00 daily nor the 08:00 watchdog. The fix is to
re-run the registration scripts. To verify after registration:

```cmd
schtasks /query /tn "\Backup\DailyKopiaSnapshot" /v /fo LIST
schtasks /query /tn "\Backup\KopiaBackupHealthCheck" /v /fo LIST
schtasks /query /tn "\Backup\WbadminHealthCheck" /v /fo LIST
```

**Stale flag files mislead future you.** A `BACKUP_HEALTH_FAIL.flag`
sitting in `logs/` after a fixed incident makes downstream tooling think
the host is unhealthy. Delete stale flags after resolving an incident; the
toast scripts will recreate them next time a real failure occurs.

## Push hygiene

These scripts live on `master` of the fork (`davidcforbes/kopia`). Push
only to that remote; **never** to `origin/kopia` (upstream). The fork's
master diverged from upstream long ago and carries this Windows-specific
automation that has no place in the open-source repo.

```bash
git push fork master                  # this is the canonical destination
git fetch origin                      # to pull upstream changes
git merge origin/master               # standard merge from upstream when desired
```

If you ever want to upstream a kopia bug fix, cherry-pick the specific
commits onto a clean branch off `origin/master` rather than pushing
this fork's master.
