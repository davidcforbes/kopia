# Kopia → RustBack Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the product/stack identity from "Kopia"/"backup-monitor" to "RustBack" across the `backup-monitor` repo, the `kopia` repo's automation files, and live Windows system state.

**Architecture:** Pure rename, no behavior change. 5 phases with checkpoints: (1) source repo, (2) dir + GitHub rename, (3) kopia-repo scripts/signing/docs, (4) live system state, (5) rebuild + re-sign + verify.

**Tech Stack:** Rust (cargo workspace), PowerShell, Windows Task Scheduler, Azure Trusted Signing.

**Spec:** `docs/superpowers/specs/2026-05-17-kopia-to-rustback-rename-design.md`

---

## Master substitution reference

Apply these product-identity substitutions. **Order matters where noted.** All steps below reference this table.

| # | From | To |
|---|---|---|
| S1 | `backup-server-tray` | `rustback-tray` |
| S2 | `backup-server` | `rustback-server` |
| S3 | `backup-mirror` | `rustback-mirror` |
| S4 | `backup-dump` | `rustback-dump` |
| S5 | `backup-indexer` | `rustback-indexer` |
| S6 | `backup-monitor` (binary / exe / dir contexts) | `rustback-monitor` |
| S7 | `C:\dev\backup-monitor` | `C:\dev\rustback` |
| S8 | `C:\BackupServer` | `C:\RustBack` |
| S9 | `D:\BackupMonitorIndex` | `D:\RustBackIndex` |
| S10 | `BackupMonitorIndex` (bare) | `RustBackIndex` |
| S11 | `kopiamonitor:` | `rustback:` |
| S12 | `kopiamonitor` (protocol name, no colon) | `rustback` |
| S13 | `Forbes.BackupMonitor` | `RustBack.Monitor` |
| S14 | `KopiaBackup.HealthCheck` | `RustBack.HealthCheck` |
| S15 | `BackupServerWaker-` | `RustBackWaker-` |
| S16 | `BackupMonitorWindow` | `RustBackWindow` |
| S17 | `Backup Monitor` (product name) | `RustBack` |
| S18 | `KopiaRun` | `SnapshotRun` |
| S19 | `KopiaSnapshot` | `Snapshot` |
| S20 | `KopiaLsEntry` | `SnapshotLsEntry` |
| S21 | `parse_kopia_log` | `parse_snapshot_log` |
| S22 | `list_kopia_snapshots` | `list_snapshots` |
| S23 | `parse_kopia_ls_line` | `parse_ls_line` |
| S24 | `open_kopia_detail` | `open_snapshot_detail` |
| S25 | `SearchSource::Kopia` | `SearchSource::Snapshot` |
| S26 | `kopia_table` | `snapshot_table` |
| S27 | `"Kopia Backup History"` | `"Backup History"` |
| S28 | `"Kopia Backup"` | `"File Backup"` |
| S29 | `"Kopia Repo Size"` | `"Repo Size"` |
| S30 | `"Kopia Files"` | `"Indexed Files"` |

**Ordering rule:** apply S1 before S2 (so `backup-server-tray` is not partially hit by `backup-server`). Apply S9 before S10.

**DO NOT TOUCH — legacy kopia tool references (the word "kopia" is overloaded):**
`kopia.exe`, the `kopia ` CLI verb (`kopia snapshot restore`, `kopia ls`), `KOPIA_PASSWORD`/`KOPIA_SERVER_PASSWORD` env vars, `daily_kopia.log`, `C:\dev\kopia`, `D:\KopiaRepo`, `D:\KopiaServer`, the `KopiaRepo`/`KopiaServer` on-disk subtree names in `replica.rs`, the `--kopia` indexer CLI flag, and `kopia-*` beads issue IDs in comments. The scheduled task `\Backup\KopiaServer` IS renamed (Task 14) — but the `D:\KopiaServer` directory is not. When in doubt, inspect the surrounding line; do not blanket-`sed` the word "kopia".

---

## PHASE 1 — `rustback` source repo

