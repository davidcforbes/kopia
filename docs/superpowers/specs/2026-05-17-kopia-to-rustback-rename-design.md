# Kopia → RustBack Rename — Design Spec

**Bead:** kopia-a4i.1 (parent epic kopia-a4i)
**Date:** 2026-05-17
**Status:** Design — awaiting user review

## 1. Context & decision

The product/stack is being rebranded from "Kopia"/"backup-monitor" to **RustBack**
(Rust Backup and Recovery on Windows). The `rustback` crate name on crates.io was
confirmed free 2026-05-17.

kopia-a4i.1 originally specified the rename be **sequenced after legacy-stack
retirement**, because renaming mid-cutover churns load-bearing surfaces (signing
config, scheduled-task XMLs, the URL protocol). On 2026-05-17 the owner **explicitly
overrode that sequencing**: the legacy kopia backup stack was disabled this session
(boot task, nightly job, health checks, KopiaUI auto-start all disabled), and the
owner elected to execute the full rename now, treating the disabled stack as dead.

This spec covers the **product identity** rename only. References to the legacy
**kopia tool itself** (the third-party Go binary `kopia.exe`, its repository and
server directories, its CLI invocations, its log format) remain "kopia" — that tool
is a real dependency RustBack monitors and will eventually replace.

## 2. Identity mapping

### 2.1 Changes (product identity)

| Surface | From | To |
|---|---|---|
| Cargo crate | `backup-monitor` | `rustback` |
| Binary: GUI | `backup-monitor` | `rustback-monitor` |
| Binary: control plane | `backup-server` | `rustback-server` |
| Binary: replica | `backup-mirror` | `rustback-mirror` |
| Binary: console dump | `backup-dump` | `rustback-dump` |
| Binary: search index | `backup-indexer` | `rustback-indexer` |
| Binary: tray | `backup-server-tray` | `rustback-tray` |
| Source dir | `C:\dev\backup-monitor` | `C:\dev\rustback` |
| GitHub repo | `davidcforbes/backup-monitor` | `davidcforbes/rustback` |
| Config dir | `C:\BackupServer` | `C:\RustBack` |
| Index dir | `D:\BackupMonitorIndex` | `D:\RustBackIndex` |
| URL protocol | `kopiamonitor:` | `rustback:` |
| Toast AppUserModelID (GUI) | `Forbes.BackupMonitor` | `RustBack.Monitor` |
| Toast AppId (health-check) | `KopiaBackup.HealthCheck` | `RustBack.HealthCheck` |
| Scheduled task: server | `\Backup\KopiaServer` | `\Backup\RustBackServer` |
| Scheduled tasks: wakers | `\Backup\BackupServerWaker-*` | `\Backup\RustBackWaker-*` |
| Win32 window class | `BackupMonitorWindow` | `RustBackWindow` |
| Win32 window title | `Backup Monitor — Forbes Asset Management` | `RustBack — Forbes Asset Management` |
| Manifest assembly name | `BackupMonitor` | `RustBack` |
| build.rs ProductName | `Backup Monitor` | `RustBack` |
| Icon asset | `assets/backup-monitor.ico` | `assets/rustback.ico` |
| exe manifest file | `backup-monitor.exe.manifest` | `rustback-monitor.exe.manifest` |

