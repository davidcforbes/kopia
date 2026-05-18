# RustBack Backup Server — Architecture Blueprint & Completion Roadmap

## Context

The `kopia-0dr` epic ("Backup Server — headless orchestrator") is **34/46 children
complete (73%)**. The control plane (`rustback-server`) is production-grade: DAG
runner, cron gating, retry, subprocess supervision with Windows Job Objects,
stall-watch, SQLite+JSONL state, a loopback REST API, and a shared
`worker_contract` module all shipped and tested. The first native worker
(`rustback-mirror replica`, sub-project 1) is built and is the proven template.

**11 beads remain.** This document does two things:
**(A)** synthesizes the architectural patterns and software-design approach into a
single blueprint every remaining worker/module must follow, and **(B)** sequences
the 11 open beads into a dependency-ordered completion roadmap.

This is a **planning/research deliverable** — it determines *how* to finish the
epic. It does not itself change code. Bead text predates the 2026-05-18
Kopia→RustBack rename; this doc uses the current `rustback-*` names.

Authoritative design sources (already in-repo, this doc synthesizes them):
- `architecture-vision.md` §5 (topology), §6 (rustic_core/metadata), §9 (decision log)
- `docs/superpowers/specs/2026-05-17-native-worker-cutover-roadmap-design.md`
- `docs/superpowers/plans/2026-05-17-subproject-0-stabilization.md`

---

## PART A — Worker Architecture Blueprint

### A1. The three-plane model (hard boundaries)

```
UI plane       rustback-monitor.exe — GUI + tray (interactive session)
                  │  HTTP/REST (loopback 127.0.0.1:51516)
Control plane  rustback-server.exe — headless Service: scheduler, DAG, state,
               catalog/index module, run-status module
                  │  worker contract (spawn / JSONL / exit code)
Worker plane   rustback-mirror.exe · rustback-filecopy.exe · rustback-blockcopy.exe
               — separate signed, supervised processes
```

Invariants (architecture-vision §5.1): **UI never talks to workers. Workers never
talk to UI. State lives only in the control plane.**

### A2. Process-vs-module rule (decision #9)

- **Data-plane work → a separate supervised process** (a worker). A worker crash,
  leak, or hang must not take down the control plane.
- **Control-plane logic → a module inside `rustback-server`** (catalog/index,
  run-status). The server stays *data-blind*: workers read repos and produce data;
  the server catalogs and serves it but never opens a repo itself.
- Target topology is **5 executables**: `rustback-server`, `rustback-monitor`,
  `rustback-mirror`, `rustback-filecopy`, `rustback-blockcopy`. `rustback-dump`,
  `rustback-indexer`, `rustback-tray` are retired *into* modules of the first two.

### A3. The worker contract (the single most important pattern)

Defined in `C:\dev\rustback\src\worker_contract.rs` — **shared** by every worker
and the server. A new worker MUST:

| Aspect | Contract |
|---|---|
| **Invocation** | Server spawns it inside a Windows Job Object (kill-on-close → whole process tree dies on timeout/stall). Args on the command line. No REST callbacks. |
| **Events (stderr)** | Emit `Event` records as JSONL, one per line: `{"type":"progress",...}`, `heartbeat`, `summary`, `error`. Worker emits `run_id=0, job=""`; the server stamps real identity via `inject_identity`. Use `worker_contract::ProgressReporter` (interval-based) + `emit_heartbeat(phase)` for long no-op phases. |
| **Summary (stdout)** | One plain-text line: `<tool> summary key=value key=value …`. The server reverse-scans stdout for ` summary `. |
| **Exit codes** | `0` = clean, `23` = partial (some files errored, run continued — rsync convention), `1` = hard failure. Server adds `124` = Killed. |
| **Liveness** | Only `Progress` and `Heartbeat` count as liveness. A `Structured` worker MUST emit ≥1 `Progress` per run or the server logs a contract error. |
| **Never** | A worker must not swallow failures silently and must never write to the orchestration log — that is the server's job. |

Server side that consumes it: `src/server/worker.rs::run_worker` (spawn, tee
stdout/stderr, timeout, stall-watch), `src/server/scheduler.rs` (DAG, cron, retry).

