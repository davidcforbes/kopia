# Backup Stack Architecture

> Authoritative inventory for the kopia + wbadmin + backup-monitor stack
> running on this Windows host. Read this **before** answering questions
> about backup state or designing new tooling in this orbit. The
> companion file `CLAUDE.md` enforces two hard rules that depend on this
> doc.

## Why this doc exists

Two failure modes are documented in `personal/automation:scripts/README.md`'s
"Failure modes" section:

1. Sampling one log file and answering "no errors" while a different
   authoritative source disagreed.
2. Designing new tooling without first auditing the existing components.

Both happened because the surfaces below were not catalogued in one
place. They are now.

## Components

| Binary                 | Path                                                      | Role                                                                     |
|------------------------|-----------------------------------------------------------|--------------------------------------------------------------------------|
| `kopia.exe`            | `C:\Users\david\go\bin\kopia.exe`                         | Snapshot/restore engine. Built from this fork (`go install ./...`).      |
| `backup-monitor.exe`   | `C:\dev\backup-monitor\target\release\backup-monitor.exe` | Direct2D GUI dashboard. Parses logs and renders status cards live.       |
| `backup-dump.exe`      | `C:\dev\backup-monitor\target\release\backup-dump.exe`    | Console version of the same scoring engine. **Use this from agents.**    |
| `backup-indexer.exe`   | `C:\dev\backup-monitor\target\release\backup-indexer.exe` | Builds gzipped JSONL search indexes in `D:\BackupMonitorIndex`. Wired into `daily_kopia_backup.cmd` after maintenance — non-fatal on failure. Bootstrap with `scripts/run_indexer_backfill.cmd` (elevated). |
| **Upstream `kopia.exe server`** | `C:\Users\david\go\bin\kopia.exe` (run by `\Backup\KopiaServer` Scheduled Task) | **Sole repository holder.** Long-running, started at boot via `scripts/start_kopia_server.ps1` (which reads `KOPIA_SERVER_PASSWORD` from the DPAPI vault). Listens on `127.0.0.1:51515` with the stable TLS cert at `D:\KopiaServer\server.{crt,key}`. All other components (KopiaUI, daily_kopia_backup.cmd, manual `kopia.exe` invocations against `%APPDATA%\kopia\repository.config`) are REST clients of this process, never repo-direct. Runs Kopia's policy-driven maintenance internally — no other component should run `kopia maintenance run`. Architectural change landed 2026-05-04 (epic kopia-7s7) to eliminate the multi-process repo race that broke the 05-04 03:00 nightly. |
| `KopiaUI.exe`          | `C:\dev\kopia\dist\kopia-ui\win-unpacked\KopiaUI.exe`     | Electron desktop app (long-running tray process). Spawns a bundled `kopia.exe server` child (path: `…\resources\server\kopia.exe`) configured **as a client** of the upstream server above (post-cutover 2026-05-04 — `repository.config` is API-mode pointing at `https://127.0.0.1:51515` with the pinned cert fingerprint). The bundled child does NOT open the repo on disk — it's a stateless proxy serving KopiaUI's own UI. Maintenance failures used to surface here; they now come from the upstream server. |

`backup-monitor`'s parsing covers `C:\dev\kopia\logs\daily_kopia.log`
plus the `Microsoft-Windows-Backup` event log. It produces a single
PASS/FAIL/STATUS-CARDS verdict per run and a paginated history.
KopiaUI is a parallel toast emitter — `backup-monitor` does **not** parse
KopiaUI's logs or surface its maintenance failures.

## Authoritative source by question

When a question is asked about backup state, read from the row that
matches. Do not improvise.