Worktree: `C:\dev\backup-monitor` (still under the old dir name; renamed in Phase 2). All Phase 1 edits land in **one commit** — type renames (S18–S26) must be atomic crate-wide or the crate will not compile.

### Task 1: Cargo manifest, build script, manifest, icon

**Files:**
- Modify: `C:\dev\backup-monitor\Cargo.toml`
- Modify: `C:\dev\backup-monitor\build.rs`
- Rename + modify: `C:\dev\backup-monitor\backup-monitor.exe.manifest` → `rustback-monitor.exe.manifest`
- Rename: `C:\dev\backup-monitor\assets\backup-monitor.ico` → `assets\rustback.ico`

- [ ] **Step 1: Edit `Cargo.toml`**

Set the crate name and all six binary names:
```toml
[package]
name = "rustback"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "rustback-monitor"
path = "src/main.rs"

[[bin]]
name = "rustback-dump"
path = "src/bin/dump.rs"

[[bin]]
name = "rustback-indexer"
path = "src/bin/indexer.rs"

[[bin]]
name = "rustback-mirror"
path = "src/bin/mirror.rs"
```
And the two later `[[bin]]` blocks: `name = "rustback-server"` and `name = "rustback-tray"`. Leave the `kopia-0dr*` comment task IDs and all `[dependencies]` untouched.

- [ ] **Step 2: Rename the icon and manifest files**

Run:
```powershell
Move-Item C:\dev\backup-monitor\assets\backup-monitor.ico C:\dev\backup-monitor\assets\rustback.ico
Move-Item C:\dev\backup-monitor\backup-monitor.exe.manifest C:\dev\backup-monitor\rustback-monitor.exe.manifest
```

- [ ] **Step 3: Edit `build.rs`**

Replace lines 8–15 and 21–22 so they read:
```rust
        res.set_icon("assets/rustback.ico");
        res.set("ProductName", "RustBack");
        res.set("FileDescription", "RustBack — Forbes Asset Management");
        res.set("CompanyName", "Forbes Asset Management");
        res.set("LegalCopyright", "MIT licensed");
        // PerMonitorV2 DPI awareness via manifest so it takes effect before
        // the first HWND is created — see rustback-monitor.exe.manifest.
        res.set_manifest_file("rustback-monitor.exe.manifest");
```
```rust
    println!("cargo:rerun-if-changed=assets/rustback.ico");
    println!("cargo:rerun-if-changed=rustback-monitor.exe.manifest");
```

- [ ] **Step 4: Edit `rustback-monitor.exe.manifest`**

Change line 6 `name="BackupMonitor"` to `name="RustBack"`. In the comment at line 12, change `backup-monitor creates` to `rustback-monitor creates`.

(No commit yet — Phase 1 commits once at Task 8.)

### Task 2: `src/server/toast.rs`

**Files:**
- Modify: `C:\dev\backup-monitor\src\server\toast.rs`

- [ ] **Step 1: Edit the two constants**

Line 24: `const APP_USER_MODEL_ID: &str = "RustBack.Monitor";`
Line 28: `const LAUNCH_URI: &str = "rustback:";`

- [ ] **Step 2: Update the doc comments**

Lines 13–14 / 23: change `register_backup_monitor_toast.ps1` to `register_rustback_toast.ps1` and `kopiamonitor: protocol` to `rustback: protocol`. Leave the `kopia-0dr.20` task ID and the `kopia-file, kopia-block` worker codenames (those are bead/worker IDs).

- [ ] **Step 3: Update the test assertion**

Around line 231, the test asserting `launch="kopiamonitor:"` → `launch="rustback:"`.

(No commit yet.)

### Task 3: `src/data.rs`

**Files:**
- Modify: `C:\dev\backup-monitor\src\data.rs`

- [ ] **Step 1: Path constants**

Line 1456: `pub const INDEX_DIR: &str = r"D:\RustBackIndex";`
Line 2403 comment: `D:\BackupMonitorIndex\last-restore.log` → `D:\RustBackIndex\last-restore.log`.
Line 2465: `pub const TRIGGER_TASK_PATH: &str = r"\Backup\DailyKopiaSnapshotV2";` — **leave as-is** (that legacy task name is not in scope; the bead lists only `BackupServerWaker-*` and `KopiaServer`).