### A4. The native-worker template (proven by `rustback-mirror replica`)

Every new worker is a **`clap` subcommand** structured in phases, modeled on
`src/mirror/replica.rs::run` (sub-project 1):

1. **Preflight** — capacity / heartbeat / privilege gates; hard-fail early.
2. **Resource acquisition** — VSS shadow via `src/mirror/vss.rs` (`create_shadow`
   returns a `ShadowHandle` whose `Drop` tears the shadow down on *every* exit
   path; `reconcile_orphans` sweeps shadows from prior killed runs).
3. **Work loop** — emit `Heartbeat` at phase boundaries, `Progress` on cadence.
4. **Summary + flags** — write the `summary` line; set/clear `BACKUP_*_FAIL.flag`.
5. **Teardown** — RAII `Drop` releases the shadow (bounded subprocess, 120s cap).

Reusable primitives already built (do not reimplement): chunk-CBT engine +
`.cbt.ok` markers + manifest (`src/mirror/cbt.rs`, `manifest.rs`), sparse-range
skip (`sparse.rs`), USN journal engine (`src/mirror/usn.rs`), atomic
tmpfile+fsync+rename for all stateful writes.

### A5. The build → eval → cutover gate (per worker)

From the cutover-roadmap spec §4 — the **accelerated** model:

1. Build the worker; synthetic-fixture tests pass.
2. **One** parallel-eval run (legacy + native side-by-side; diff outputs).
3. **Cut over immediately** — flip the `jobs.toml` job `command`; the native
   worker becomes the primary scheduled path.
4. Legacy script stays **on-disk and manually runnable** as a fallback — *not
   scheduled, not deleted*.
5. Move to the next sub-project; delete the legacy script only when the operator
   is explicitly confident.

Eval method differs by data tier:
- **Replica / block (.33, .40)** — byte-compare: legacy and native produce the
  same destination tree, directly diffable.
- **File tier (.39)** — *restore-level* eval, NOT byte-compare (per kopia-0dr.35):
  `rustic_core` writes restic format, incompatible with the kopia repo. Verify via
  round-trip (snapshot→restore→diff incl. Windows metadata), dual-snapshot
  equivalence, and the real `restic` tool as an independent oracle.

### A6. Constraints — what NOT to do (architecture-vision §4, ARCHITECTURE.md §8)