| Question                                            | Authoritative source                                                                                              |
|-----------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| Did last night's backup pass?                       | `backup-dump.exe` STATUS CARDS (Kopia + wbadmin) and run #1 row.                                                  |
| Is the upstream kopia server up?                    | `schtasks /Query /TN "\Backup\KopiaServer"` (Status=Running), plus `netstat -ano \| findstr 127.0.0.1:51515` showing LISTENING. From clients: `kopia --config-file=%APPDATA%\kopia\repository.config repository status` exits 0 with API URL in output. |
| What was the kopia exit code on a given night?      | `C:\dev\kopia\logs\daily_kopia.log` `Exit codes:` line for that run.                                              |
| Which files errored inside a snapshot?              | The matching `C:\Users\david\AppData\Local\kopia\cli-logs\kopia-*-snapshot-create.0.log`.                         |
| Did wbadmin run last night?                         | `wbadmin get versions` newest entry, plus `Microsoft-Windows-Backup` event log via `Get-WinEvent`.                |
| Was the daily wrapper invoked at all?               | `C:\dev\kopia\logs\daily_kopia.log` mtime + the `Daily Kopia backup start` marker.                                |
| Are there outstanding flagged failures?             | `C:\dev\kopia\logs\BACKUP_ERRORS.flag` and `BACKUP_HEALTH_FAIL.flag` and `WBADMIN_HEALTH_FAIL.flag`.               |
| Toast click target / how to open the dashboard?     | `kopiamonitor:` URL protocol, registered HKCU, points at `backup-monitor.exe` (see `register_backup_monitor_toast.ps1`). |
| "Kopia has encountered an error during Maintenance" toast appearing at odd hours? | Post-cutover: the upstream `\Backup\KopiaServer` task is running maintenance per repo policy. The toast is forwarded by KopiaUI (AppId `electron.app.KopiaUI`) because it subscribes to the upstream server's notification stream. Inspect `%APPDATA%\kopia-ui\logs\main.log` for the `NOTIFICATION` JSON, then check the `kopia-*-maintenance-*.log` under `%LOCALAPPDATA%\kopia\cli-logs\` (server-spawned) for the actual error. The pre-cutover "stale credentials in KopiaUI's bundled child" failure mode no longer applies. |
| Why does Find & Restore show no matches for a known file? | Compare newest mtime in `D:\BackupMonitorIndex\kopia-*.jsonl.gz` against today. If older than the latest snapshot, the indexer didn't run — find `[indexer]` lines in `daily_kopia.log`. |

When two of these disagree, **report the disagreement**. Do not pick a
winner.

## Log surfaces

| Path                                                       | Writer                              | Contents                                                                                          |
|------------------------------------------------------------|-------------------------------------|---------------------------------------------------------------------------------------------------|
| `C:\Users\david\AppData\Local\kopia\cli-logs\*.log`        | `kopia.exe` itself                  | One file per CLI invocation. DEBUG-level. Multi-megabyte. Sampling one is **not** representative. |
| `C:\dev\kopia\logs\daily_kopia.log`                        | `daily_kopia_backup.cmd` (v2)       | Wrapper-aggregated. One run per nightly fire. Has `Exit codes:` and per-step `[snapshot]` lines.  |
| Event log: `Microsoft-Windows-Backup`                      | wbadmin / wbengine                  | Critical/Error events around wbadmin runs. Read via `Get-WinEvent`.                               |
| `C:\dev\kopia\logs\BACKUP_ERRORS.flag`                     | `daily_kopia_backup.cmd` v2         | Touched when `check_backup_errors.ps1` reports `errors > 0`. Removed on PASS.                     |
| `C:\dev\kopia\logs\BACKUP_HEALTH_FAIL.flag`                | `check_backup_health.ps1`           | Touched when watchdog detects a missed run / no summary line.                                     |
| `C:\dev\kopia\logs\WBADMIN_HEALTH_FAIL.flag`               | `check_wbadmin_health.ps1`          | Touched when wbadmin freshness exceeds threshold or a failure event is found.                    |
| `%APPDATA%\kopia-ui\logs\main.log`                         | KopiaUI Electron + bundled server   | KopiaUI lifecycle + per-notification `NOTIFICATION:` JSON lines. Authoritative source for KopiaUI maintenance failures. Rolls to `main.old.log` at ~1 MB. |
| `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db` | Windows notification platform   | SQLite store of all delivered toasts (any AppId). Useful when investigating a mystery toast — see `reference_toast_debugging.md` memory or query `Notification` joined to `NotificationHandler.PrimaryId`. Default retention ~3 days. |

## Scheduled tasks (under `\Backup\`)

| Task name                  | Schedule        | Action                                                                                                  |
|----------------------------|-----------------|---------------------------------------------------------------------------------------------------------|
| `DailyKopiaSnapshotV2`     | Daily 03:00     | Runs `C:\dev\kopia\scripts\daily_kopia_backup.cmd` (v2 wrapper, RunLevel Highest, S4U logon).           |
| `KopiaBackupHealthCheck`   | Daily 08:00     | Runs `check_backup_health.ps1` (watchdog: did the daily run write a `snapshot summary` line?).          |
| `WbadminHealthCheck`       | Daily 08:05     | Runs `check_wbadmin_health.ps1` (wbadmin freshness via `wbadmin get versions` + Backup event log).      |
| `KopiaServer`              | At system startup, restart on failure (3×1min) | Runs `scripts/start_kopia_server.ps1` (S4U logon, RunLevel=HighestAvailable). Long-running upstream `kopia.exe server` on 127.0.0.1:51515 — the sole holder of `D:\KopiaRepo`. See Components table. |
| `WeeklyBackupVerify`       | Weekly Sat 04:00| Runs `verify_backups.cmd` (`kopia snapshot verify` + content sample + full maintenance).                |