Scheduled-task **folder** `\Backup\` is kept (generic, not branding; lower risk —
non-RustBack tasks like `WbadminHealthCheck` also live there).

### 2.2 Rust types & identifiers (product surface — also renamed per 2026-05-17 owner decision)

The owner elected to rename the in-code `Kopia*` data types too. New names use
**`Snapshot`** as the neutral term for the file-tier dedup backup domain:

| From | To |
|---|---|
| `KopiaRun` | `SnapshotRun` |
| `KopiaSnapshot` | `Snapshot` |
| `KopiaLsEntry` | `SnapshotLsEntry` |
| `parse_kopia_log()` | `parse_snapshot_log()` |
| `list_kopia_snapshots()` | `list_snapshots()` |
| `parse_kopia_ls_line()` | `parse_ls_line()` |
| `open_kopia_detail()` | `open_snapshot_detail()` |
| `SearchSource::Kopia { .. }` | `SearchSource::Snapshot { .. }` |
| `kopia_table` (field / component / module) | `snapshot_table` |
| UI label "Kopia Backup History" | "Backup History" |
| UI label "Kopia Backup" (status card) | "File Backup" |
| UI label "Kopia Repo Size" | "Repo Size" |
| UI label "Kopia Files" | "Indexed Files" |

### 2.3 Explicitly NOT changed

- Legacy kopia tool: `kopia.exe`, `kopia snapshot restore`, `kopia ls`, the
  `--kopia` indexer CLI flag, `KOPIA_PASSWORD` env vars, `daily_kopia.log` parsing.
- Legacy tool directories: `D:\KopiaRepo`, `D:\KopiaServer`, the on-disk
  `KopiaRepo`/`KopiaServer` subtree names referenced in `replica.rs`.
- `C:\dev\kopia` repo — stays named `kopia` (it is the upstream-kopia fork).
- `D:\Recovery` folder name (generic DR cache; only the cached *filenames* change
  with the binary renames).
- Beads issue IDs in code comments (`kopia-0dr`, `kopia-iwz`, …) — issue-tracker
  references; renaming the beads prefix is a separate `bd rename-prefix` operation,
  out of scope here.
- Company name "Forbes Asset Management".

## 3. Repo scope

- **`rustback` repo** (renamed from `backup-monitor`): all Rust source, build.rs,
  manifest, Cargo.toml, README, icon.
- **`kopia` repo** (`C:\dev\kopia`, unchanged name): `scripts/`, `signing/`,
  `cicd/`, root docs — these are the Windows automation around the stack. Only
  their *contents* update (absolute paths + identity strings); the repo is not
  moved. Relocating them into the `rustback` repo is a separate architectural
  decision, out of scope for kopia-a4i.1.

## 4. Phased execution

Each phase is independently verifiable; a failure stops cleanly at a phase boundary.

### Phase 1 — `rustback` source repo (in `C:\dev\backup-monitor`, pre-dir-rename)

1. `Cargo.toml`: crate `name`, all six `[[bin]] name` entries.
2. `build.rs`: icon path, `ProductName`, `FileDescription`, manifest file name.
3. Rename `backup-monitor.exe.manifest` → `rustback-monitor.exe.manifest`; update
   assembly `name`.
4. Rename `assets/backup-monitor.ico` → `assets/rustback.ico`.
5. `src/server/toast.rs`: `LAUNCH_URI`, `APP_USER_MODEL_ID`, test assertions.
6. `src/main.rs`: window class, window title, `kopia_table` references.
7. `src/data.rs`: `INDEX_DIR` const → `D:\RustBackIndex`; `TRIGGER_TASK_PATH`;
   type renames per §2.2; UI strings.
8. `src/bin/{server,dump,indexer,mirror,tray}.rs`: help text, `C:\BackupServer`
   default config path → `C:\RustBack`, `D:\BackupMonitorIndex` default →
   `D:\RustBackIndex`, `launch_sibling("backup-monitor.exe")` →
   `"rustback-monitor.exe"`, type renames.
9. `src/components/`, `src/pages/`, `src/server_client.rs`, `src/server/`,
   `src/mirror/replica.rs`, `src/worker_contract.rs`: type renames, UI labels,
   test strings. Rename `src/components/kopia_table.rs` → `snapshot_table.rs`.
10. `README.md`: title, descriptions, binary table, paths.
11. **Verify:** `cargo build --release` produces `target/release/rustback-*.exe`
    (6 binaries); `cargo test` green; `cargo clippy` clean.
12. Commit on the `rustback` repo.

### Phase 2 — directory + GitHub rename

1. Ensure Phase 1 is committed and pushed.
2. Rename GitHub repo `backup-monitor` → `rustback` (`gh repo rename`).
3. Update the local git remote URL.
4. Close `C:\dev\backup-monitor` (no processes — stack is disabled), rename the
   directory to `C:\dev\rustback`.
5. **Verify:** `git -C C:\dev\rustback remote -v` resolves; `git fetch` works.

### Phase 3 — `kopia` repo: scripts / signing / cicd / docs

All edits update absolute paths (`C:\dev\backup-monitor` → `C:\dev\rustback`,
`C:\BackupServer` → `C:\RustBack`, `D:\BackupMonitorIndex` → `D:\RustBackIndex`),
binary names, the URL protocol, AppIds, and task names.

1. `scripts/*.ps1`, `scripts/*.cmd` (`daily_kopia_backup.cmd`,
   `run_indexer_backfill.cmd`, `daily_d_replica.ps1`, `weekly_replica_verify.ps1`,
   `post_summary_toast.ps1`, `start_kopia_server.ps1`, `check_backup_health.ps1`, …).
2. `scripts/register_backup_monitor_toast.ps1` → rename file to
   `register_rustback_toast.ps1`; update protocol, exe path, AppId, DisplayName.
3. `scripts/scheduled-tasks/*.xml`: binary paths, task names, descriptions.
   Rename the XML files to match new task names.
4. `signing/sign-all.ps1`: the target list (6 `rustback-*.exe` paths under
   `C:\dev\rustback\target\release\`, plus the renamed `.ps1` helpers).
5. `cicd/README.md`, `cicd/*.ps1`: AppId, exe names, protocol.
6. Docs: `ARCHITECTURE.md`, `architecture-vision.md`, `CLAUDE.md`, `AGENTS.md`,
   `SECRETS.md`, `oss-dev/SETUP.md`, `oss-dev/SECURITY.md`.
7. **Verify:** grep the `kopia` repo's stack files for residual `backup-monitor` /
   `kopiamonitor` / `BackupMonitorIndex` / `C:\dev\backup-monitor` — only legacy
   kopia-tool references remain.
8. Commit on `oss-dev`.

### Phase 4 — live system state

1. Move `D:\BackupMonitorIndex` → `D:\RustBackIndex`.
2. Move `C:\BackupServer` → `C:\RustBack` (carries `jobs.toml`, `state/`).
3. Unregister the `kopiamonitor:` URL protocol; register `rustback:` (via the
   renamed `register_rustback_toast.ps1`).
4. Delete the old scheduled tasks (`KopiaServer`, `BackupServerWaker-*`) and
   re-create them from the renamed XMLs as `RustBackServer` / `RustBackWaker-*`.
   **Created disabled** — the stack is intentionally off; the owner re-enables
   when ready.
5. Toast AppId registry keys: re-register under `RustBack.Monitor` /
   `RustBack.HealthCheck`.
6. **Verify:** new dirs exist with content; `Get-ScheduledTask` shows the renamed
   tasks present and Disabled; URL protocol registry key resolves to
   `rustback-monitor.exe`.

### Phase 5 — rebuild, re-sign, verify

1. `cargo build --release` in `C:\dev\rustback`.
2. Run `signing/sign-all.ps1` — signs the 6 `rustback-*.exe` + helper scripts,
   refreshes the `D:\Recovery` cache.
3. Delete stale `D:\Recovery\backup-*.exe` (superseded by `rustback-*.exe`).
4. **Verify:** sign-all reports "All signatures valid"; `D:\Recovery` holds the
   `rustback-*.exe` set; `rustback-monitor.exe` launches and the dashboard renders.
5. Commit any final artifacts; push both repos.

## 5. Rollback

- Phases 1, 3, 5 are git commits — revert normally.
- Phase 2 (dir + GitHub rename) — re-rename back; `gh repo rename` is reversible.
- Phase 4 — the directory moves are reversible (move back); scheduled tasks can be
  recreated from git-tracked XMLs; URL protocol/AppId re-registered. Because the
  stack is disabled, a partial Phase-4 state is not operationally dangerous.

## 6. Out of scope

- Renaming the `kopia` repo or relocating `scripts/`/`signing/`/`cicd/` into the
  `rustback` repo.
- Renaming the beads issue prefix (`kopia-*`).
- Any functional change — this is a pure rename; no behavior changes.
- Re-enabling the backup stack (owner decision, separate).

## 7. Acceptance

All new-stack binaries, crate, URL protocol, paths, scheduled tasks, signing
config, in-code types, and docs carry the RustBack identity. Remaining "kopia"
references only describe the legacy upstream kopia tool. Both repos build, sign,
and the dashboard launches.