- No `tokio`/async — pure tax here; the stack is `std::thread` + `crossbeam::channel`.
- No multi-threaded chunk hashing — I/O-bound, SHA-256 has 2.5× headroom.
- No file-level parallelism in CBT mode — head contention costs −30–50%.
- No Hyper-V RCT — wrong API; use `FSCTL_USN_TRACK_MODIFIED_RANGES` + `USN_RECORD_V4`.
- No `mmap` on multi-TB files — working-set blows up.
- No magic-string log parsing as a coordination channel — the contract eliminates it.
- Server identity = the `david` account, **not LocalSystem** — `wbadmin` DENY ACEs
  on `E:\` lock out SYSTEM too; workers inherit the server token.

---

## PART B — Completion Roadmap (11 open beads)

Sequenced into three tiers. Effort = rough build size, not calendar time.

### Tier 1 — Finish what's in flight (P0, no new design)

| Bead | What | Effort | Notes |
|---|---|---|---|
| **kopia-0dr.33** | `rustback-mirror replica` — finish eval + cut over | Small | Code done. Gated on: signed `rustback-mirror.exe` (now unblocked post-rename + re-sign) and accepting that torn-recovery makes the first real run safe (E:'s `.cbt.ok` markers were wiped by the eval). Then flip `jobs.toml` `replica_d_to_e` command + retire `daily_d_replica.ps1` to on-disk fallback. |
| **kopia-0dr.4** | Phase 1.3 cutover — 14-night soak | Passive | Orchestration cutover already executed (legacy tasks disabled, wakers created — now `RustBackWaker-*`). Just needs 14 clean nightlies with `rustback-dump` STATUS CARDS green, then delete the disabled legacy tasks + archive XMLs. **Note:** the backup stack is currently *intentionally disabled* (see memory `project-kopia-autostart-disabled`) — the soak clock is paused until the operator re-enables. |

Tier 1 is the prerequisite gate: do not start net-new workers (Tier 3) until the
orchestration + first worker are proven in production.

### Tier 2 — Control-plane / UI consolidation (P2–P3, follows existing patterns, low design risk)

These are module extractions and a launch-model upgrade — no new external data
formats, all within `rustback-server`/`rustback-monitor`.

| Bead | What | Effort | Sequencing |
|---|---|---|---|
| **kopia-0dr.45** | `rustback-server` as a self-installing Windows Service (`install`/`uninstall` subcommands, SCM `ServiceMain` + control handler, logon = `david`) | Medium | After .4's soak proves the orchestration. Supersedes `RustBackWaker-*` tasks. Service mode skeleton already partly present in `src/bin/server.rs` (Ctrl+C handler, heartbeat thread, HTTP serve loop). |
| **kopia-0dr.43** | Retire `rustback-dump.exe` → run-status module in `rustback-server` + a `rustback-server status` CLI subcommand (preserves CLAUDE.md Rule 1's fast verdict) | Medium | Independent; can run parallel with .45. The STATUS CARDS verdict logic moves from `dump.rs` into a server module reading SQLite+JSONL state. |
| **kopia-0dr.42** | Retire `rustback-indexer.exe` → catalog/index module in `rustback-server` | Medium-Large | Two-step: (1) fold the existing kopia/wbadmin indexer logic now; (2) adapt the file-list intake to consume `rustback-filecopy`'s snapshot-walk output once .39 lands. Index storage stays `D:\RustBackIndex` (recovery infra). |
| **kopia-0dr.27** | `rustback-monitor` per-step progress + event-stream view (consume `GET /api/runs/{id}` + `/api/events`) | Small-Medium | Blocker (.26) is done. Direct2D UI work only. Per-step progress only populates for *structured* workers — fully meaningful once Tier-3 workers emit `Event::Progress`. |
| **kopia-0dr.44** | Retire `rustback-tray.exe` → tray icon folds into `rustback-monitor` (must run in the interactive session) | Small | P3. Lowest priority; do last in this tier. |

### Tier 3 — Net-new native workers (P2–P3, each needs its OWN brainstorm + spec)

Strict serial order per the cutover roadmap (2→3→4→5). Each is a multi-week build;
**each gets its own `superpowers:brainstorming` → spec → plan cycle** — this
roadmap does not pre-design them.

| Bead | Sub-project | Retires | Effort | Design notes |
|---|---|---|---|---|
| **kopia-0dr.38** | 2 — `rustback-verify` native worker | `weekly_replica_verify.ps1`, `verify_backups.cmd` | Medium | Two modes (replica-repo check, VHDX integrity). Proven operations; closest to the replica template. **Next worker to build.** |
| **kopia-0dr.39** | 3 — `rustback-filecopy` (embeds `rustic_core`) | `daily_kopia_backup.cmd` + `kopia.exe` | Large (multi-week) | Hardest. Embed `rustic_core` at pinned `=0.11.x`, Cargo.lock committed. Windows metadata layer (ACL/ADS/reparse/sparse) — upstream PR to rustic_core, surgical fork only if upstream stalls 3+ months. Subcommands snapshot/restore/verify/prune/list/find/mount + a long-running `--query-mode`. **Its spec MUST inherit kopia-0dr.35**: restore-level eval (not byte-compare) and coexistence migration (stand up a new restic repo alongside the kopia repo; never in-place conversion). |
| **kopia-0dr.40** | 4 — `rustback-blockcopy` (VHDX from VSS) | `wbadmin.exe` | Large (multi-week) | Hardest. Net-new bootable-VHDX-from-VSS imaging, no upstream. `windows::Win32::Storage::{Vhd,Vss}` + `ntfs` crate + `bcdboot`; chunk-CBT incrementals reuse `rustback-mirror`'s engine. |
| **kopia-0dr.41** | 5 — USN change-tracking speed layer | — | Medium | P3. Per-volume USN cursor owned by `rustback-server`, handed to workers as a hint (never ground truth). Builds on the already-code-complete USN engine in `src/mirror/usn.rs`. Pure optimization — do last. |

`kopia-0dr.35` is not a build — it is the eval/coexistence **design constraint**
that .39's spec must adopt. Fold it into .39's brainstorm; close it when .39's
spec explicitly adopts the restore-level eval.

### Recommended execution order

```
1. kopia-0dr.33  (finish replica eval + cutover)        ─┐ Tier 1
2. kopia-0dr.4   (14-night soak — passive, gated on      │  prerequisite
                  the operator re-enabling the stack)   ─┘  gate
