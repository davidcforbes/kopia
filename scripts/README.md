# Personal backup automation scripts

Local Windows automation around this Kopia fork — **not for upstream**.
Lives only on the `personal/automation` branch in the fork. Never merged
to `master` or any `fix/*` PR branch.

## Layout

| File | Purpose |
|---|---|
| `setup_all.cmd` | One-time elevated setup — creates Kopia repo, registers scheduled tasks, configures wbadmin. |
| `daily_kopia_backup.cmd` | Nightly 03:00 task — `C:\dev` and `C:\Users\david` snapshots, quick maintenance, backup-indexer. Decrypts `KOPIA_PASSWORD` from `.kopia-pw.dat` via DPAPI LocalMachine scope. |
| `verify_backups.cmd` | Weekly Saturday 04:00 task — `snapshot verify` + 5% file content sample + full maintenance. Same DPAPI password loader. |
| `get_kopia_password.ps1` | Reads `.kopia-pw.dat` (gitignored), runs `ProtectedData.Unprotect` LocalMachine, writes plaintext to stdout. |
| `repo_status_check.ps1` | Hard-timeout wrapper around `kopia repository status` for monitoring. |
| `check_backup_health.ps1` | Daily 08:00 task — parses last `daily_kopia.log` run, posts Windows toast PASS/FAIL. Toast click target is `kopiamonitor:` protocol. |
| `check_backup_errors.ps1` | Older error-counting helper used by the daily script's trailer. |
| `register_backup_monitor_toast.ps1` | One-time HKCU registration: `KopiaBackup.HealthCheck` AppId + `kopiamonitor:` URL protocol pointing at `backup-monitor.exe`. |
| `create_scheduled_task.ps1` | Registers the daily 03:00 Kopia task. S4U logon + RunLevel Highest. |
| `create_health_check_task.ps1` | Registers the daily 08:00 health-check task. Interactive logon (toast must reach the user's session). |
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

## Branch hygiene

This branch lives only on `fork/personal/automation`. To pull updates from
upstream master without polluting this branch:

```bash
git fetch origin
git rebase origin/master
git push fork personal/automation --force-with-lease
```
