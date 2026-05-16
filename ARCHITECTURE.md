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
| **Upstream `kopia.exe server`** | `C:\Users\david\go\bin\kopia.exe` (run by `\Backup\KopiaServer` Scheduled Task) | **Sole repository holder.** Long-running, started at boot via `scripts/start_kopia_server.ps1`. The launcher reads BOTH `.kopia-pw.dat` (→ `KOPIA_PASSWORD`, the repo encryption password) AND `.kopia-server-pw.dat` (→ `KOPIA_SERVER_PASSWORD`, HTTP basic auth) — Windows Credential Manager isn't reliably accessible from S4U / elevated split-token contexts. Server-side `--config-file` is `D:\KopiaServer\repository.config` (filesystem-mode, pointing at `D:\KopiaRepo` with absolute `cacheDirectory` so it works from anywhere); the API-mode config at `%APPDATA%\kopia\repository.config` is the *client* config used by everything else. Listens on `127.0.0.1:51515` with the stable TLS cert at `D:\KopiaServer\server.{crt,key}`. Emits a structured heartbeat line every 60s to `C:\dev\kopia\logs\heartbeat.log` (epic kopia-bcp). All other components (KopiaUI, `daily_kopia_backup.cmd`, manual `kopia.exe` invocations against `%APPDATA%\kopia\repository.config`) are REST clients of this process, never repo-direct. Runs Kopia's policy-driven maintenance internally — no other component should run `kopia maintenance run`. |
| `KopiaUI.exe`          | `C:\dev\kopia\dist\kopia-ui\win-unpacked\KopiaUI.exe`     | Electron desktop app (long-running tray process). Spawns a bundled `kopia.exe server` child (path: `…\resources\server\kopia.exe`) configured **as a client** of the upstream server above (post-cutover 2026-05-04 — `repository.config` is API-mode pointing at `https://127.0.0.1:51515` with the pinned cert fingerprint). The bundled child does NOT open the repo on disk — it's a stateless proxy serving KopiaUI's own UI. Maintenance failures used to surface here; they now come from the upstream server. |
| **`cicd/` pipeline**   | `C:\dev\kopia\cicd\*.ps1` + `Makefile.local.mk`           | Six-phase local CI/CD: `make release-and-deploy` chains diagnose → release (build+sign) → deploy-artifacts → deploy-tasks → deploy-config → smoke-test → toast. State at `cicd/.last-deploy`. See [`cicd/README.md`](cicd/README.md) and the design spec at [`docs/superpowers/specs/2026-05-05-cicd-pipeline-design.md`](docs/superpowers/specs/2026-05-05-cicd-pipeline-design.md). |
| **D: → E: replica** (kopia-7ar, kopia-8tn) | `scripts/daily_d_replica.ps1` (writer) + `E:\` target volume (Disk 3, ASMT 2235 USB-SATA enclosure, NTFS 64K-cluster, label `Replica-D`, 7.45 TB) | Daily VSS+rsync mirror of D: contents (kopia repo, wbadmin VHDX, primary user data) to E: so a future D: hardware failure has a recovery path. Two-phase architecture (kopia-8tn, Stage 1): VSS shadow of D: → mklink junction (rsync reads the junction natively via cygwin1.dll) → **Tree A** (`rsync --recursive --links --times --inplace --no-whole-file --delete-after`, excludes WindowsImageBackup/): all contents except wbadmin VHDXes → **Tree B** (`rsync --recursive --links --times --inplace --no-whole-file --delete-after --link-dest=<prior wbadmin dated folder>`): WindowsImageBackup/ only with explicit basis matching. The `--link-dest` pointer to yesterday's wbadmin dated folder enables `rsync` to detect unchanged VHDX blocks and hardlink them (zero disk cost); changed blocks transmit via rolling-hash delta algorithm. Expected outcome: wall time <90 min (vs 5–6 h baseline), transferred bytes <50 GB (vs ~1 TB baseline). Rsync.exe ships from cwRsync 6.4.8 ([itefixnet/cwrsync-client](https://github.com/itefixnet/cwrsync-client), BSD-2-Clause, pinned by SHA256, installed via `scripts/install_cwrsync.ps1` to `C:\cwrsync\`). Recovery-only: ACLs lock E:\ to `SYSTEM:F Administrators:F david:R`, only the elevated sync writes. The replicated `E:\KopiaRepo` is openable standalone with the same kopia password. Design plan: `C:\Users\david\.claude\plans\magical-cooking-jellyfish.md` (kopia-8tn multi-stage plan). |

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
| Is the upstream kopia server up?                    | **Heartbeat-line freshness in `C:\dev\kopia\logs\heartbeat.log`** (line every 60s, missing or >180s old → server is gone). Also: `schtasks /Query /TN "\Backup\KopiaServer"` (Status=Running), `netstat -ano \| findstr 127.0.0.1:51515` showing LISTENING, and `backup-dump.exe` STATUS CARDS row "Heartbeat: Xs ago". |
| Is a backup run actually progressing or hung?       | `heartbeat.log` ticks every 60s with active task list (`task=Snapshot:david@chrislaptop2:C:\dev,duration=Ns`). Wrapper's in-band guard (`scripts/heartbeat_watchdog.ps1`, kopia-bcp.3) kills the wrapper's kopia child if no tick for 180s. The 08:00 watchdog (`check_backup_health.ps1`) also flags STALL when in-progress + heartbeat stale. |
| What was the kopia exit code on a given night?      | `C:\dev\kopia\logs\daily_kopia.log` `Exit codes:` line for that run.                                              |
| Which files errored inside a snapshot?              | The matching `C:\Users\david\AppData\Local\kopia\cli-logs\kopia-*-snapshot-create.0.log`.                         |
| Did wbadmin run last night?                         | `wbadmin get versions` newest entry, plus `Microsoft-Windows-Backup` event log via `Get-WinEvent`.                |
| Was the daily wrapper invoked at all?               | `C:\dev\kopia\logs\daily_kopia.log` mtime + the `Daily Kopia backup start` marker.                                |
| Are there outstanding flagged failures?             | `C:\dev\kopia\logs\BACKUP_ERRORS.flag` and `BACKUP_HEALTH_FAIL.flag` and `WBADMIN_HEALTH_FAIL.flag`.               |
| Toast click target / how to open the dashboard?     | `kopiamonitor:` URL protocol, registered HKCU, points at `backup-monitor.exe` (see `register_backup_monitor_toast.ps1`). |
| "Kopia has encountered an error during Maintenance" toast appearing at odd hours? | Post-cutover: the upstream `\Backup\KopiaServer` task is running maintenance per repo policy. The toast is forwarded by KopiaUI (AppId `electron.app.KopiaUI`) because it subscribes to the upstream server's notification stream. Inspect `%APPDATA%\kopia-ui\logs\main.log` for the `NOTIFICATION` JSON, then check the `kopia-*-maintenance-*.log` under `%LOCALAPPDATA%\kopia\cli-logs\` (server-spawned) for the actual error. The pre-cutover "stale credentials in KopiaUI's bundled child" failure mode no longer applies. |
| Why does Find & Restore show no matches for a known file? | Compare newest mtime in `D:\BackupMonitorIndex\kopia-*.jsonl.gz` against today. If older than the latest snapshot, the indexer didn't run — find `[indexer]` lines in `daily_kopia.log`. |
| Did the last `make release-and-deploy` succeed?     | `cicd/.last-deploy` JSON: `verdict` is `success`/`failure`/`in_progress`; per-phase entries record status + duration + recommendedAction. The daily `\Backup\KopiaCicdHealthCheck` task surfaces failures via Windows toast under `KopiaBackup.HealthCheck`. |
| Is the D: → E: replica fresh and healthy?          | `backup-dump.exe` STATUS CARDS "Replica:" row (kopia-iwz). Underlying inputs: presence of `C:\dev\kopia\logs\BACKUP_REPLICA_FAIL.flag` (daily failed) **or** `C:\dev\kopia\logs\BACKUP_REPLICA_VERIFY_FAIL.flag` (weekly verify caught corruption) — either flag → Failed. Otherwise the verdict comes from the newest `replica summary` line in `daily_kopia.log`: PASS if errors=0 and ≤30 h old; STALE if no summary in 30 h. For "is the replica running RIGHT NOW", check `Get-Process robocopy` and tail `C:\dev\kopia\logs\daily_d_replica.log` for `[progress]` lines (one per minute while robocopy runs). |
| Did the weekly verify of E:\KopiaRepo pass?         | Newest `replica verify summary` line in `daily_kopia.log` — `errors=0` is PASS. `deferred=yes` means it skipped because daily was running concurrently (not a failure). Plus `BACKUP_REPLICA_VERIFY_FAIL.flag` for the sticky failure indicator. |

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
| `C:\dev\kopia\logs\heartbeat.log`                          | Upstream `kopia.exe server` (epic kopia-bcp) | One structured `[heartbeat] <RFC3339> uptime=<N>s tasks=<N> [task=...]*` line every 60s. Producer is the kopia server itself (`--heartbeat-interval=60s --heartbeat-file=...`). Consumed by `scripts/heartbeat_watchdog.ps1` (in-band stall guard during nightly), `check_backup_health.ps1` (out-of-band STALL detection), and `backup-monitor.exe` STATUS CARDS Heartbeat tile. Append-only; no rotation today (~110 KB/day at 60s cadence is negligible). |
| `C:\dev\kopia\logs\daily_d_replica.log`                    | `daily_d_replica.ps1` (kopia-30c, kopia-5ua) | One section per replica run: `[start]`, `[preflight]`, `[vss]` (shadow create + mklink mount), `[mirror]` (rsync invocation), `[progress]` lines emitted every 60s by a Start-Job watcher with `E:used=N write=NMB/s rsync_log=NKB idle=Ns` and a ` STALL` tag if neither signal advances for 600 s, then `[result]` and `[done]`. Rotates at 1 MB to `.old`. Plus `daily_d_replica.log.rsync` for rsync's own `--log-file` stream (`Number of files: ...`, `Total file size: ...`, etc.). |
| `C:\dev\kopia\logs\daily_kopia.log` (additional `replica summary` line) | `daily_d_replica.ps1` finally block | Each replica run appends one `replica summary source=D: target=E: bytes=N files=N errors=N duration_s=Ns mode=NORMAL\|INITIAL-SEED rsync_kopia_rc=N rsync_wbadmin_rc=N robocopy_rc=N link_dest_used=<path\|empty> shadow_id={...} tool=rsync` line. `backup-monitor`/`backup-dump` parse this to populate the Replica STATUS CARD (kopia-iwz). Post-kopia-5ua Split: Tree A (KopiaRepo) exit code → `rsync_kopia_rc`; Tree B (WindowsImageBackup with --link-dest basis) exit code → `rsync_wbadmin_rc`. `robocopy_rc` is the aggregate worst exit code (0/23/24 = pass, kept for backward compatibility). `link_dest_used` tracks whether an explicit `--link-dest=<prior-dated-folder>` basis was found; empty on first run (graceful fallthrough to whole-file copy). |
| `C:\dev\kopia\logs\daily_kopia.log` (additional `replica vhdx summary` line) | `weekly_replica_verify.ps1` scan block | Each weekly verify run appends one `replica vhdx summary checked=N valid=N invalid=N folder=<Backup YYYY-MM-DD HHMMSS\|empty> duration_s=N` line (after the kopia content verify summary). Runs Get-VHD + Test-VHD on the latest wbadmin dated folder on E: to catch silent VHDX corruption. `invalid > 0` promotes the overall verify to FAIL status. |
| `C:\dev\kopia\logs\daily_kopia.log` (additional `replica verify summary` line) | `weekly_replica_verify.ps1` finally block | Each weekly verify run appends one `replica verify summary errors=N sample_bytes=N duration_s=Ns deferred=yes\|no max_bytes=N parallel=N replica=E:\KopiaRepo` line. `deferred=yes` means a daily replica was running so verify skipped (not a failure). |
| `C:\dev\kopia\logs\weekly_replica_verify.log`              | `weekly_replica_verify.ps1` (kopia-ht4) | One section per verify run: `[start]`, `[preflight]`, `[connect]`, `[verify]`, `[disconnect]`, `[done]`. Rotates at 1 MB to `.old`. |
| `C:\dev\kopia\logs\BACKUP_REPLICA_FAIL.flag`               | `daily_d_replica.ps1` (kopia-30c, kopia-5ua) | Touched on any replica failure (preflight fail, VSS fail, rsync rc ∉ {0,23,24}). Removed on success. Sticky across runs until the next clean replica completes. Consumed by `backup-monitor.exe` STATUS CARDS Replica tile. |
| `C:\dev\kopia\logs\BACKUP_REPLICA_VERIFY_FAIL.flag`        | `weekly_replica_verify.ps1` (kopia-ht4) | Touched on any verify failure (kopia connect fail, content verify fail). Removed on PASS. Sticky across weeks until the next clean verify. Consumed alongside `BACKUP_REPLICA_FAIL.flag` by `backup-monitor.exe` STATUS CARDS Replica tile (either flag → Failed). |
| `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db` | Windows notification platform   | SQLite store of all delivered toasts (any AppId). Useful when investigating a mystery toast — see `reference_toast_debugging.md` memory or query `Notification` joined to `NotificationHandler.PrimaryId`. Default retention ~3 days. |

## Scheduled tasks (under `\Backup\`)

| Task name                  | Schedule        | Action                                                                                                  |
|----------------------------|-----------------|---------------------------------------------------------------------------------------------------------|
| `DailyKopiaSnapshotV2`     | Daily 03:00     | Runs `C:\dev\kopia\scripts\daily_kopia_backup.cmd` (v2 wrapper, RunLevel Highest, S4U logon).           |
| `KopiaBackupHealthCheck`   | Daily 08:00     | Runs `check_backup_health.ps1` (watchdog: did the daily run write a `snapshot summary` line?).          |
| `WbadminHealthCheck`       | Daily 08:05     | Runs `check_wbadmin_health.ps1` (wbadmin freshness via `wbadmin get versions` + Backup event log).      |
| `KopiaServer`              | At system startup, restart on failure (3×1min) | Runs `scripts/start_kopia_server.ps1` (S4U logon, RunLevel=HighestAvailable). Long-running upstream `kopia.exe server` on 127.0.0.1:51515 — the sole holder of `D:\KopiaRepo`. Emits the 60s heartbeat to `heartbeat.log`. See Components table. |
| `WeeklyBackupVerify`       | Weekly Sat 04:00| Runs `verify_backups.cmd` (`kopia snapshot verify` + content sample + full maintenance).                |
| `KopiaCicdHealthCheck`     | Daily 08:10     | Runs `cicd/toast-cicd-status.ps1 -Mode Surveillance` — reads `cicd/.last-deploy`, toasts under `KopiaBackup.HealthCheck` only on `verdict=failure` or run age >24h. Silent on fresh+green. Surfaces drift in the local CI/CD pipeline. |
| `DailyDReplica` (kopia-30c, kopia-5ua, kopia-7ar, kopia-8tn) | Daily 05:00     | Runs `scripts/daily_d_replica.ps1` to mirror D: → E: via VSS+rsync (cwRsync 6.4.8). Scheduled after both wbadmin (02:00) and the kopia snapshot (03:00) so D: is quiescent. `RunLevel=HighestAvailable` (VSS needs admin), `InteractiveToken` (toasts), `ExecutionTimeLimit=PT4H`. Task XML at `scripts/scheduled-tasks/DailyDReplica.xml`. Two-phase architecture (kopia-7ar): **Tree A** mirrors `D:\KopiaRepo` without basis matching (write-once semantics already limit changes). **Tree B** mirrors `D:\WindowsImageBackup` with explicit `--link-dest=<prior dated folder>` basis, providing concrete per-file matching. Unchanged blocks hardlink to prior folder (zero disk cost); changed blocks use rsync's rolling-hash delta algorithm. Both calls use `--inplace --no-whole-file --delete-after` to force delta semantics and preserve basis files. Expected outcome: <90 min wall time (vs 5–6 h baseline), <50 GB transferred (vs ~1 TB baseline). Pre-kopia-7ar used robocopy `/MIR` with whole-file copy; rsync with fuzzy matching attempted delta but had no concrete basis. |
| `WeeklyReplicaVerify` (kopia-ht4, kopia-8tn) | Weekly Sat 06:30 | Runs `scripts/weekly_replica_verify.ps1`. Connects to `E:\KopiaRepo` read-only via a dedicated `--config-file` (so it doesn't displace the default API-mode `repository.config`), runs `kopia content verify --max-bytes=1GB --parallel=4`, then disconnects. Catches silent corruption of the replica before D: actually dies. **VHDX validation** (kopia-8tn): After kopia content verify, scans the latest wbadmin dated folder on E: with `Get-VHD` (header+BAT check) and `Test-VHD` (full structural validation). Reports `replica vhdx summary checked=N valid=N invalid=N folder=... duration_s=N`. Invalid VHDXes promote overall verify to FAIL status. Defers (no failure) if a `daily_d_replica` rsync is currently running. Failures: `BACKUP_REPLICA_VERIFY_FAIL.flag` + toast under `KopiaBackup.HealthCheck` + `replica verify summary errors=N ...` + `replica vhdx summary invalid=...` lines in `daily_kopia.log`. Task XML at `scripts/scheduled-tasks/WeeklyReplicaVerify.xml`. |

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
5a. **Replica daily (kopia-30c):** `daily_d_replica.ps1`'s finally
    block emits a `KopiaBackup.HealthCheck` toast on FAIL only (silent
    on PASS, like the watchdogs above). The `BACKUP_REPLICA_FAIL.flag`
    is touched on FAIL, removed on PASS. The Replica STATUS CARD in
    `backup-monitor.exe`/`backup-dump.exe` reads the flag + the newest
    `replica summary` line in `daily_kopia.log` (kopia-iwz) and shows
    PASS/FAIL/STALE accordingly.
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

## Performance optimization landscape (backup-mirror)

Research compiled 2026-05-15 after a 5-hour torn-recovery WIB run exposed
how much wall time the current single-threaded full-hash-pass design costs.
This section is the authoritative inventory of available primitives. Treat
it as the menu when designing speedups; cite which option you're picking.

### NTFS change-detection primitives

Ranked by usefulness for our workload. All are documented Windows APIs
unless noted.

| Primitive | Granularity | Skips hash pass? | Stability | Notes |
|---|---|---|---|---|
| **`FSCTL_USN_TRACK_MODIFIED_RANGES` + `USN_RECORD_V4`** | byte ranges (≥64 MB rounded) | **Yes** | Win10/Server 2016+ stable | The big find. Plain NTFS, no Hyper-V. Per-file dirty extents. Reports over-round (~16× per chunk) but never under-reports — safe. See [[kopia-61n]]. |
| **USN journal V2/V3** | file | No (file-level only) | Win2K+ stable | Good outer filter: "did this file change since cursor X". `usn-journal-rs` crate. See [[kopia-1tr]]. |
| **`FSCTL_QUERY_ALLOCATED_RANGES`** | allocated byte ranges | partial (skips unallocated) | XP+ stable | For sparse VHDX. Strict improvement over `is_all_zero(buf)` post-read check. See [[kopia-dyj]]. |
| **`GetFileTime` LWT** | file | No | always | Free via `std::fs::Metadata`. Useful tertiary signal. |
| **`FILE_ATTRIBUTE_ARCHIVE`** | file | No | always | Contested with wbadmin (both clear it). Don't touch. |
| **VHDX RCT (`QueryChangesVirtualDisk`)** | byte ranges | Yes — *if RCT enabled* | Server 2016+ | Requires Hyper-V owned + RCT enabled at write. wbadmin output doesn't qualify. **Rejected for our case** (formerly tracked as kopia-44w, closed). |
| **`$MFT` / `$LogFile` direct read** | file (MFT) / none | No | undoc / unstable | Same info as `FSCTL_ENUM_USN_DATA`. Skip. |
| **VSS differential snapshot mgmt** | none (mgmt only) | No | stable | `IVssDifferentialSoftwareSnapshotMgmt` manages diff-area storage, doesn't expose `Diff(A, B)` to userspace. Skip. |
| **`ReadDirectoryChangesW`** | file | No (real-time only) | stable | Wrong semantics for "since last run". Skip. |
| **`FSCTL_LOOKUP_STREAM_FROM_CLUSTER`** | cluster→file | No | stable but slow | Docs explicitly warn "very resource-intensive". Forensic tool, not change-tracking. Skip. |

**Implementation order if optimizing the VHDX path**: (1) ALLOCATED_RANGES preflight for cheap win on sparse files → (2) USN V4 range tracking for the big win → (3) ignore RCT entirely.

### Parallelism opportunities

Disk envelope on the current host:
- **D:\\** (NVMe-ish, ~500-1000 MB/s sequential): tolerates QD≈4-8.
- **E:\\** (slower, ~150-200 MB/s sustained): seek-bound. Optimal QD=1-2 sequential, ~4 mixed. Multiple parallel readers *thrash* the head on a spindle.
- **CPU**: SHA-256 ~2 GB/s/core via `sha2` crate. We are I/O-bound, not CPU-bound. Multi-threaded hashing buys nothing.

Ranked by impact:

| Opportunity | Workload | Mechanism | Wall-clock win | Notes |
|---|---|---|---|---|
| **Intra-file rehash↔main pipeline** | cbt torn-recovery | `std::thread` + `crossbeam::channel(4)` | ~45% reduction | Two phases touch disjoint physical disks. See [[kopia-c90]]. |
| **File-level parallelism N=4** | blob mode (Tree-A) | `rayon::ThreadPool` | ~2x (Tree-A) | Stat+open latency dominates for small files. Restic/Kopia precedent. See [[kopia-0cj]]. |
| **File-level parallelism for cbt** | cbt mode (Tree-B) | — | **Negative** (-30 to -50%) | Multiple readers on the same E:\\ head thrash. Keep N=1 for cbt mode. |
| **Multi-threaded chunk hashing** | any | `rayon::par_iter` | None | Hashing not the bottleneck — 2.5× headroom over D:\\ throughput. Skip. |
| **Cross-file pipelining** (rehash of B during main of A) | cbt | — | **Negative** | Two concurrent E:\\ readers/writers thrash. Skip. |
| **`tokio::fs` async I/O** | any | tokio + windows-rs | None today | Tokio's `tokio::fs` is a blocking-stub thread pool, not IOCP. No payoff without independent QD demand. Defer. |
| **`ReadFileScatter` vectored I/O** | rehash on fragmented dst | windows-rs direct FFI | Marginal | Sequential reads already kernel-readahead-optimized. Defer. |
| **Process priority bump** | any | scheduled task `<Priority>5</Priority>` | ~2-3x measured | See [[kopia-8ag]] and `reference_taskscheduler_priority_default.md`. **Apply first** — biggest single bang for the buck. |

**What *not* to do**:
- Don't introduce tokio. No network I/O, no async I/O benefit, pure tax.
- Don't multi-thread chunk hashing — we're I/O-bound.
- Don't parallelize files in cbt mode — head contention erases the win.
- Don't bet on RCT — wrong API for wbadmin output.
- Don't write a minifilter driver — USN V4 obviates it.
- Don't use mmap on multi-TB files — see `reference_mmap_multi_tb_windows.md`.

Sources for both subsections live in the closed/in-progress bead histories
(`bd show kopia-44w`, `bd show kopia-61n`, etc.) — the research reports
themselves are linked from those bead notes.

## When to update this doc

- Any new binary or task added to the chain.
- Any new log surface or flag file.
- Any change to where the authoritative source for a question lives.
- Any change to the v1/v2 reality once `scripts/` is fully tracked or
  the gitignore is removed.