3. kopia-0dr.45  (Windows Service)          ─┐
4. kopia-0dr.43  (run-status module)         │ Tier 2 — interleavable,
5. kopia-0dr.42  (catalog/index module)      │ low design risk
6. kopia-0dr.27  (monitor event view)        │
7. kopia-0dr.44  (tray fold-in)             ─┘
8. kopia-0dr.38  (sub-project 2: verify)    ─┐
9. kopia-0dr.39  (sub-project 3: filecopy)   │ Tier 3 — each its own
   (+ .35 folded into .39's spec)            │ brainstorm→spec→plan;
10. kopia-0dr.40 (sub-project 4: blockcopy)  │ strict serial order
11. kopia-0dr.41 (sub-project 5: USN layer) ─┘
```

Tier 2 and the start of Tier 3 (.38) can overlap once Tier 1 is done — .38 follows
the proven replica template and needs no control-plane change. .39/.40/.41 are
strictly serial and gated on their own specs.

---

## Open decisions / risks to resolve before Tier 3

1. **`rustic_core` upstream metadata PR** (.39) — issue #19 (`windows_metadata`) is
   `help wanted`. Decide the trigger for the surgical-fork fallback (the docs say
   "upstream stalls 3+ months"). Confirm before .39's spec is written.
2. **Backup stack is currently OFF** — the soak (.4) and replica cutover (.33)
   cannot complete until the operator re-enables the disabled scheduled tasks.
   This roadmap assumes re-enablement happens before Tier 1 closes.
3. **`.42` ↔ `.39` coupling** — the catalog module's file-list intake depends on
   `rustback-filecopy`'s output format. Do `.42` step 1 (fold existing indexer)
   early; defer step 2 (filecopy intake) until `.39` lands.

---

## Critical files (reference map for executing the roadmap)

| Area | Files |
|---|---|
| Worker contract (shared) | `C:\dev\rustback\src\worker_contract.rs` |
| Server supervision / DAG | `src\server\worker.rs`, `src\server\scheduler.rs`, `src\bin\server.rs` |
| Server state / API / config | `src\server\state.rs`, `src\server\api.rs`, `src\server\config.rs` |
| Native-worker template | `src\bin\mirror.rs`, `src\mirror\replica.rs`, `cbt.rs`, `vss.rs`, `usn.rs`, `manifest.rs`, `sparse.rs` |
| Indexer → catalog module (.42) | `src\bin\indexer.rs` |
| Run-status → module (.43) | `src\bin\dump.rs`, `src\data.rs` |
| Monitor event view (.27) | `src\pages\`, `src\components\`, `src\server_client.rs`, `src\http_client.rs` |
| Live config | `C:\RustBack\jobs.toml` |
| Design docs | `architecture-vision.md`, `docs\superpowers\specs\2026-05-17-native-worker-cutover-roadmap-design.md` |

## Verification (how to confirm the roadmap is being followed)

- **Per worker**: `cargo test` synthetic-fixture suite green; one parallel-eval
  recorded in the bead; `jobs.toml` `command` flipped; legacy script confirmed
  on-disk + manually runnable; `rustback-dump`/`status` STATUS CARDS green.
- **Per consolidation bead**: the retired `.exe` is gone from `signing/sign-all.ps1`
  and `D:\Recovery`; the absorbing binary's `cargo test` green; the REST/CLI
  surface the module exposes returns correct data against live state.
- **Epic done**: `bd show kopia-0dr` at 46/46; exactly 5 signed executables exist;
  `rustback-server` runs as a Service; all four legacy PowerShell/CMD workers are
  on-disk fallbacks only; `kopia.exe` + `wbadmin.exe` retired as scheduled paths.
- **Each Tier-3 bead** must produce its own `docs/superpowers/specs/*.md` before
  any implementation — this roadmap is deliberately roadmap-level for them.
