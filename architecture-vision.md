# Architecture Vision

**Status:** Living document. Updated 2026-05-14.

**Companion to:** [`ARCHITECTURE.md`](ARCHITECTURE.md) (the current as-built
inventory).

This document captures the *long-term* shape we want the backup stack
to take, the *lessons* that pushed us toward that shape, and the
*decisions* we've made or are deferring. It exists to anchor near-term
architectural choices (Backup Server design, worker boundary choices,
lib vs binary splits) against an agreed-upon north star.

---

## 1. Vision

Build a **unified Rust backup solution for Windows** that combines:

- **File-level deduplicated backup** (kopia's strength — content-addressable
  storage, dedup across snapshots, encryption, configurable hashing/compression,
  efficient incremental snapshots, searchable filename index).
- **Block-level system imaging** (Macrium Reflect's strength — bootable
  VHDX/VHD images, bare-metal restore, sector-level recovery, BCD/boot
  sector handling).
- **Headless orchestration with a thin UI** (own architecture — control
  plane + worker plane + UI client, replacing the current
  Task-Scheduler-driven sprawl of independent cmd/ps1 wrappers).

Single signed Rust binary stack, Windows-first, then Linux/macOS,
eventually **open-sourced on GitHub** as a community-supportable
alternative to both kopia (file-only, Go) and Macrium (proprietary,
Windows-only).

**Competitive target:** the open-source release aims for **feature
and speed parity with Macrium Reflect** at the imaging tier and
with kopia/restic at the file tier — beating both on *integration*,
since today neither tool covers the full ground a Windows user
needs (file-level dedup AND bootable system images AND headless
orchestration AND a polished UI). See §8 for the Macrium feature
matrix and what's in/out of v1.0 scope.

Working name TBD (not "kopia2" — needs its own identity). Likely
Apache-2.0 to match kopia's license and preserve compatibility for
later format-bridging work.

**Release model:** the current personal stack continues to receive
maintenance fixes until it reaches a frozen stability point (see
§7.x); after that, only critical regressions are patched, and all
new development happens on the OSS branch line. The frozen personal
build is the operator's safety net while the v1.0 OSS build proves
itself in parallel evaluation against today's real workloads.

## 2. Why this, why now

The current personal-stack production system works (with the bugs
itemized in §4 mostly addressed) and will continue to work for the
foreseeable future. The user has explicitly committed to keeping the
kopia-based stack alive for local DR throughout the rewrite. This
vision is therefore a *long-horizon evolution*, not a crisis-driven
pivot.

The reasons to start now anyway:

1. **The architectural cleanups we *need* anyway** (cross-task
   orchestration, headless server, thin UI separation) are the same
   ones the long-term vision requires. Investing in the Backup Server
   pays off whether or not the kopia-rewrite ever ships.