- [ ] **Step 2: Type renames**

Apply S18 (`KopiaRun`→`SnapshotRun`), S19 (`KopiaSnapshot`→`Snapshot`), S20 (`KopiaLsEntry`→`SnapshotLsEntry`), S21–S24 (function renames), S25 (`SearchSource::Kopia`→`SearchSource::Snapshot`) to every occurrence in this file.

- [ ] **Step 3: UI strings**

Apply S27–S30. Line 170 "Daily Kopia backup start" → "Daily backup start". The comment at line 1928 ("Kopia: one sidecar per latest-1 root oid") describes the kopia tool's output — leave it.

- [ ] **Step 4: Sibling-binary comments**

Lines 4, 1022: `backup-dump.exe`/`backup-monitor.exe` → `rustback-dump.exe`/`rustback-monitor.exe` (S4, S6).

(No commit yet.)

### Task 4: Binary entry points (`src/main.rs`, `src/bin/*.rs`)

**Files:**
- Modify: `C:\dev\backup-monitor\src\main.rs`
- Modify: `C:\dev\backup-monitor\src\bin\server.rs`
- Modify: `C:\dev\backup-monitor\src\bin\dump.rs`
- Modify: `C:\dev\backup-monitor\src\bin\indexer.rs`
- Modify: `C:\dev\backup-monitor\src\bin\mirror.rs`
- Modify: `C:\dev\backup-monitor\src\bin\tray.rs`

- [ ] **Step 1: `src/main.rs`**

Line 726: `wide("RustBackWindow")` (S16). Line 766: `wide("RustBack — Forbes Asset Management")` (S17). Apply S26 (`kopia_table`→`snapshot_table`) to the layout field and its references (lines 32, 42, 61–62, 67–68, 96).

- [ ] **Step 2: `src/bin/server.rs`**

Line 40 `about = "Backup pipeline control plane (kopia-0dr)"` — leave (`kopia-0dr` is a bead ID). Replace any `C:\BackupServer` default config path with `C:\RustBack` (S8). Leave `kopia-0dr*` comments.

- [ ] **Step 2b: `src/bin/dump.rs`**

Line 1 `//! Console dumper for the backup-monitor data module.` → `rustback` (S6). Line 2 `//! Prints parsed Kopia and wbadmin runs` → `//! Prints parsed snapshot and wbadmin runs`. Line 218 `println!("Kopia: ...")` → `println!("Backup: ...")`.

- [ ] **Step 3: `src/bin/indexer.rs`**

Line 37 `const DEFAULT_INDEX_DIR: &str = r"D:\RustBackIndex";` (S9). Line 226 help text `backup-indexer — build search indexes for backup-monitor` → `rustback-indexer — build search indexes for rustback` (S5, S6). Apply S18–S25 type renames. **Keep** the `--kopia` CLI flag and `// ── Kopia ──` section header context where it labels the kopia-tool data source — but the structs `KopiaSnapshot`/`KopiaLsEntry` and functions `list_kopia_snapshots`/`parse_kopia_ls_line` are renamed per S19/S20/S22/S23.

- [ ] **Step 3b: `src/bin/mirror.rs`**

Apply S10 to any `BackupMonitorIndex` exclusion-list entry.

- [ ] **Step 4: `src/bin/tray.rs`**

Line 445 `launch_sibling("backup-monitor.exe")` → `launch_sibling("rustback-monitor.exe")` (S6). Replace any `C:\BackupServer` path with `C:\RustBack` (S8).

(No commit yet.)

### Task 5: Library modules