The daily wbadmin system image runs out of the built-in
`\Microsoft\Windows\Backup\Microsoft-Windows-WindowsBackup` task (Windows-managed,
templateId-based, fires at 02:00 to `D:` with `-allCritical`). A second
`\Backup\WeeklySystemImage` task previously existed but was redundant with the
daily run, conflicted on the same target, and its companion script was missing
since the 04-25 incident — it was deleted 2026-05-02 (kopia-5o6 closed).

## Notification chain

1. `daily_kopia_backup.cmd` writes the structured `snapshot summary
   source=... errors=N ...` line per source (added in master commit
   `1f5c6604` on `feat/snapshot-summary-line`).
2. After the last snapshot, the wrapper invokes
   `post_summary_toast.ps1` which parses the line and posts a single
   PASS/FAIL Windows toast.
3. The toast's launch target and the `Open` action both use the
   `kopiamonitor:` URL protocol, registered HKCU by
   `register_backup_monitor_toast.ps1`.
4. The handler resolves to `backup-monitor.exe`, which loads the live
   dashboard.
5. The 08:00 watchdog and 08:05 wbadmin checks are independent toasts
   on the same `KopiaBackup.HealthCheck` AppId. Both are **silent on
   PASS** — they only emit a toast when something is wrong (FAIL,
   STALE, NO RUN FOUND, etc.). Their flag files are still
   written/cleared either way, so `backup-monitor.exe` reflects state.
6. **External, parallel emitter (post-cutover 2026-05-04):** maintenance
   now runs on the **upstream `kopia.exe server`** (the `\Backup\KopiaServer`
   task), not on KopiaUI's bundled child. KopiaUI's bundled child runs
   in client/proxy mode and does not perform maintenance. If the upstream
   server logs a maintenance error (any path issue, missed schedule,
   credential drift), KopiaUI's bundled child still surfaces the toast
   under AppId **`electron.app.KopiaUI`** because KopiaUI is the
   subscriber to the server's notification stream. These toasts are
   independent of `KopiaBackup.HealthCheck` and not parsed by
   `backup-monitor.exe`. Stale-credentials are no longer relevant —
   the upstream server reads `KOPIA_SERVER_PASSWORD` from the DPAPI
   vault on startup; client credentials are pinned via `repository.config`.

## Secrets layout (post-cutover 2026-05-04)

`scripts/` is tracked normally on master. Two DPAPI LocalMachine-
encrypted secrets live there:

- `scripts/.kopia-pw.dat` — kopia *repository* password (decrypts the
  blobs in `D:\KopiaRepo`). Read by `get_kopia_password.ps1`.
- `scripts/.kopia-server-pw.dat` — kopia *server* HTTP basic-auth
  password and repo-user password for `david@chrislaptop2`. Read by
  `get_kopia_server_password.ps1`. Used by both `start_kopia_server.ps1`
  (server side) and `daily_kopia_backup.cmd` (client side, fed via the
  `KOPIA_PASSWORD` env var).

Plus the upstream server's stable TLS cert at
`D:\KopiaServer\{server.crt, server.key, fingerprint.sha256}`. Locked
to `SYSTEM:F Administrators:F david:R`. Fingerprint pinned in
`repository.config`'s `apiServer.serverCertFingerprint` for all clients.

Both vault secrets are protected by three orthogonal layers:

1. **`scripts/.gitignore`** (committed, shared) ignores
   `.kopia-pw.dat`, `.kopia-server-pw.dat`, and `BACKUP_*.flag`. The
   inner gate.
2. **`.git/info/exclude`** (per-host, never committed) carries a
   defensive secret-pattern safety net (`*.pw`, `*.pw.dat`, `*.pem`,
   `*.key`, `*.token`, `*-credentials.{json,yaml}`,
   `secrets.{json,yaml}`, `.env`, `.env.*`). Catches mistakes the
   inner gitignore might miss.
3. **DPAPI LocalMachine encryption + restrictive ACLs** on the file
   itself. Machine-bound: even a leak elsewhere would be useless.

The historical "v1/v2 hazard" — where on-disk scripts evolved
silently while `personal/automation` lagged — went away with the
consolidation. `git status` now surfaces drift on the first edit.
The companion `check_branch_drift.ps1` was retired in the same
change. Recreate steps for a fresh machine live in
[`SECRETS.md`](SECRETS.md).

## Cross-project dependencies

`backup-monitor` depends on a sibling crate `d2d-ui` at
`C:\dev\Rust-DeskApp\crates\d2d-ui` (its README says so). When working
on backup-monitor, that sibling is part of the build graph; touching
its API can break this app.

## When to update this doc

- Any new binary or task added to the chain.
- Any new log surface or flag file.
- Any change to where the authoritative source for a question lives.
- Any change to the v1/v2 reality once `scripts/` is fully tracked or
  the gitignore is removed.