2. **The Rust skill base already exists**: `backup-monitor.exe`,
   `backup-mirror.exe`, `backup-dump.exe`, `backup-indexer.exe` are all
   already Rust binaries under `C:\dev\backup-monitor\`. The seed of
   the unified architecture is in place; this is consolidation, not a
   greenfield project.
3. **Signing infrastructure is already in place** (Azure Trusted
   Signing under the `famcodesign` profile). Releasing signed Rust
   binaries to GitHub is a solved problem in this stack.
4. **Today's bugs revealed structural fragility** (§4). The fixes are
   bandages on a model that wasn't designed for what it's now doing —
   five separate Task Scheduler tasks coordinating via log file
   parsing and flag files.

## 3. Current state (brief)

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the authoritative
inventory. The summary:

- **kopia** (Go, upstream fork at `github.com/davidcforbes/kopia`)
  handles file-level snapshot, restore, repo. Runs as
  `\Backup\KopiaServer` (long-running) + `\Backup\DailyKopiaSnapshotV2`
  (daily wrapper task).
- **wbadmin** (Windows built-in) handles the system-image VHDX. Runs
  as `\Microsoft\Windows\Backup\Microsoft-Windows-WindowsBackup` daily.
- **backup-monitor.exe** (Rust, GUI tray) parses logs, shows status,
  fires toast notifications.
- **backup-dump.exe** (Rust, CLI) scores nightly runs, produces
  authoritative STATUS CARDS.
- **backup-indexer.exe** (Rust, CLI) builds filename `.names.idx` and
  `.jsonl.gz` indexes in `D:\BackupMonitorIndex` (recovery-aid
  infrastructure that must stay on D: — see
  `feedback-index-must-stay-on-d`).
- **backup-mirror.exe** (Rust, CLI) — new since 2026-05-13 cutover
  (kopia-bmy.3) — chunk-CBT mirror replicating D:→E: with 4 MiB
  chunked content-addressable manifests.
- **Wrapper scripts** (PowerShell 5.1 + cmd) orchestrate the above
  via Task Scheduler entries under `\Backup\`.

## 4. Lessons learned (from the 2026-05-14 session)

Every one of these is a structural lesson, not just a specific bug to
fix. They drive the architectural choices in §5.

### 4.1 Task Scheduler is a wakeup alarm, not an orchestrator

The current stack has five separate scheduled tasks
(`DailyKopiaSnapshotV2`, `DailyDReplica`, `WeeklyReplicaVerify`,
`WbadminHealthCheck`, `KopiaServer`) with wall-clock triggers, zero
awareness of each other, and only a single integer (`Last Result`) as
their language to the rest of the system. Today's 02:00 missed
trigger (laptop slept past the wall-clock time) and the 22:46 abort
(replica task killed mid-run with no graceful recovery) both come
from this design. The Backup Server pattern (§5.2) eliminates the
class.

### 4.2 Log-parsing as a coordination protocol is fragile

`backup-dump.exe` decides "did the daily run succeed" by parsing
`daily_kopia.log` for specific magic strings ("Daily Kopia backup
complete", "Exit codes:", "RUN" if no completion line). Today the
wrapper finished its snapshot phase but was still running the indexer
phase, so the log lacked the completion line, so backup-dump scored
the run as RUN, so the STATUS CARD looked stale, so the user thought
the replica had failed. The data was actually fine. **A real
orchestrator owns its state; consumers query it. Don't make every
consumer reverse-engineer state from log strings.**

### 4.3 Heartbeat liveness ≠ forward-progress liveness

`heartbeat_watchdog.ps1` watches `heartbeat.log` staleness and kills
wrapper children if no tick. But today's wbadmin indexer was
heartbeat-fresh the entire time it appeared "hung" (~30 min without
log output). The only way to know it was actually working was to
watch `D:\BackupMonitorIndex\wbadmin-*.names.idx` mtime grow at ~250
MB/min. **The Backup Server's health model needs to combine heartbeat
(process is alive) with forward-progress signals (file mtime, output
byte counts, optional OS CPU/IO metrics).**

### 4.4 Antivirus heuristics silently kill backup processes

Bitdefender's `CMD:Heur.BZC.PZQ.Boxter.949.54B76876` heuristic
process-blocked `kopia.exe snapshot create` at 23:11 on 2026-05-13
with no quarantine file written. That single block cascaded into:
KopiaServer task RC=1 → repo unavailable on 127.0.0.1:51515 →
heartbeat stuck on `Repository:Open` → laptop slept past the 03:00
trigger → DailyKopiaSnapshotV2 missed trigger → STATUS CARD showed
yesterday's date. **The architecture must surface AV-kill events
explicitly**: a wrapper guard that detects "my child died with no
exit message I wrote" and classifies it as `AV-suspected` rather than
letting it cascade silently. Memory:
`reference-bd-boxter-kopia`.

### 4.5 Build/sign-time validation gaps cascade into runtime failures

`_scrub_non_ascii.ps1` has silently dropped closing braces in signed
PowerShell scripts twice now (commits `0cb05533` and today's recurrence
in `weekly_replica_verify.ps1` at line 305). `sign-all.ps1` happily
signs the broken result because it doesn't parse-check pre-sign.
Every scheduled run then fails at parse time, RC=1, zero log output,
no useful diagnostic — for hours or days, until someone notices the
STATUS CARD. **The signing pipeline must AST-parse every `.ps1`
target before invoking signtool. Better: phase out `.ps1` wrappers
entirely in favor of Rust binaries that the compiler validates.**
Tracked as `kopia-02h` (P1 after recurrence).

### 4.6 Token-class confusion (S4U vs InteractiveToken)

`WeeklyReplicaVerify` ran under `InteractiveToken` (gets filtered
standard token), so couldn't read the `.kopia-pw.dat` which is
ACL-locked to `Administrators:R, SYSTEM:R`. `DailyKopiaSnapshotV2`
has the same logon type but reads a *different* password file
(`.kopia-server-pw.dat`), so the bug never surfaced there.
`KopiaServer` uses `S4U` and works fine. **The new architecture
should be headless (S4U-equivalent) by default, not inherit the
interactive-session pitfalls of Task Scheduler's defaults.**

### 4.7 DR posture has bootstrapping dependencies that aren't on D:

The user's restore-from-D: mental model is correct for *data* (kopia
repo + wbadmin VHDX + filename index are all on D:, plus a Win11 ISO
for boot media) but the bootstrap chain (kopia.exe binary, the
backup-monitor Rust binaries, the wrapper scripts, the repo
password) lives only on C:. If C: dies, the bootstrap is
recoverable via `git clone` + remembering the kopia password — but
that's not the same as "self-contained on D:". Two bd issues filed
(`kopia-1yn`, `kopia-2xy`) to harden this. **The unified system
should explicitly publish a recovery medium spec, not implicitly
rely on the user remembering to keep the password somewhere.**

### 4.8 Index location reveals the DR positioning principle

The user pushed back on a proposed optimization to move
`D:\BackupMonitorIndex` to C: (which would have eliminated D: I/O
contention between the indexer and the replica). Reason: the index
is *recovery infrastructure* — if C: dies, you need the index on
the *surviving* drive to find what's in your backups. Storing it on
C: is a circular dependency. **Generalizable principle: every piece
of recovery-aid infrastructure belongs on the medium that survives
the failure it's meant to recover from. The new system should
formalize this — name the principle, apply it to design decisions
about where state and indexes live.** Memory:
`feedback-index-must-stay-on-d`.

### 4.9 Personal-stack-quality vs OSS-quality is a real delta

Currently the stack tolerates: hardcoded paths to `D:\BackupMonitorIndex`
in 6+ places, no automated tests for wrapper scripts, signing
machinery wired to a personal Azure subscription, magic-string
log-parsing as the coordination protocol, machine-specific
DPAPI-encrypted secrets. None of this would survive open-source
review. **The migration to the unified Rust system is also a
migration to OSS-quality engineering practices**: config files
instead of hardcoded paths, AST-validated scripts (or pure Rust),
documented IPC protocol, portable secret-storage abstraction.

### 4.10 VSS shadow-copy paths are a separate AV-exclusion namespace from live paths

Added 2026-05-15. Bitdefender consumer's on-access scanner intercepts
file reads at the minifilter layer and sees the *bare NT
object-manager path*
(`\Device\HarddiskVolumeShadowCopyN\dev\kopia\scripts\...`) when a
backup tool reads a file through a VSS shadow. Live-volume path
exclusions (`C:\dev\kopia`) do **not** propagate to shadow access —
the exclusion engine matches the literal path string the kernel
sees, not the canonical live-volume equivalent. Empirically
verified 2026-05-15 (`kopia-bhw`): the DOS-namespaced form
(`\\?\GLOBALROOT\Device\...`) is silently ignored; only the bare
NT form with `*` wildcards on the shadow number works. **The new
architecture must, at install time, configure AV exclusions for
BOTH the live paths AND the corresponding shadow namespace
(`\Device\HarddiskVolumeShadowCopy*\<rel-path>\*`).** Recorded as
`reference-bd-shadow-copy-exclusion`.

### 4.11 Wbadmin's dst-folder rotation breaks "stable destination" assumptions

Added 2026-05-15. `wbadmin` creates a fresh dated folder per backup
(`Backup 2026-05-15 090023` → `Backup 2026-05-16 …` the next night)
and keeps only the latest on the source side. Any mirror tool that
keys per-file state by basename (e.g. backup-mirror's per-VHDX CBT
manifest) needs the wrapper to **rename the destination dated
folder to match source before invoking the mirror** — otherwise
every rotation creates an empty new dst path, the basename manifest
matches nothing on disk, and the post-preflight torn-recovery
rewrites the full ~2.7 TB. We hit this on 2026-05-15 and burned
5+ hours of disk time before fixing it (`kopia-8fc`). **The Backup
Server's job DAG must model "destination-path-aligned" as a
pre-step on workers that operate on rotating-name source trees,
not bury it inside the worker.**

### 4.12 Scheduled tasks silently inherit BelowNormal priority

Added 2026-05-15. Windows Task Scheduler defaults `<Priority>` to
7 (BelowNormal) when the XML omits the field, and that priority
propagates to every child process the task spawns. We discovered
this 2026-05-15 (`kopia-8ag`) when backup-mirror.exe was crawling
at 148 MB/s effective throughput on a disk that can sustain 500+
MB/s. Bumping the running PID to Normal restored expected speed;
persistent fix needed
`$task.Settings.Priority = 5; Set-ScheduledTask`. **The new
architecture should set explicit task priority at server install
time** — never trust the Task Scheduler default. Generalizes to:
every Windows scheduling default that's optimized for "don't
disrupt the interactive user" hurts unattended overnight work.
Recorded as `reference-taskscheduler-priority-default`.

### 4.13 Producer/consumer log-format coupling is silent-fail by design

Added 2026-05-15. Variant of lesson 4.2.
`backup-mirror.exe`'s wrapper (`daily_d_replica.ps1`) writes
` -- replica summary k=v …` to `daily_kopia.log` after every
replica run. `backup-dump.exe`'s parser at `data.rs:545` looked
for ` — replica summary ` (em-dash) or ` - replica summary `
(single hyphen). Double-dash was silently skipped, so the
dashboard's "Replica last OK" was frozen at the last rsync-era
em-dash entry (2026-05-11) for four nights even after successful
backup-mirror runs. Fixed 2026-05-15 (`kopia-wp4`). **The Backup
Server's worker contract — structured JSON-over-HTTP rather than
log-line magic — removes this entire class of bug from
existence**, and is the right reason to do it.

## 5. Architecture principles + component map

### 5.1 Three planes, hard boundaries

```
┌─────────────────────────────────────────────────────────┐
│ UI plane          backup-monitor.exe (tray) +          │
│                   future web/CLI clients               │
│ ─────────────────────────────────────────────────────  │
│                   API (HTTP/REST or named pipes)       │
│ ─────────────────────────────────────────────────────  │
│ Control plane     backup-server.exe (headless,         │
│                   long-running, scheduler + DAG +      │
│                   state + health monitor)              │
│ ─────────────────────────────────────────────────────  │
│                   Worker contract (spawn + heartbeat   │
│                   + done/fail report)                  │
│ ─────────────────────────────────────────────────────  │
│ Worker plane      Replaceable: starts with kopia.exe,  │
│                   wbadmin.exe, backup-indexer.exe,     │
│                   backup-mirror.exe; progressively     │
│                   replaced with native Rust workers    │
│                   (backup-snapshot, backup-restore,    │
│                   backup-repo, backup-image)           │
└─────────────────────────────────────────────────────────┘
```

UI never talks to workers directly. Workers never talk to UI. State
lives in the control plane only.

### 5.2 Backup Server (control plane) — `backup-server.exe`

Headless Rust binary. Runs as `\Backup\BackupServer` Task Scheduler
entry with `LogonType=S4U`, `RunLevel=HighestAvailable`, similar to
`\Backup\KopiaServer`.

Responsibilities:
- **DAG definition**: reads a TOML/JSON config describing job types,
  their dependencies, retry policies, schedule windows.
- **Sequencer**: launches workers in dependency order, waits for
  upstream success before starting downstream.
- **Health monitor**: subscribes to `heartbeat.log` (process-alive
  signal), watches forward-progress signals (file mtime, byte
  counts, optionally OS CPU/IO via PDH counters per child PID).
- **State persistence**: writes job state to a JSON or SQLite file so
  a server crash + restart resumes cleanly rather than starting over.
- **Error recovery**: classifies errors as `retry-transient` vs
  `abort-sequence` vs `manual-intervention` based on configurable
  rules. Handles AV-kill detection (lesson 4.4) as a first-class
  error class.
- **HTTP API** exposing: current state of all jobs, recent history,
  trigger-a-job, abort-a-job. Authentication via shared secret
  (DPAPI-encrypted, same pattern as `.kopia-server-pw.dat`).
- **Heartbeat to `heartbeat.log`** so the existing stall-guard pattern
  works against the server itself (lesson 4.3 self-applied).

Concrete next-investment epic: `kopia-0dr` (Backup Server).

### 5.3 Worker contract

A worker is any process the server spawns to do real work. Today
this is `kopia.exe snapshot create` or `backup-indexer.exe`. In the
future it's `backup-snapshot --source=...`, `backup-image --vol=C:`,
etc.

Contract:
- Server invokes worker with `--server-url=http://127.0.0.1:NNNN`
  and `--job-id=UUID` arguments.
- Worker calls `POST /worker/heartbeat?job_id=UUID` every N seconds
  with optional progress fields (bytes processed, current file,
  etc.).
- Worker calls `POST /worker/done?job_id=UUID&rc=N` on exit with
  structured result.
- Worker stdout/stderr is captured by server and tagged with
  `job_id` in a unified log.

Workers must be **resumable** where possible (kopia snapshot create
already is; wbadmin is not — design constraint for the Rust
replacement). Workers must **not** silently swallow failures.
Workers must **never** write directly to the orchestration log —
that's the server's responsibility.