**Files:**
- Modify: `C:\dev\backup-monitor\src\server_client.rs`
- Modify: `C:\dev\backup-monitor\src\http_client.rs`
- Modify: `C:\dev\backup-monitor\src\worker_contract.rs`
- Modify: `C:\dev\backup-monitor\src\mirror\replica.rs`
- Modify: `C:\dev\backup-monitor\src\pages\find_restore.rs`
- Modify: `C:\dev\backup-monitor\src\pages\dashboard.rs`
- Modify: `C:\dev\backup-monitor\src\components\status_cards.rs`
- Modify: `C:\dev\backup-monitor\src\components\table_paging.rs`
- Rename + modify: `C:\dev\backup-monitor\src\components\kopia_table.rs` → `snapshot_table.rs`

- [ ] **Step 1: Rename the component file**

Run:
```powershell
Move-Item C:\dev\backup-monitor\src\components\kopia_table.rs C:\dev\backup-monitor\src\components\snapshot_table.rs
```
Update the `mod kopia_table;` declaration (in `src/components/mod.rs` or `src/components.rs`) to `mod snapshot_table;` and any `use`/path references (S26).

- [ ] **Step 2: Type-rename the library modules**

Apply S18–S26 to `server_client.rs` (the `use crate::data::{KopiaRun,...}` import and `KopiaRun` usages at lines 138/141/144/198), `find_restore.rs` (`SearchSource::Kopia` pattern matches), `dashboard.rs`, and `snapshot_table.rs` (the `//! Kopia backup history table.` doc comment → `//! Backup history table.`, and the `draw_text("Kopia Backup History", ...)` → S27).

- [ ] **Step 3: UI labels in `status_cards.rs`**

Lines 83/97/104: apply S28 (`"Kopia Backup"`→`"File Backup"`), S29 (`"Kopia Repo Size"`→`"Repo Size"`), S30 (`"Kopia Files"`→`"Indexed Files"`).

- [ ] **Step 4: Comments / test strings**

`http_client.rs` line 18 sibling-binary comment list: `backup-dump, backup-monitor` → `rustback-dump, rustback-monitor`. `server_client.rs` lines 255/261/271/280 test assertions for `"backup-monitor"` → `"rustback-monitor"` (S6). `table_paging.rs` line 7 doc comment `backup-monitor's` → `rustback's`. `replica.rs`: leave `KopiaRepo`/`KopiaServer` subtree names (legacy tool dirs); apply S10 to `BackupMonitorIndex` exclusion entries at lines 27/688. `worker_contract.rs` line 270 `E:\KopiaRepo\p00.f` — leave (legacy repo path).

(No commit yet.)

### Task 6: `README.md`

**Files:**
- Modify: `C:\dev\backup-monitor\README.md`

- [ ] **Step 1: Title and branding**

Line 5 `<h1 align="center">Backup Monitor</h1>` → `RustBack` (S17). Line 8 subtitle: `Live dashboard for the kopia + wbadmin backup stack` — keep "kopia" (it names the tool monitored). Line 73 copyright: keep `© Forbes Asset Management`.

- [ ] **Step 2: Paths and binary table**

Line 41 `C:\dev\backup-monitor\` → `C:\dev\rustback\` (S7). Line 54 binary table `backup-monitor.exe` and the other five exe rows → `rustback-*` names (S1–S6). Line 62 `D:\BackupMonitorIndex` → `D:\RustBackIndex` (S9). Lines 65–66 `--kopia` flag examples — keep.

(No commit yet.)

### Task 7: Crate-wide residual sweep

**Files:** all of `C:\dev\backup-monitor\src\`

- [ ] **Step 1: Grep for missed product-identity strings**

Run (from `C:\dev\backup-monitor`):
```powershell
rg -n "backup-monitor|backup-server|backup-mirror|backup-dump|backup-indexer|BackupMonitorIndex|kopiamonitor|Forbes\.BackupMonitor|BackupMonitorWindow|KopiaRun|KopiaSnapshot|KopiaLsEntry|kopia_table|parse_kopia_log" src Cargo.toml build.rs
```
Expected: no matches except inside `kopia-0dr*` bead-ID comments. Fix any real product-identity miss by applying the matching substitution.

### Task 8: Build, test, commit Phase 1

- [ ] **Step 1: Build**

Run: `cargo build --release` in `C:\dev\backup-monitor`.
Expected: success; `target\release\` contains `rustback-monitor.exe`, `rustback-server.exe`, `rustback-mirror.exe`, `rustback-dump.exe`, `rustback-indexer.exe`, `rustback-tray.exe`.

- [ ] **Step 2: Test**

Run: `cargo test`.
Expected: all tests pass (including the toast `launch="rustback:"` assertion and the `server_client.rs` arg-parsing tests).

- [ ] **Step 3: Clippy**

Run: `cargo clippy --release`.
Expected: no new warnings.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "rename: Kopia/backup-monitor -> RustBack (source repo, kopia-a4i.1)"
```