### 5.4 UI plane — `backup-monitor.exe` becomes a thin client

Current backup-monitor.exe does three jobs: log-parsing, state
display, toast notifications. After the rebuild it does only:
display + notifications. Log-parsing and state management move into
the server.

UI calls `GET /status` to render the dashboard. UI never reads log
files directly. UI is testable against a mock server. UI can be
replaced (web UI, CLI client, mobile app) without touching the
control plane.

### 5.5 Worker boundaries — the rewrite road map

Order of replacement (easiest → hardest):

| Order | Worker | Replaces | Notes |
|---|---|---|---|
| 1 | `backup-indexer` | (already Rust) | First worker to use the new server contract. Proves the protocol. |
| 2 | `backup-mirror` | (already Rust) | Already structured well. Just needs to talk to server instead of being orchestrated by ps1. |
| 3 | `backup-verify` | `weekly_replica_verify.ps1` | Eliminates the ps1 entirely. Calls kopia.exe but wraps it. |
| 4 | `backup-image` | `wbadmin` | The hard one for Windows. Needs VSS + raw block read + VHDX write. Research outcome (§6.2): buildable in **weeks** using `windows::Win32::Storage::{Vhd,Vss}` + `ntfs` crate + shell out to `bcdboot`. Reuses `backup-mirror` chunk-CBT for incrementals. |
| 5 | `backup-file snapshot` | `kopia snapshot create` | Subcommand of the `backup-file` binary (see §5.6). Thin wrapper around `rustic_core::Repository::backup` (file-tier decision §6.0 settled). Our value-add: handing `LocalSource` a VSS shadow-copy mount root, capturing Windows-specific metadata via the upstream-PR'd `windows_metadata` field. |
| 6 | `backup-file restore` | `kopia restore` | Subcommand of `backup-file`. Thin wrapper around `rustic_core::Repository::restore`. Our value-add: applying the Windows metadata correctly on restore (security descriptors, ADS, reparse points, sparse). |
| 7 | (not needed) | `kopia repository ...` | The file-tier repo layer is rustic_core's responsibility. We focus on platform integration, orchestration, and the block-image worker. |

Each worker is independently shippable. The system remains
production-grade throughout because old workers keep running until
their replacement is proven via parallel-evaluation (the kopia-bmy.3
cutover pattern).

### 5.6 `rustic_core` slot map — where the library lives in the architecture

`rustic_core` is a library (a Rust crate you `use` in code), not a
binary or a service. The question is which of our binaries link it
against and which never touch it. The split is opinionated and tight:

```
┌────────────────────────────────────────────────────────────┐
│ UI plane:      backup-monitor.exe       — NO rustic_core   │
│                (thin client; queries server via HTTP)      │
├────────────────────────────────────────────────────────────┤
│ Control plane: backup-server.exe        — NO rustic_core   │
│                (orchestrator only; manages workers)        │
├────────────────────────────────────────────────────────────┤
│ Worker plane:                                              │
│   File-tier (one binary, multiple subcommands):            │
│     backup-file snapshot                — YES rustic_core  │
│     backup-file restore                 — YES rustic_core  │
│     backup-file verify  (a.k.a. check)  — YES rustic_core  │
│     backup-file prune                   — YES rustic_core  │
│     backup-file list / find             — YES rustic_core  │
│     backup-file mount  (snapshot FUSE)  — YES rustic_core  │
│   Block-tier:                                              │
│     backup-image                        — NO  rustic_core  │
│   Local-replica:                                           │
│     backup-mirror     (chunk-CBT D:→E:) — NO  rustic_core  │
│   Search-aid:                                              │
│     backup-indexer    (filename .idx)   — YES (read-only)  │
└────────────────────────────────────────────────────────────┘
```

**Why `backup-file` is one binary with subcommands, not many binaries**:

- All rustic_core operations flow through one `Repository` object —
  `backup`, `restore`, `check`, `prune`, `snapshots`. Sharing a binary
  means linking rustic_core once.
- Smaller signed-artifact set (signing each binary has fixed
  overhead — see today's `signing/sign-all.ps1` and the kopia-tpl/
  kopia-02h bug class).
- One set of dependency bumps when rustic_core releases.
- Matches the shape kopia CLI users already know (`kopia snapshot
  create`, `kopia restore`, etc.) and rustic CLI users (`rustic
  backup`, `rustic restore`).
- The Backup Server's worker contract treats it as one binary launched
  with different subcommands per job.

**Query vs mutation worker split — `backup-file --query-mode`**:

UI wants snappy "list snapshots / browse a snapshot tree / search
filenames" responses. Spawning `backup-file list` per UI click is
slow (rustic_core repo-open cost). Three options:

- **(a) Spawn-on-demand**: every UI query → server spawns
  `backup-file list ...` → exit. Simple; slow on hot paths.
- **(b) Long-running query worker**: one persistent
  `backup-file --query-mode` keeps the repo open. Server proxies UI
  reads through it. *This is the KopiaServer pattern transcribed
  to our architecture* — same role, just one we own.
- **(c) Server embeds rustic_core for read-only**: easy and fast,
  but bloats the server and makes it data-aware (violates the
  "control plane has no data" principle).

**Decision (2026-05-14): adopt option (b)**. Mutation workers (`backup`,
`restore`, `prune`) are still spawned per-job. A single persistent
query worker handles UI reads. The Backup Server stays slim and
data-blind; the query worker is the only long-running file-tier
process.

**What rustic_core does NOT replace** (worth being explicit so we
don't accidentally try):

- **Orchestration** — Backup Server (our control plane).
- **Block-level system imaging** — `backup-image` worker (VHDX from
  VSS, our own code; see §6.2).
- **Local-disk replica** — `backup-mirror` (chunk-CBT byte-level,
  format-agnostic — operates on bytes regardless of what's stored).
- **Windows-specific metadata layer** — security descriptors, ADS,
  reparse points, sparse. Captured via the upstream PR to rustic_core
  (`windows_metadata` field on `Metadata`) OR our surgical fork of
  the three relevant modules (see §6.0).
- **Filename search index** — `backup-indexer` writes our own
  `.names.idx` format under `D:\BackupMonitorIndex`. Uses rustic_core
  read-only to walk snapshots but maintains its own index format
  (the kopia REST API equivalence gap documented in memory
  `reference-kopia-api-no-basename-index` carries forward).

**What it does cleanly replace** (the kopia features in our current
production stack that map 1:1 to rustic_core):

- `kopia snapshot create` → `backup-file snapshot`
- `kopia restore` → `backup-file restore`
- `kopia repository connect ... verify ... disconnect` (used by
  `weekly_replica_verify.ps1`) → `backup-file verify`
- `kopia maintenance run --full` → `backup-file prune` (kopia's
  full maintenance ≈ rustic prune in scope)
- `kopia snapshot list` → `backup-file list`

## 6. Open questions — research pending

### 6.0 Embedding strategy and extension boundary (settled 2026-05-14)

Based on the code+architecture review of `rustic_core` (see §6.1):

**Strategy: embed `rustic_core` at a pinned release as the file-tier
foundation. Build our Windows-specific work and orchestration as
*our* code on top. Do not fork unless forced.**

Pinning strategy:
- `rustic_core = "=0.11.x"` in `Cargo.toml`, exact version.
- `Cargo.lock` committed.
- **Never track `main`** — every minor release ships at least one
  breaking API change.
- Re-evaluate on each minor bump; ratchet tests through each upgrade
  deliberately.
- Vendor a specific commit only when actively shepherding an
  upstream PR; otherwise pin to release.

Where Windows extensions live:

| Capability | Where it goes | Why |
|---|---|---|
| VSS snapshot integration | **Our orchestrator** (Backup Server / worker) hands `LocalSource` a shadow-copy mount root | No `rustic_core` change needed; matches how restic-the-CLI does it. Clean separation. |
| NTFS ACL / ADS / reparse / sparse handling | **Upstream PR to `rustic_core`**, opt-in `windows_metadata` field on `Metadata` | Preserves restic-format compatibility when absent. Issue #19 is `help wanted`. License Apache/MIT, no CLA, unblocked. |
| Long-path (`\\?\` prefix) handling | **Upstream PR** alongside the metadata work | Belongs in the same set of Windows fixes. |
| If upstream stalls 3+ months | **Surgical fork** of `backend/node.rs`, `backend/local_destination.rs`, and `Metadata` only — never the whole crate | Keeps upstream merge surface minimal; everything else continues to flow from upstream. |
| Block-level VHDX imaging | **Separate worker** (`backup-image`) under our control | Outside rustic's scope by design. See §6.2. |
| Backup Server orchestration | **New binary** under our control | Outside rustic's scope by design. See §5.2. |

This split keeps our novel work — Windows imaging and orchestration —
under our full control, while letting us inherit ~6-18 months of
mature file-tier engineering (chunker edge cases, index race
conditions, pack repair, restore correctness) that rustic and restic
have already debugged.

### 6.1 `rustic_core` quality assessment (evidence for §6.0)

Research outcome (2026-05-14): `rustic_core` (Apache-2.0 OR MIT) is a
credible, genuinely library-shaped Rust foundation for the **file-level**
tier of the unified system, but it cannot do block-level imaging
(neither restic nor rustic does — confirmed in upstream issue
[restic#4398](https://github.com/restic/restic/issues/4398), open
with no plan to ship native imaging). Key facts:

- **API shape**: `rustic_core` exposes `Repository` as a state-machine
  type with `backup`, `restore`, `snapshots`, `check`, `prune`
  high-level operations. Working embed example in the upstream docs.
  Status flagged as "early development, API subject to change" —
  pin a version and expect churn.
- **Format**: reads and writes the restic v1 repository format.
  Maintained parity with restic. Compatibility is beta-grade, not
  1.0.
- **Crypto**: uses the RustCrypto crates (`aes`, `poly1305`,
  `scrypt`, `sha2`). Inherits restic's cryptographic design (Filippo
  Valsorda's 2017 analysis is the main public review — no fatal
  flaws, one caveat about password changes not re-keying blobs). No
  public third-party audit of rustic specifically; recent CVEs in
  the restic ecosystem (CVE-2025-22868, CVE-2025-22869) are in the
  upstream `golang.org/x/crypto/ssh` and don't apply to rustic.
- **Windows specifics — the weakest area**:
  - **VSS: NOT implemented in rustic.**
    [rustic#1412](https://github.com/rustic-rs/rustic/issues/1412)
    is open, low priority, unassigned. Restic itself has
    `--use-fs-snapshot` for VSS; rustic doesn't. We'd wire VSS
    ourselves either way.
  - **NTFS ACLs**: restic only landed proper Security Descriptor
    preservation in 2025 (PR #5465). Full SD capture requires
    `SeBackupPrivilege` (Windows limit, not restic's). rustic
    trails restic's coverage here.
  - **ADS, sparse files, reparse points, symlinks**: rustic
    inherits whatever subset of restic's Windows handling has been
    ported; expect gaps.

**Code+architecture review outcome (2026-05-14)**:

Strengths:
- **Typestate `Repository<S>` pattern** — strong API design signal
  ([repository.rs](https://github.com/rustic-rs/rustic_core/blob/main/crates/core/src/repository.rs)).
- **Clean modular layout** — backend / blob / index / archiver /
  commands cleanly separated. Better organized than restic-the-Go-codebase
  in some respects.
- **Library-shaped API** — three-line backup call, 13 working
  examples in `examples/`, builder pattern, `Result`-returning, no
  global state.
- **Synchronous + rayon parallelism** — fits our model. Internal
  parallelism via `std::thread::scope` + `rayon` + `crossbeam-channel`.
  Per-file work is the streaming chunker (single-threaded per file,
  parallel across files).
- **Streaming I/O, not mmap** — correct answer for multi-TB files,
  avoids the Windows mmap pitfall already documented at
  [`reference-mmap-multi-tb-windows`](memory).
- **`thiserror`-structured errors** with attached guidance, doc-URL
  links, error codes. Stated discipline: "no unwraps in production
  code."
- **Newtyped IDs** (`BlobId`, `DataId`, etc.) — proper type discipline.
- **Test coverage**: unit + integration + snapshot (`insta`) +
  property (`proptest`). No fuzz harness. Respectable for a small team.
- **License**: Apache-2.0 OR MIT, **no CLA** — contributing Windows
  fixes is unblocked.

Weaknesses (sized, not disqualifying):
- **Pre-1.0 API churn**: every minor bump has had at least one
  breaking change. No 1.0 in the public roadmap. Mitigation: pin to
  exact release, ratchet tests deliberately on upgrades.
- **Bus factor of 1**: Alex Weiss (`aawsome`) is 53% of last-90-day
  commits. 8 distinct human authors in the last quarter but most are
  drive-by. Mitigation: restic-format compat means we can read our
  data with restic itself if rustic_core ever stalls.
- **Backend traits are `pub(crate)`**: third-party backends require a
  fork or upstream PR. Doesn't affect our plan (we use the existing
  `local` backend) but worth knowing.
- **Chunker is a closed enum** (`Rabin | FixedSize`), not trait-based —
  can't plug our own without a patch.
- **`Node`/`Metadata` is Unix-shaped** — no fields for security
  descriptors, ADS, reparse-point tags, sparse flags. Windows code
  paths in `local_destination.rs` are TODO stubs (`#[cfg(windows)]`
  branches return `Ok(())` for `set_user_group`, `set_permission`,
  `set_extended_attributes`, etc.).
- **Thin design docs**: no ARCHITECTURE.md, no ADRs, `CONTRIBUTING.md`
  is two sentences. API rustdoc is decent; design rationale isn't
  written down.
- **No published benchmarks** vs restic.

Project health:
- **77 stars, 38 forks, 49 open issues, 14 open PRs, 518 commits** on
  main, 52 releases.
- Release cadence: **6-8 weeks** between minor releases (steady).
  Latest `rustic_core-0.11.0` on 2026-04-05.
- **Apache/MIT, no CLA, no CODE_OF_CONDUCT.md, no GOVERNANCE.md**.
- Windows umbrella issue **#19 is `help wanted`** — upstream
  receptive to Windows contributions.

Decision answers:
- **A.** Code quality high enough to embed? **Yes, with caveats.**
- **B.** Right extension points for our needs without forking?
  **Partly.** VSS yes (orchestrator-level). NTFS ACLs no (needs
  upstream PR or surgical fork of `Metadata`).
- **C.** Healthy enough to depend on for years? **Risky but
  acceptable.** Bus factor of 1; format compat mitigates.
- **D.** Pinning strategy: **pin to release, vendor lockfile, never
  track main.**
- **E.** If embedding NOT viable, would forking fix it? **No.** A
  fork inherits the same code; only acquires merge-conflict debt
  forever.

Full evidence: see the citation block in the dispatch agent's report
(this turn's working notes). Key source links:
- [Repo root](https://github.com/rustic-rs/rustic_core)
- [Public API](https://github.com/rustic-rs/rustic_core/blob/main/crates/core/src/lib.rs)
- [Repository typestate](https://github.com/rustic-rs/rustic_core/blob/main/crates/core/src/repository.rs)
- [Unix-only Metadata](https://github.com/rustic-rs/rustic_core/blob/main/crates/core/src/backend/node.rs)
- [Windows TODO stubs](https://github.com/rustic-rs/rustic_core/blob/main/crates/core/src/backend/local_destination.rs)
- [Windows umbrella issue #19](https://github.com/rustic-rs/rustic_core/issues/19)

### 6.2 wbadmin alternatives — VHDX worker is buildable in Rust

Research outcome (2026-05-14): there is no clean turnkey Rust
library for emitting bootable VHDX from a VSS snapshot today, but
all the pieces exist and **a `backup-image` worker is buildable
in weeks, not months**. The architecture:

- **VHDX writer**: use the official Microsoft
  [`windows`](https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/Storage/Vhd/index.html)
  crate's `Win32::Storage::Vhd` bindings — let `VirtDisk.dll`
  (`CreateVirtualDisk` / `OpenVirtualDisk`) write the VHDX, we
  stream blocks in. Pure-Rust crates (`vhdx` by calebfletcher,
  `rdisk` by vsrs) exist but are research-grade; the
  Microsoft-bindings path is production-ready.
- **VSS access**: write the COM dance ourselves against
  `IVssBackupComponents` (bindings in `winapi`/`windows-rs`, no
  high-level wrapper available). Standard sequence: CoInitialize →
  CreateVssBackupComponents → InitializeForBackup → SetBackupState
  → GatherWriterMetadata → StartSnapshotSet → AddToSnapshotSet →
  DoSnapshotSet → GetSnapshotProperties. [albertony/vss](https://github.com/albertony/vss)
  is C# but a useful reference.
- **NTFS-aware sparse reads**: use
  [`ntfs`](https://github.com/ColinFinck/ntfs) (ColinFinck,
  MIT/Apache) — mature, well-reviewed crate. Lets us skip
  unallocated blocks via `FSCTL_QUERY_ALLOCATED_RANGES` against
  the shadow device for ~disk-used-size first images instead of
  full-volume size.
- **Boot config (BCD)**: **shell out to `bcdboot.exe`.** This is
  standard practice — even Macrium and Acronis do this because
  Microsoft does not document the on-disk BCD format. Not a
  weakness; the accepted pattern.
- **Native-Boot-of-VHDX restore**: `diskpart` partition setup +
  mount the VHDX + `bcdboot` against the mounted Windows partition.
  Fully supported by Microsoft ([Native Boot VHDX
  docs](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/deploy-windows-on-a-vhd--native-boot)).

Pragmatic architecture for the `backup-image` worker:

1. Acquire VSS snapshot of the source volume.
2. Open the shadow device as a 512n block source.
3. Create a dynamic VHDX via `CreateVirtualDisk`.
4. Read allocated-range list from the shadow's NTFS via the `ntfs`
   crate / `FSCTL_QUERY_ALLOCATED_RANGES`.
5. Stream only allocated blocks into the VHDX (skip unallocated).
6. On subsequent runs, chunk-CBT against the prior image — reuses
   `backup-mirror`'s existing 4 MiB chunk infrastructure.
7. For restore: `diskpart` + mount VHDX + `bcdboot`.

**The headline finding**: this is genuinely tractable. wbadmin's
quirks (file-lock hangs, ACL traps, no fine-grained scriptability)
are not inherent to system-imaging — they're wbadmin's quirks.
Owning the worker means owning the bugs as well, but it removes
the external dependency that we have least control over.

Cross-platform implications (for the open-source roadmap):

- **Linux**: no equivalent of wbadmin. The community pieces are
  `dd` / `ddrescue` for raw, `partclone` / `ntfsclone` /
  `e2image` for filesystem-aware sparse images, `tar` / `borg` /
  `restic` for file-level, and `grub-install` for boot. Clonezilla
  is a curated ISO assembly of these. There is no
  "give-me-a-bootable-image with one syscall" service to wrap.
  Our Linux `backup-image` worker would compose `partclone` +
  `grub-install` (or similar) at the worker layer.
- **macOS**: **bootable-image backup is not possible.** Apple
  removed the capability post Big Sur (2020) — the signed
  System Volume + Sealed System Volume model means only `asr`
  restoring an Apple-signed installer image produces a bootable
  disk. Time Machine on APFS uses APFS volume snapshots but is
  explicitly not bootable. macOS support means: file-level only,
  recovery is "reinstall macOS, then restore user data via
  `tmutil`-equivalent." Document this as a platform limit in the
  open-source readme; don't promise what Apple won't let us
  deliver.

**Crate landscape summary**:

| Need | Best crate | License | Maturity |
|---|---|---|---|
| VHDX read+write via Win32 | `windows::Win32::Storage::Vhd` | Apache/MIT | Production |
| VHDX read (pure Rust) | `vhdx` (calebfletcher) | Apache/MIT | Early |
| VSS COM bindings | `windows::Win32::Storage::Vss` | Apache/MIT | Bindings stable, no high-level wrapper |
| NTFS parser | `ntfs` (ColinFinck) | MIT/Apache | Mature |
| BCD manipulation | (none — shell out to `bcdboot.exe`) | — | N/A |

References:
- [restic#4398 — block device backup](https://github.com/restic/restic/issues/4398)
- [rustic vs restic comparison](https://rustic.cli.rs/docs/comparison-restic.html)
- [rustic_core on docs.rs](https://docs.rs/rustic_core/latest/rustic_core/)
- [rustic#1412 — VSS support](https://github.com/rustic-rs/rustic/issues/1412)
- [Filippo on restic cryptography](https://words.filippo.io/restic-cryptography/)
- [MS-VHDX open specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-vhdx/83e061f8-f6e2-4de1-91bd-5d518a43d477)
- [`windows::Win32::Storage::Vhd`](https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/Storage/Vhd/index.html)
- [ColinFinck/ntfs](https://github.com/ColinFinck/ntfs)
- [Native Boot VHDX (Microsoft)](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/deploy-windows-on-a-vhd--native-boot)

### 6.3 Repository format — three paths now in play

With the rustic_core research outcome (it IS library-usable),
the format decision has three branches instead of two:

- **A. Embed rustic_core, use restic format.** Cheapest entry: file
  tier "just works" via a library call. Cost: accept upstream API
  churn (rustic_core flagged as early-stage), accept that VSS / ACL
  / ADS coverage is on us either way, deliver a tool that's a peer
  of restic rather than a peer of kopia. Restic-format compatibility
  is a feature in itself — restic users can migrate to us trivially.
- **B. Implement kopia format ourselves.** Highest up-front cost
  (kopia has a sprawling spec — content/object/manifest layers,
  pluggable hashing/compression/encryption, hierarchical policies).
  Reward: zero-migration path for existing kopia users (which
  includes today's production data). Risk: must track kopia format
  evolution; we don't control the spec.
- **C. New native format learning from both.** Most ambitious. Cost:
  full design + implementation work, migration tooling required
  for kopia AND restic users. Reward: clean format decisions
  optimized for our actual workload (chunk-CBT, mixed file +
  block-image tiers, Windows-first semantics), no upstream
  compatibility burden.

**Decision (settled 2026-05-14)**: option A — embed `rustic_core`
at pinned release. See §6.0 for the extension strategy. Reasons:
(1) the code+architecture review (§6.1) confirmed quality is high
enough; (2) we are not crypto experts and rustic_core's
RustCrypto-based implementation is the most-mature Rust-native file
backup available today; (3) restic-format compatibility is a real
value prop for the open-source release AND an emergency exit if
rustic_core upstream ever stalls; (4) saves 6-18 months of file-tier
reimplementation work; (5) lets us focus our novel work on the
Backup Server and the VHDX worker — the parts that don't exist
anywhere.

Open follow-up: how do we migrate the user's existing kopia repo
into a restic-format repo? Probably: one-time "snapshot mount via
kopia + re-backup via rustic_core" tool. Not pretty, but doable.
Worth a separate beads issue when the file-tier worker actually
lands.

### 6.4 Kopia features not in `rustic_core` — what we'd need to build

Embedding `rustic_core` gives us mature file-tier dedup + encryption
+ snapshot/restore essentially for free. Several kopia features that
the current production stack uses (or that we'd otherwise want)
**do not exist in rustic_core or restic** — we'd build these
ourselves, mostly in the **Backup Server** layer rather than as
modifications to rustic_core. Categorized by where the work goes
and how urgent:

**Build in the Backup Server (control plane), early phase:**

| Kopia feature | Where it goes in our architecture | Notes |
|---|---|---|
| **Hierarchical policy system** (global → host → user → path; retention, scheduling, file inclusion, compression, error handling) | Backup Server's policy engine | Kopia stores policies as JSON manifests *inside the repo*. Rustic has only CLI flags (`forget --keep-daily=N`). We'd build the policy engine in the server and emit appropriate `backup-file prune` / `forget` invocations. Stored policy semantics are flexible — could persist in server state file rather than the repo. |
| **Retention policy evaluator** (latest-N, hourly-N, daily-N, weekly-N, monthly-N, annual-N, with promotion logic) | Backup Server, calls `backup-file prune` with computed `--keep-*` flags | Rustic has these flags; what's missing is the *policy*, not the *primitive*. Stored declaratively in server config. |
| **Maintenance scheduling** (kopia quick + full maintenance) | Backup Server's job DAG | Rustic has `check` + `prune` as primitives. We schedule them. |
| **Snapshot actions/hooks** (pre/post-snapshot shell commands per path — e.g. SQL dump before snapshot) | Backup Server's job DAG (steps wrap the snapshot worker) | Cleaner here than in the worker — actions become explicit DAG nodes, not buried inside backup logic. |
| **Concurrent multi-host snapshot coordination** (multiple machines pushing to one shared repo, lock-aware) | Backup Server's job scheduler (acquire repo lock before snapshot worker spawns) | Restic format supports cross-host dedup at the format level; coordination is policy. v1 single-machine; v2+ multi-machine. |

**Build as new workers, later phase:**

| Kopia feature | Worker / approach | Notes |
|---|---|---|
| **Snapshot mount (FUSE/WinFsp)** — browse/extract files from snapshot without full restore | `backup-file mount` subcommand, uses `winfsp-rs` on Windows / `fuser` on Linux | Restic-the-CLI has `restic mount`; rustic_core does not ship a mount API yet. Could be a small wrapper we build on top of rustic_core's snapshot tree walk. Highly user-visible (backup-monitor UI shows "browse snapshot" → mount → file picker). |
| **Snapshot diff / changelog** (what changed between two snapshots) | `backup-file diff` subcommand | rustic has `diff`; verify it covers what kopia's `snapshot diff` does. |
| **Repository repair** (kopia `repository repair` for partial corruption) | `backup-file repair` subcommand | rustic has limited repair (`check --read-data` etc.). Worth assessing parity. |

**Format-level (would need upstream PR or surgical fork — see §6.0):**

| Kopia feature | Restic-format equivalent? | What we'd do |
|---|---|---|
| **Reed-Solomon error correction codes (ECC)** on pack files — defense against bit-rot in primary repo | **Restic format has none.** | Real gap. Mitigation today: the `backup-mirror` chunk-CBT replica catches divergence between D: and E: by content hash, so corruption shows up on the next replica run. Could add ECC as a sidecar (`*.ecc` files next to packs) without breaking restic compat. **Worth a beads issue to evaluate.** |
| **Configurable hashing algorithms** (HMAC-SHA256, HMAC-SHA224, BLAKE2B, BLAKE3) | Restic: SHA-256, recently BLAKE3 added. | Adequate. Hash choice is locked in at repo init anyway. |
| **Configurable compression** (zstd, gzip, lz4, none, with per-level tuning) | Restic ≥0.14: zstd only, level tunable. | Adequate for v1; if it matters later, file an upstream PR for additional codecs. |
| **Pluggable content splitters** (BUZHASH, RABIN, FIXED + sub-variants) | Restic format hardcodes RabinCDC. Rustic enum closed (`Rabin | FixedSize`). | Adequate for v1. |
| **Format versioning with backward-compat** (kopia's `repo/format/` v1 + v2 + ...) | Restic format is v1; rustic tracks. | Less mature in version management; cross our fingers and bridge if needed. |

**Won't have / explicit non-features (open-source readme caveat):**

| Kopia feature | Why we won't build it | What we do instead |
|---|---|---|
| **11+ cloud storage backends** (S3, Azure, GCS, B2, SFTP, WebDAV, rclone, etc.) | Out of v1 scope by design (local + LAN replica only). | Rustic already supports local, REST, S3, B2, opendal-backed others. Add as needed, post-v1. |
| **HTML web UI** (kopia/htmlui as a separate repo) | We're building a native Windows UI (`backup-monitor.exe`) for our primary use case. | A web UI is a possible later addition (thin Yew/Leptos client of our server API) — same as how rustic UI projects evolved. Not v1. |
| **gRPC API** (kopia has gRPC alongside REST) | Our IPC is HTTP/REST or named pipes (see §6.0). | YAGNI for v1; revisit if a serious cross-language client need emerges. |
| **Cross-host dedup at the format level** | Restic format supports this; we just don't orchestrate it in v1. | Document as "single-machine v1, multi-machine roadmap." |

**Summary of build-vs-inherit math:**

- **Inherited from rustic_core**: file walking, deduplication, encryption,
  hashing, compression, snapshot creation, restore, prune, check, repo
  locking, pack management, index management, restic-format compat. The
  hardest 70% of a backup tool's correctness budget.
- **Built by us in the Backup Server**: policies, scheduling, hooks,
  orchestration, retention evaluation, multi-machine coordination
  (later), the entire UI layer, the entire block-image worker, the
  entire replica worker.
- **Upstream PR (one initiative)**: `windows_metadata` opt-in field
  on `Metadata` for security descriptors / ADS / reparse / sparse.
- **Maybe-build, deferred decision**: ECC sidecar files. Snapshot
  mount worker (probably yes, mid-phase).

This split is the right shape for the open-source story: "we are
the orchestration + Windows-native layer that turns rustic_core into
a complete unified backup product." The novel work is concentrated
where it should be — in the parts that don't exist anywhere — and
we don't reinvent the parts that already work well.

### 6.5 Configuration & secrets portability

Today's stack uses DPAPI-LocalMachine secrets, hardcoded paths,
and machine-specific signing certs. The unified system needs a
portable secret-storage abstraction (probably an opaque trait
with DPAPI, libsecret, macOS Keychain, and "encrypted file +
password from env" implementations). Decide early because every
worker will depend on it.

### 6.6 Cross-platform commitment

Open source means the community will ask for Linux + macOS day
one. The choice: ship Windows-first with an explicit "Linux/macOS
on the roadmap" statement (manageable), or build cross-platform
from the start (higher up-front cost, narrower MVP). Recommendation:
Windows-first, but design abstractions (e.g., `Volume` trait with
`VssVolume` and `LinuxDmSnapshot` impls) that don't paint into a
corner.

### 6.7 NTFS change-detection primitives — making the file-tier worker fast

Research outcome (2026-05-15, after watching a 2.46 TB torn-recovery
rehash take 4.6 hours): Windows exposes documented primitives that
let backup workers skip the full-file hash pass when the OS already
knows nothing changed. Today's stack reads + hashes every chunk of
every file on every run; the new architecture should consult these
signals first and only fall back to full hashing when the signal is
unavailable, ambiguous, or fails the trust gate.

The primitives, ranked by leverage:

| Primitive | Granularity | Skips hash pass? | Notes |
|---|---|---|---|
| **`FSCTL_USN_TRACK_MODIFIED_RANGES` + `USN_RECORD_V4`** | byte ranges (≥64 MB rounded) | **Yes** | Plain NTFS, no Hyper-V dependency. Per-file dirty extents reported by the OS. Reports over-round (~16× per chunk at 4 MiB) but never under-reports — safe for backup correctness. Enabled per-volume; persists across reboots. See `kopia-61n`. |
| **USN journal V2/V3** | file | No (file-level only) | Standard NTFS change journal. The right outer filter: "did this file change since cursor X". `usn-journal-rs` crate. Tracks via `kopia-1tr`. |
| **`FSCTL_QUERY_ALLOCATED_RANGES`** | allocated byte ranges | partial (skips unallocated) | For sparse VHDX files, eliminates reads on holes outright (vs the current `is_all_zero(buf)` post-read check that still pays the I/O). Documented since XP. Tracked via `kopia-dyj`. |

What we **rejected** and why:

- **VHDX Resilient Change Tracking (RCT)** — `QueryChangesVirtualDisk`
  via `virtdisk.h`. Block-level CBT for VHDX, but only works when
  the VHDX is owned by Hyper-V with RCT enabled at write time.
  `wbadmin`'s output VHDXes don't qualify, nor does our QuickBooks
  `.qbw` use case. Closed `kopia-44w` in favor of USN V4.
- **VSS differential snapshot management** — the COM API exists
  (`IVssDifferentialSoftwareSnapshotMgmt`) but only manages the
  diff-area storage; there is no userspace `Diff(snapshot_a,
  snapshot_b)` query exposed. Veeam built their own filter driver
  to get around this; we don't need to because USN V4 covers our
  case on plain NTFS.
- **`$MFT` / `$LogFile` direct reads** — same information as
  `FSCTL_ENUM_USN_DATA`, but undocumented format and slower. Skip.
- **`FSCTL_LOOKUP_STREAM_FROM_CLUSTER`** — Microsoft's own docs
  warn "very resource-intensive." Forensic tool, not
  change-tracking.
- **Custom minifilter driver** (Veeam-style) — was a serious option
  in our planning until we found USN V4. With USN V4 in hand, a
  driver buys us nothing on plain NTFS and adds a deployment
  surface (driver signing, kernel-mode bugs) we shouldn't take on.

Where these primitives slot into the architecture:

- **Per-volume USN cursor state lives in the Backup Server.** The
  server enables the journal + range tracking at install time,
  persists `{journal_id, next_usn}` per volume in its state file,
  and hands each backup worker a filtered "set of files (and
  byte ranges within those files) that may have changed since
  last run."
- **Workers consume the signal as a hint, never as ground truth.**
  The kopia-8j4 preflight (size-and-marker check) remains the
  trust gate. If a worker is told "this file is clean" by the
  USN cursor but `dst.len() != manifest.src_size`, the worker
  falls back to full hash. The signal is for speed, not for
  correctness.
- **Journal-wrapped or first-run fallback is automatic.** If the
  stored journal_id mismatches the volume's current journal_id, or
  if stored `next_usn < first_usn` (wrap), the server hands the
  worker an empty hint and the worker does a full pass. Never
  silently skip when the journal can't prove cleanliness.

**Expected impact (production-extrapolated from today's runs):**

| Workload | Today (full hash) | With USN V4 + ALLOCATED_RANGES |
|---|---|---|
| KopiaRepo nightly (~27K immutable pack blobs, ~0 changes) | ~37 min | seconds |
| WIB nightly (2.7 TB VHDX, ~99% unchanged blocks) | ~80 min | minutes |
| KopiaRepo with active maintenance | ~37 min | seconds + write of new packs |
| WIB after wbadmin GB-scale daily delta | ~80 min | minutes proportional to delta |

This work is independent of the rustic_core embed (§6.0) — these
primitives sit *between* the worker and `rustic_core::backup()`,
filtering the file/range set before rustic_core's chunker even
sees them. Restic-format compatibility unchanged.

**Parallelism note:** see also §4 and CLAUDE.md Rule 3 — the
architecture should bias toward intra-file pipeline parallelism
(disjoint physical disks read concurrently, as in the `kopia-c90`
torn-recovery pattern landed 2026-05-15) and *avoid* multi-threaded
hashing or file-level parallelism in CBT mode where head contention
on spinning destinations destroys throughput. Multi-threaded
hashing in particular buys nothing because SHA-256 is already 2.5×
faster than the I/O subsystem can feed it on this host.

## 7. Migration strategy: Ship of Theseus

Throughout the rewrite, the production stack stays alive. Each
worker is replaced one at a time, with parallel evaluation
(matching the kopia-bmy.3 pattern):

1. Build new worker.
2. Run old + new side-by-side, comparing outputs.
3. Run only the new worker for N days while keeping old code path
   reachable for rollback.
4. Delete old worker.

The user's personal data is never the test bed. The user's data
goes through the production stack continuously; the new code path
is tested against synthetic fixtures + parallel-evaluation
shadows.

### 7.1 Freeze point: personal-use stable, OSS-dev branch

Once the **current codebase** (kopia + wbadmin + backup-monitor +
backup-mirror + scripts/, all the work tracked in `kopia-bmy` and
its children) reaches a stability point where the dashboard is
green for ~14 consecutive nights with no manual intervention, we
**freeze it as the operator's personal-use build**. Concretely:

- Tag the personal-stack repo at `personal-v1-frozen` (or similar)
  on both `kopia` and `backup-monitor`.
- The frozen tag receives only critical-regression patches —
  security CVEs, AV vendor breakage, Windows-API breakage on a
  future Windows feature update. No new features.
- All new development moves to a separate branch line (`oss-dev`
  or a new repo) targeting the §1 vision.

The two lines run in parallel for the duration of the OSS rewrite:

```
personal-v1-frozen ──● (security-only, runs daily, owns user's data)
                     │
                     │ parallel evaluation
                     │ (synthetic + replica shadow)
                     │
oss-dev    ──────────● (active development, no user-data dependency)
                     │
                     ●─→ feature/speed parity with Macrium
                     │
                     ●─→ v1.0 cut, OSS public release
                     │
                     ●─→ N nights of parallel-eval success
                     │
                     ●─→ personal-stack migration to OSS v1.0
                          (operator's call, not forced)
```

This is the literal Ship of Theseus pattern from §7 applied at the
codebase level rather than the worker level: keep the working
thing working while the new thing matures, then transition only
when the new thing has earned the trust. The frozen tag exists
specifically so operator confidence in their backups is never
contingent on the OSS dev branch's stability.

What "stable enough to freeze" means concretely:

- 14 consecutive nights green per `backup-dump.exe` (Kopia,
  wbadmin, Replica, Heartbeat all OK)
- No open P1 beads against the personal stack
- BD exclusions documented and reproducible on a fresh machine
  (kopia-bhw resolution)
- All five `\Backup\` tasks set to explicit Priority=5 (kopia-8ag)
- `signing\README.md` covers the cold-start procedure for a fresh
  host (incident-recovery target)

Today's session moved several items into the "done" column toward
this freeze. Open items above are the bar for declaring the
freeze.

## 8. Out of scope (deferred decisions)

### 8.1 Macrium Reflect feature parity matrix — what we WILL match for v1.0

The §1 competitive target says "feature and speed parity with
Macrium Reflect at the imaging tier." Concretely, for v1.0 OSS
release:

| Macrium feature | Our v1.0 plan | Architecture mapping |
|---|---|---|
| Full disk + partition imaging (bootable VHDX/VHD) | **YES** | `backup-image` worker, §6.2 |
| Incremental imaging via Changed Block Tracking | **YES, and via documented OS API rather than a kernel driver** | USN V4 + ALLOCATED_RANGES, §6.7. We deliberately reject Macrium's minifilter-driver approach — we get equivalent CBT semantics from documented NTFS primitives. |
| Rapid Delta Restore (block-level fast restore) | **YES** | `backup-image` restore mode reverses the chunk-CBT manifest — only writes blocks that differ from current dst state. Same primitive as backup-mirror's existing torn-recovery path scales to restore direction. |
| Mount image as virtual drive (browse without restore) | **YES** | `backup-image` + `windows::Win32::Storage::Vhd::AttachVirtualDisk`. For file-tier snapshots, separate `backup-file mount` worker via WinFsp (§6.4). |
| Verify image integrity | **YES** | rustic_core `check` for file tier; per-chunk SHA-256 + sidecar manifest hash for image tier. |
| AES-256 encryption at rest | **YES** | Inherited from rustic_core (file tier); separate symmetric encryption layer for VHDX image tier. |
| Compression (configurable) | **YES** | rustic_core zstd (file tier); zstd on chunk writes in image tier. |
| Scheduled backups | **YES** | Backup Server's job DAG (§5.2), replacing Macrium's scheduler and Windows Task Scheduler both. |
| VSS integration | **YES** | Built into every read-path worker; not optional. §5.2/§6.0 — VSS lives in the orchestrator. |
| WinPE / Linux rescue boot media | **YES, post-MVP — necessary for OSS credibility** | Native Boot VHDX restore covers the common case (§6.2). A WinPE-based recovery ISO is required for "C: drive is dead" scenarios and must ship by v1.0. Build target: small WinPE image with backup-server + backup-image embedded, fetches manifest from D:\ replica. |
| ViBoot (instantly boot image as VM for test/recovery) | **STRETCH** | VHDX is a native Hyper-V format. With Hyper-V or a free hypervisor (VirtualBox supports VHDX read since 6.0), this is mostly orchestration. Add a `backup-image vmboot` command that creates the VM definition and starts it. Not a v1.0 blocker, but the gap with Macrium narrows the demo. |
| Image Guardian (ransomware protection for backup files) | **YES, simpler form** | Backup destination repo path is owned by a dedicated low-privilege service account; user account has read-only access. Ransomware running as the user can't damage the backup. Optional: filesystem-filter-based write protection if Windows ever exposes a sane API. |
| Cloning (live disk-to-disk) | **STRETCH** | `backup-image --restore-target=physical-disk` covers it via the existing imaging primitives. Not a v1.0 priority but practically free given the rest of the stack. |
| Differential imaging (vs. incremental) | **NO** | Modern CBT incrementals make differentials a less useful feature. Document why we skip it. |
| Site Manager (central multi-machine management) | **NO (out of v1.0)** | Single-machine first. Multi-machine roadmap deliberate. |
| PXE Boot Rescue | **NO** | Out of scope; small-scale operator use case. |

**Speed parity targets** (measured on this host's actual workload
as the operator's benchmark):

| Workload | Macrium-class target | Our path to it |
|---|---|---|
| First full image of 2.7 TB system | ≤ source disk's sequential read throughput × duration | NTFS sparse-allocated-range awareness (§6.7) brings us to "as fast as the OS will sustain reads of the allocated blocks" |
| Incremental image, 99% unchanged | minutes, proportional to delta | USN V4 + ALLOCATED_RANGES, §6.7 — same primitive Macrium uses (CBT), via documented API instead of a driver |
| Restore 2.7 TB image, 5% blocks need write | minutes, proportional to delta | Reverse-direction chunk-CBT (kopia-c90 pattern), only writes blocks that differ from current target state |
| Nightly file-tier backup of unchanged C:\ | seconds | USN journal V2/V3 (file-level) skips clean-file hash pass entirely |
| Browse snapshot to extract one file | seconds to mount, instant browse | WinFsp + rustic_core's snapshot tree walk — already fast in rustic upstream |

### 8.2 Out of scope, period (until well after v1.0)

These are explicitly NOT in the unified-system roadmap, at least
until v1.0:

- **Cloud backends** (S3, Azure, GCS, B2). Local + LAN replica
  only for v1. Cloud is what kopia already does well; reach for it
  later or stay in the "local-first, optional cloud later" lane.
- **Multi-machine fleet management** / Site Manager. Single-machine
  first. The Backup Server is per-machine, not central.
- **Remote management / web dashboard**. Local UI + CLI only.
- **Linux/macOS in v1.0**. Windows-first, deliberate (Linux
  imaging composes `partclone` + bootloader per §6.6; macOS
  bootable image is impossible per Apple's design).
- **Kopia format byte-compatibility writing** (vs. reading). Read
  for migration; write only in native (restic) format.
- **Differential imaging** as a separate operation from
  incrementals. Modern CBT obviates it.
- **PXE Boot Rescue**. Niche, deferred indefinitely.

## 9. Decision log

| Date | Decision | Why | Status |
|---|---|---|---|
| 2026-05-14 | Long-term goal: Rust-native unified Windows backup tool, open-source target | User vision after DR + architecture audit | Active vision |
| 2026-05-14 | Migration strategy: Ship of Theseus, workers replaced one-by-one | Current stack works; big-bang rewrites die from divided attention | Active |
| 2026-05-14 | `D:\BackupMonitorIndex` stays on D: | Recovery infrastructure — must survive C: failure (lesson 4.8) | Settled |
| 2026-05-14 | Backup Server (`kopia-0dr`) is the next-investment epic | Required scaffolding for any worker-replacement work | Active |
| 2026-05-14 | Kopia-based production stack stays alive throughout the rewrite | User local DR commitment | Settled |
| 2026-05-14 | Window scope first; Linux/macOS deferred | Match user's actual environment, narrow v1 | Active |
| 2026-05-14 | Apache-2.0 license preference (TBC) | Compat with kopia, common in Rust crypto ecosystem | Tentative |
| 2026-05-14 | File-tier foundation: embed `rustic_core` at pinned release (`=0.11.x`), Cargo.lock committed, never track main | Code+architecture review confirmed quality (typestate API, streaming I/O, structured errors, library-first design, Apache/MIT no-CLA). Bus factor of 1 mitigated by restic-format compatibility (emergency exit via restic). Saves 6-18 months of reimplementation. | Settled |
| 2026-05-14 | VSS integration lives in our orchestrator, not in rustic_core | LocalSource takes a path; we hand it the shadow-copy mount root. Matches restic-the-CLI pattern. No fork needed. | Settled |
| 2026-05-14 | NTFS ACL / ADS / reparse / sparse handling via upstream PR (opt-in `windows_metadata` field on `Metadata`) | Issue #19 is `help wanted`. Apache/MIT no CLA. Opt-in preserves restic format compat when absent. | Settled |
| 2026-05-14 | Fork-as-fallback: if upstream stalls 3+ months on the Windows metadata PR, fork ONLY `backend/node.rs`, `backend/local_destination.rs`, `Metadata` — never the whole crate | Keeps upstream merge surface minimal; everything else continues to flow from upstream. | Settled |
| 2026-05-14 | File-tier workers ship as ONE binary `backup-file` with subcommands (snapshot, restore, verify, prune, list, find, mount), not five separate binaries | Single rustic_core link, fewer signed artifacts, matches kopia + rustic CLI shapes, the worker contract handles it uniformly | Settled |
| 2026-05-14 | Query workload runs in a persistent `backup-file --query-mode` worker; mutation workers spawn per-job | Server stays slim and data-blind; UI gets fast snapshot-tree / search responses without per-click repo-open cost; transcribes KopiaServer's pattern to our own architecture | Settled |
| 2026-05-14 | Backup-Monitor.exe never embeds rustic_core; talks to server over HTTP/named-pipe only | Keeps UI thin, testable against a mock server, replaceable (web/CLI/mobile) without touching control plane | Settled |
| 2026-05-14 | Backup Server itself never embeds rustic_core; all repo reads/writes go through workers | Keeps the control plane data-blind; preserves the "control plane manages, worker plane works" boundary | Settled |
| 2026-05-14 | Snapshot mount worker (`backup-file mount` via WinFsp on Windows, FUSE on Linux) is in scope mid-phase | Critical for restore browsing without full extract; user-visible value-add the backup-monitor UI will showcase | Tentative |
| 2026-05-14 | ECC sidecar files for primary repo bit-rot defense — pending evaluation | Restic format has no built-in ECC; chunk-CBT replica catches divergence after the fact. Defense in depth might warrant an `*.ecc` sidecar layer. Beads issue needed. | Open |
| 2026-05-14 | Snapshot policies (retention, hooks, scheduling) are stored in Backup Server config, NOT in the rustic_core repo | Restic format has no policy concept; we own the policy layer in our server; lets us evolve policy without touching repo format | Settled |
| 2026-05-14 | wbadmin replacement strategy: build our own `backup-image` worker in Rust | All pieces exist (`windows::Win32::Storage::Vhd` for VHDX, `windows::Win32::Storage::Vss` for snapshots, `ntfs` crate for sparse reads, shell out to `bcdboot.exe` for BCD); buildable in weeks not months | Tentative |
| 2026-05-14 | macOS bootable-image is explicitly out of scope (Apple's design forbids it) | Document as platform limit in OSS readme | Settled |
| 2026-05-14 | Linux `backup-image` worker will compose `partclone` + bootloader rather than be one binary | No "give-me-a-bootable-image" syscall exists on Linux; Clonezilla is a curated assembly, not a library | Tentative |
| 2026-05-15 | AV exclusions at install time must cover BOTH live-volume and VSS-shadow path namespaces (`\Device\HarddiskVolumeShadowCopy*\<rel>\*` in bare-NT form for BD-style consumer AVs) | Empirically verified `kopia-bhw`: live-volume exclusions do not propagate to shadow-access paths; DOS-namespaced (`\\?\GLOBALROOT\...`) is silently ignored | Settled (BD-confirmed; pattern likely generalizes to other AVs but unverified) |
| 2026-05-15 | Wrapper / Backup Server must align destination dated folder to source BEFORE invoking workers that key by basename | `kopia-8fc`: wbadmin's nightly folder rotation otherwise triggers full re-mirror every night | Settled |
| 2026-05-15 | Backup Server install must set explicit `<Priority>5</Priority>` (Normal) on every scheduled task it manages | `kopia-8ag`: Task Scheduler default is BelowNormal, propagates to all children, silently throttles I/O 2-3× | Settled |
| 2026-05-15 | Adopt `FSCTL_USN_TRACK_MODIFIED_RANGES` + `USN_RECORD_V4` as the primary change-detection primitive for the file-tier worker; `FSCTL_QUERY_ALLOCATED_RANGES` for sparse-file preflight; reject Hyper-V RCT | Plain NTFS, no Hyper-V dependency, byte-range granularity, documented stable APIs; turns 80-minute VHDX hash passes into minutes-proportional-to-delta. See §6.7. Closes RCT as a dead end. | Settled |
| 2026-05-15 | Worker contract is structured JSON-over-HTTP (or named-pipe), never magic-string log parsing | `kopia-wp4`: producer/consumer separator-format drift silently broke the dashboard's replica-OK signal for 4 nights post-cutover. The new contract eliminates this class. | Settled (already implied by §5.3; explicit now) |
| 2026-05-15 | Intra-file pipeline parallelism (rehash producer thread + main-loop consumer + bounded crossbeam channel) is the canonical pattern for any worker phase that reads two disjoint physical disks; multi-threaded hashing and cbt-mode file-level parallelism are explicitly rejected | `kopia-c90` landed this pattern in backup-mirror; the `backup-image` worker should inherit it. Multi-threaded hashing is CPU-side overkill (SHA-256 already 2.5× faster than I/O); cbt-mode file parallelism causes head thrash on spindle destinations | Settled |
| 2026-05-15 | Personal-stack codebase will be frozen at `personal-v1-frozen` once it sustains 14 consecutive green nights, no open P1s, BD/priority/signing-setup all documented for fresh-host rebuild; OSS-dev branch line starts thereafter, runs parallel-eval against synthetic + replica shadow, never touches operator's data | Separates operator-data-safety from OSS-dev-stability so neither blocks the other; canonical Ship-of-Theseus pattern applied at codebase scope rather than worker scope (§7.1) | Active vision |
| 2026-05-15 | OSS-dev v1.0 competitive target: feature and speed parity with Macrium Reflect at the imaging tier and with kopia/restic at the file tier; explicit Macrium feature matrix and speed targets recorded in §8.1 | Concretizes the §1 vision into a measurable bar; clarifies what we WILL build (imaging, CBT, mount, rescue media, encryption, ransomware-resistant repo) vs WON'T (Site Manager, PXE, differential, cloud-in-v1) | Active vision |

## 10. References

- `ARCHITECTURE.md` — current as-built inventory.
- `SECRETS.md` — secrets layout + recreate procedure.
- Memory: `feedback-index-must-stay-on-d`,
  `feedback-backup-tooling-rust-default`, `feedback-ps51-utf8-bom`,
  `reference-bd-boxter-kopia`, `reference-backup-architecture`,
  `reference-bd-shadow-copy-exclusion` (added 2026-05-15),
  `reference-taskscheduler-priority-default` (added 2026-05-15).
- Beads: `kopia-a4i` (this vision), `kopia-0dr` (Backup Server epic),
  `kopia-bmy` (replica cutover), `kopia-02h` (scrub brace-eating),
  `kopia-bmy.6` (BD Boxter heuristic), `kopia-bmy.7` (verify
  finally-block crash), `kopia-1yn` + `kopia-2xy` (DR hardening).
- 2026-05-15 session beads:
  - Closed: `kopia-8j4` (preflight dst-size), `kopia-sto` (walk
    don't bail), `kopia-8fc` (wbadmin dst-folder alignment),
    `kopia-bhw` (BD shadow-copy exclusion), `kopia-c90` (pipeline
    torn-recovery), `kopia-wp4` (parser separator),
    `kopia-44w` (RCT, superseded by USN V4).
  - Open: `kopia-8ag` (apply Priority=5 to all `\Backup\` tasks),
    `kopia-61n` (USN V4 range tracking), `kopia-dyj`
    (`FSCTL_QUERY_ALLOCATED_RANGES`), `kopia-0cj` (file-level
    parallelism for blob mode), `kopia-10r` (alignment-log gap),
    `kopia-xl2` (rehash producer silent emit).
- External:
  - kopia: <https://github.com/kopia/kopia>, <https://kopia.io>
  - rustic: <https://github.com/rustic-rs/rustic>
  - rustic_core: <https://github.com/rustic-rs/rustic_core>
  - Macrium Reflect: <https://www.macrium.com> (proprietary;
    inspiration only)
  - Microsoft VHDX spec: MS-VHDX
    (<https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-vhdx/>)