---

## PHASE 2 — directory + GitHub rename

### Task 9: Push Phase 1, rename GitHub repo, update remote

- [ ] **Step 1: Push Phase 1**

Run (in `C:\dev\backup-monitor`): `git push`.
Expected: Phase 1 commit lands on the remote.

- [ ] **Step 2: Rename the GitHub repo**

Run: `gh repo rename rustback --repo davidcforbes/backup-monitor`.
Expected: `✓ Renamed repository davidcforbes/rustback`.

- [ ] **Step 3: Update the local remote URL**

Run (in `C:\dev\backup-monitor`):
```powershell
git remote set-url origin https://github.com/davidcforbes/rustback.git
git remote -v
```
Expected: origin shows `.../rustback.git`.

### Task 10: Rename the local directory

- [ ] **Step 1: Confirm no processes hold the directory**

Run: `Get-Process | Where-Object { $_.Path -like 'C:\dev\backup-monitor\*' }`
Expected: no output (the stack is disabled). If any appear, stop them first.

- [ ] **Step 2: Rename the directory**

Run: `Move-Item C:\dev\backup-monitor C:\dev\rustback`.

- [ ] **Step 3: Verify**

Run (in `C:\dev\rustback`): `git -C C:\dev\rustback status` and `git -C C:\dev\rustback fetch`.
Expected: clean status, fetch succeeds against `rustback.git`.

---

## PHASE 3 — `kopia` repo: scripts / signing / cicd / docs

Worktree: `C:\dev\kopia`, branch `oss-dev`. One commit at the end (Task 16).

### Task 11: `scripts/` PowerShell and CMD files

**Files (modify):** `scripts\daily_kopia_backup.cmd`, `scripts\run_indexer_backfill.cmd`, `scripts\daily_d_replica.ps1`, `scripts\weekly_replica_verify.ps1`, `scripts\post_summary_toast.ps1`, `scripts\start_kopia_server.ps1`, `scripts\check_backup_health.ps1`, `scripts\push_and_pr_kopia.sh`

- [ ] **Step 1: Apply path + binary substitutions**

In each file apply S7 (`C:\dev\backup-monitor`→`C:\dev\rustback`; also the forward-slash form `C:/dev/backup-monitor`→`C:/dev/rustback` in `push_and_pr_kopia.sh` line 315), S1–S6 (binary names, e.g. `backup-indexer.exe`→`rustback-indexer.exe`, `backup-mirror.exe`→`rustback-mirror.exe`), S9 (`D:\BackupMonitorIndex`→`D:\RustBackIndex`).

- [ ] **Step 2: Apply protocol + AppId substitutions**

S11/S12 (`kopiamonitor:`→`rustback:`), S14 (`KopiaBackup.HealthCheck`→`RustBack.HealthCheck`). Keep `daily_kopia.log`, `C:\dev\kopia\logs`, and `kopia.exe`/`kopia ` CLI references.

- [ ] **Step 3: Verify (no commit yet)**

Run (from `C:\dev\kopia`): `rg -n "backup-monitor|C:.dev.backup-monitor|kopiamonitor|KopiaBackup\.HealthCheck|D:.BackupMonitorIndex" scripts`
Expected: no matches except legacy-tool references.

### Task 12: `register_backup_monitor_toast.ps1` rename

**Files:**
- Rename + modify: `scripts\register_backup_monitor_toast.ps1` → `scripts\register_rustback_toast.ps1`

- [ ] **Step 1: Rename the file**

Run: `git -C C:\dev\kopia mv scripts/register_backup_monitor_toast.ps1 scripts/register_rustback_toast.ps1`

- [ ] **Step 2: Edit contents**

Apply S6 (exe path/name), S7 (dir), S11/S12 (protocol `kopiamonitor`→`rustback`), S14 (AppId). Line 13 DisplayName `'Backup Monitor'` → `'RustBack'` (S17).

### Task 13: `signing/` and `cicd/`

**Files (modify):** `signing\sign-all.ps1`, `cicd\README.md`, `cicd\diagnose-signing.ps1`, `cicd\deploy-artifacts.ps1`, `cicd\deploy-tasks.ps1`, `cicd\toast-cicd-status.ps1`

- [ ] **Step 1: `signing/sign-all.ps1` target list**

In the `$targets` array (lines ~71–85), replace the six binary paths under `C:\dev\backup-monitor\target\release\` with `C:\dev\rustback\target\release\rustback-*.exe` (S1–S7). The `$repo` variable stays `C:\dev\kopia`. Keep `C:\Users\david\go\bin\kopia.exe` (legacy tool). The helper-script `.ps1` paths stay (Phase-3 renames only `register_*` — update that one entry to `register_rustback_toast.ps1`).

- [ ] **Step 2: `cicd/` files**

Apply S6 (exe names), S11/S12 (protocol), S14 (AppId), S7 (dir paths) to each cicd file.

- [ ] **Step 3: Verify (no commit yet)**

Run: `rg -n "backup-monitor|kopiamonitor|KopiaBackup\.HealthCheck" signing cicd`
Expected: no matches.

### Task 14: Scheduled-task XML files

**Files:** all `*.xml` in `scripts\scheduled-tasks\`

- [ ] **Step 1: Edit and rename the waker tasks**

For `BackupServerWaker-Kopia.xml`, `BackupServerWaker-Replica.xml`, `BackupServerWaker-WeeklyBackupVerify.xml`, `BackupServerWaker-WeeklyReplicaVerify.xml`: inside each, apply S2/S7 to the `<Command>`/`<Arguments>` (`C:\dev\backup-monitor\target\release\backup-server.exe` → `C:\dev\rustback\target\release\rustback-server.exe`), and S8 (`C:\BackupServer`→`C:\RustBack`) in any `--config` argument. Then `git mv` each file applying S15 (`BackupServerWaker-`→`RustBackWaker-`).

- [ ] **Step 2: Edit and rename `KopiaServer.xml`**

Inside: the `<Command>`/`<Arguments>` invoke `start_kopia_server.ps1` — leave that script path (it is the kopia-tool launcher). `git mv scripts/scheduled-tasks/KopiaServer.xml scripts/scheduled-tasks/RustBackServer.xml`.

- [ ] **Step 3: Other task XMLs**

For `DailyDReplica.xml`, `DailyKopiaSnapshotV2.xml`, `WeeklyReplicaVerify.xml`, `WeeklyBackupVerify.xml`, `KopiaBackupHealthCheck.xml`, `KopiaCicdHealthCheck.xml`, `WbadminHealthCheck.xml`: apply S2/S6/S7 to any binary path inside, and S14 to any AppId. **Do not rename** these files (their task names are out of the bead's `BackupServerWaker-*`/`KopiaServer` scope).

- [ ] **Step 4: Verify (no commit yet)**

Run: `rg -n "C:.dev.backup-monitor|backup-server\.exe|backup-monitor\.exe" scripts/scheduled-tasks`
Expected: no matches.

### Task 15: Documentation

**Files (modify):** `ARCHITECTURE.md`, `architecture-vision.md`, `CLAUDE.md`, `AGENTS.md`, `SECRETS.md`, `oss-dev\SETUP.md`, `oss-dev\SECURITY.md`

- [ ] **Step 1: Apply substitutions**

Apply S1–S17 across these docs: binary names, `C:\dev\backup-monitor`→`C:\dev\rustback`, `C:\BackupServer`→`C:\RustBack`, `D:\BackupMonitorIndex`→`D:\RustBackIndex`, `kopiamonitor:`→`rustback:`, AppIds, `BackupServerWaker-*`→`RustBackWaker-*`, product name "Backup Monitor"→"RustBack". In `SECRETS.md` keep `D:\KopiaRepo`/`D:\KopiaServer` (legacy tool dirs). In `CLAUDE.md` keep the `kopia` repo references, the `/c/dev/backup-monitor/...backup-dump.exe` path becomes `/c/dev/rustback/target/release/rustback-dump.exe`.

- [ ] **Step 2: Verify (no commit yet)**

Run: `rg -n "backup-monitor\.exe|C:.dev.backup-monitor|kopiamonitor:" ARCHITECTURE.md architecture-vision.md CLAUDE.md AGENTS.md SECRETS.md oss-dev`
Expected: no matches.

### Task 16: Commit Phase 3

- [ ] **Step 1: Whole-repo residual grep**

Run (from `C:\dev\kopia`, excluding the upstream Go tree, `.beads/`, and `docs/superpowers/specs/2026-05-17-kopia-to-rustback-rename-design.md` which intentionally records old names):
```powershell
rg -n "backup-monitor|C:.dev.backup-monitor|kopiamonitor|BackupMonitorIndex|Forbes\.BackupMonitor" scripts signing cicd ARCHITECTURE.md architecture-vision.md CLAUDE.md AGENTS.md SECRETS.md oss-dev
```
Expected: no matches.

- [ ] **Step 2: Commit**

```bash
git add -A
git commit -m "rename: Kopia/backup-monitor -> RustBack (scripts, signing, cicd, docs; kopia-a4i.1)"
```

---

## PHASE 4 — live system state

### Task 17: Move the data directories

- [ ] **Step 1: Move the index dir**

Run: `Move-Item D:\BackupMonitorIndex D:\RustBackIndex`
Expected: `D:\RustBackIndex` exists with the prior index content.

- [ ] **Step 2: Move the config/state dir**

Run: `Move-Item C:\BackupServer C:\RustBack`
Expected: `C:\RustBack\jobs.toml` and `C:\RustBack\state\` exist.

- [ ] **Step 3: Verify**

Run: `Test-Path D:\RustBackIndex, C:\RustBack\jobs.toml`
Expected: both `True`.

### Task 18: Re-register the URL protocol and toast AppIds

- [ ] **Step 1: Remove the old protocol**

Run: `Remove-Item 'HKCU:\SOFTWARE\Classes\kopiamonitor' -Recurse -Force -ErrorAction SilentlyContinue`

- [ ] **Step 2: Register the new protocol**

Run: `pwsh -NoProfile -ExecutionPolicy Bypass -File C:\dev\kopia\scripts\register_rustback_toast.ps1`
Expected: the script reports success.

- [ ] **Step 3: Verify**

Run: `Get-ItemProperty 'HKCU:\SOFTWARE\Classes\rustback\shell\open\command' -ErrorAction SilentlyContinue`
Expected: the command resolves to `rustback-monitor.exe` under `C:\dev\rustback\target\release\`.

### Task 19: Recreate the scheduled tasks (disabled)

- [ ] **Step 1: Delete the old tasks**

Run:
```powershell
foreach ($t in 'KopiaServer','BackupServerWaker-Kopia','BackupServerWaker-Replica','BackupServerWaker-WeeklyBackupVerify','BackupServerWaker-WeeklyReplicaVerify') {
  schtasks /Delete /TN "\Backup\$t" /F
}
```
Expected: each reports `SUCCESS`.

- [ ] **Step 2: Register the renamed tasks from the updated XMLs**

Run:
```powershell
schtasks /Create /TN "\Backup\RustBackServer" /XML C:\dev\kopia\scripts\scheduled-tasks\RustBackServer.xml /F
foreach ($t in 'Kopia','Replica','WeeklyBackupVerify','WeeklyReplicaVerify') {
  schtasks /Create /TN "\Backup\RustBackWaker-$t" /XML "C:\dev\kopia\scripts\scheduled-tasks\RustBackWaker-$t.xml" /F
}
```
Expected: each reports `SUCCESS`.

- [ ] **Step 3: Disable all five (stack is intentionally off)**

Run:
```powershell
foreach ($t in 'RustBackServer','RustBackWaker-Kopia','RustBackWaker-Replica','RustBackWaker-WeeklyBackupVerify','RustBackWaker-WeeklyReplicaVerify') {
  schtasks /Change /TN "\Backup\$t" /DISABLE
}
```

- [ ] **Step 4: Verify**

Run: `schtasks /Query /FO TABLE /NH | Select-String 'RustBack'`
Expected: five `RustBack*` tasks listed, all `Disabled`.

---

## PHASE 5 — rebuild, re-sign, verify

### Task 20: Build and sign

- [ ] **Step 1: Release build**

Run (in `C:\dev\rustback`): `cargo build --release`
Expected: six `rustback-*.exe` in `target\release\`.

- [ ] **Step 2: Sign**

Run: `pwsh -NoProfile -ExecutionPolicy Bypass -File C:\dev\kopia\signing\sign-all.ps1`
Expected: ends with `All signatures valid.` listing the six `rustback-*.exe` and the helper `.ps1` files; `D:\Recovery` cache refreshed.

- [ ] **Step 3: Remove stale recovery-cache binaries**

Run:
```powershell
Remove-Item D:\Recovery\backup-monitor.exe,D:\Recovery\backup-server.exe,D:\Recovery\backup-mirror.exe,D:\Recovery\backup-dump.exe,D:\Recovery\backup-indexer.exe,D:\Recovery\backup-server-tray.exe -ErrorAction SilentlyContinue
```
Expected: `D:\Recovery` now holds the `rustback-*.exe` set plus `kopia.exe`.

### Task 21: Smoke-test and finalize

- [ ] **Step 1: Launch the dashboard**

Run: `C:\dev\rustback\target\release\rustback-monitor.exe`
Expected: window titled "RustBack — Forbes Asset Management" opens; dashboard renders; close it.

- [ ] **Step 2: Console dump sanity check**

Run: `C:\dev\rustback\target\release\rustback-dump.exe`
Expected: runs without error (it reads `D:\RustBackIndex` / parsed logs).

- [ ] **Step 3: Push both repos**

Run: `git -C C:\dev\rustback push` and `git -C C:\dev\kopia push`.
Expected: both push cleanly (the `kopia` pre-push signing hook passes — Task 20 just signed).

- [ ] **Step 4: Close the bead**

Run:
```bash
bd update kopia-a4i.1 --status closed
bd comment kopia-a4i.1 "RustBack rename complete 2026-05-18. All 5 phases done: rustback crate + 6 rustback-* binaries, repo+dir renamed to rustback, kopia-repo scripts/signing/cicd/docs updated, live dirs moved (D:\\RustBackIndex, C:\\RustBack), rustback: URL protocol registered, 5 RustBack* scheduled tasks recreated (disabled), binaries rebuilt + signed. Legacy kopia-tool references intentionally preserved."
```

---

## Self-review notes

- **Spec coverage:** §2.1 mapping → Tasks 1–4, 11–15; §2.2 type renames → Tasks 3–5; §2.3 "not changed" → enforced by the "DO NOT TOUCH" rule and per-task callouts; §4 phases → Tasks 1–21 grouped by phase; §5 rollback → each phase is a git commit / reversible move.
- **`TRIGGER_TASK_PATH` (`\Backup\DailyKopiaSnapshotV2`)** is deliberately left unchanged (Task 3 Step 1) — that task name is outside the bead's stated `BackupServerWaker-*`/`KopiaServer` scope; the matching XML is path/binary-updated but not file-renamed (Task 14 Step 3).
- **Atomicity:** Phase 1 type renames (S18–S26) span many files and must compile together — Phase 1 is therefore one commit (Task 8), verified by `cargo build`/`test`/`clippy`.
