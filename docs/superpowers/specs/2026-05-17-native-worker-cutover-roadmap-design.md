# Native Worker Cutover — Program Roadmap

- **Date:** 2026-05-17
- **Status:** Approved (design)
- **Tracking epic:** `kopia-0dr` (Backup Server) → feeds `kopia-a4i` (kopia-rewrite)
- **Supersedes pacing in:** `architecture-vision.md` §7 (Ship-of-Theseus
  soak gates are accelerated — see §4 below)

## 1. Goal & end state

Retire the entire legacy worker layer — `daily_kopia_backup.cmd`,
`daily_d_replica.ps1`, `weekly_replica_verify.ps1`, `verify_backups.cmd`,
**and `wbadmin`** — replacing each with a native Rust worker orchestrated
by `backup-server`.

End state: a control plane (`backup-server`) + a native worker plane +
a thin UI (`backup-monitor`), with **no PowerShell/cmd in the backup
path and no `kopia.exe` or `wbadmin` dependency**. One stack to debug
and enhance.

This roadmap is a program plan. Each sub-project below gets its own
spec → implementation plan → build cycle; this document fixes the
scope, sequencing, and cutover mechanics for all of them.

## 2. The six sub-projects

| # | Sub-project | Retires | Core work |
|---|---|---|---|
| **0** | New-stack stabilization | — | Fix `kopia-0dr.28` (P0 worker-join deadlock), `.29` (P1 orphan-sweep clobber); land stall-watch `.23/.24/.25` |
| **1** | Native replica | `daily_d_replica.ps1` | `backup-mirror` speaks the worker contract (structured progress events on stderr); `backup-server` invokes it directly; the script's preflight (ACL checks, flag files, heartbeat) moves into job config / the worker |
| **2** | Native verify | `weekly_replica_verify.ps1`, `verify_backups.cmd` | `backup-verify` worker with two modes — replica-verify (repository check against `E:`) and image-verify (VHDX integrity) |
| **3** | Native file snapshot/restore | `daily_kopia_backup.cmd` + the `kopia.exe` dependency | `backup-filecopy` binary embedding pinned `rustic_core`; subcommands snapshot/restore/verify/prune/list/find/mount; Windows metadata layer (ACL/ADS/reparse/sparse — `architecture-vision.md` §6.0); VSS shadow-copy handoff; long-running `--query-mode` worker (§5.6). **Decomposes into its own spec.** |
| **4** | Native block image | `wbadmin` | `backup-blockcopy` worker — VHDX from VSS (`windows::Win32::Storage::{Vhd,Vss}` + the `ntfs` crate + shelling to `bcdboot`; §6.2); chunk-CBT incrementals reusing `backup-mirror` |
| **5** | USN change-tracking speed layer | — | Per-volume USN cursor persisted in `backup-server`; hands each worker a changed-file/range hint (`kopia-1tr`, `kopia-61n`); the hint is a speed signal, never ground truth — workers fall back to a full pass when the journal can't prove cleanliness |

> **Topology note (2026-05-17).** The RustBack end state is the
> 5-executable topology in `architecture-vision.md` §5.7:
> `backup-server` + `backup-monitor` + `backup-blockcopy` +
> `backup-filecopy` + `backup-mirror`. `backup-indexer` and
> `backup-dump` are *not* workers — they fold into `backup-server`
> as in-process modules; `backup-server-tray` folds into
> `backup-monitor`. Build/test for all of this is tracked by beads
> `kopia-0dr.37`–`.45`.

## 3. Sequencing

Strict serial by difficulty: `0 → 1 → 2 → 3 → 4 → 5`. Each sub-project
is built and cut over before the next begins.

## 4. Cutover gates (accelerated)

The fixed multi-night soak gates of `architecture-vision.md` §7 are
**dropped** in favour of an accelerated, fix-forward model. Per worker:

1. Build, with synthetic-fixture tests passing. The operator's real
   data is never the test bed.
2. **One** parallel-eval sanity run — old + new worker on the same
   input, diff the outputs.
3. **Cut over immediately** — the new worker becomes the primary
   scheduled path.
4. The legacy script stays **on-disk and manually runnable** as a
   diagnostic/emergency fallback — not scheduled, not deleted.
5. Move to the next sub-project as soon as the current one is cut
   over. No soak counter.
6. Delete the legacy script only once the operator is explicitly
   confident.

Default posture on a failed night is **fix-forward** on the new stack,
not revert. The legacy worker exists to diagnose or to get a backup
done in an emergency, not as the standing path.

## 5. Today's cutover

**No rollback.** The `BackupServerWaker-*` scheduled tasks stay
enabled; the new stack is the primary backup path tonight and onward.

Today:

- **Sub-project 0 bug-fixes land today** — `kopia-0dr.28` (worker
  reader-thread join deadlock) and `kopia-0dr.29` (orphan-sweep
  clobbers concurrently-running jobs) — so tonight's run is sound.
  Stall-watch (`kopia-0dr.23/.24/.25`) follows immediately after.
- The four legacy scheduled tasks (`DailyKopiaSnapshotV2`,
  `DailyDReplica`, `WeeklyReplicaVerify`, `WeeklyBackupVerify`) stay
  **Disabled but on-disk** — the diagnostic/emergency fallback,
  re-runnable by hand or re-enableable if a night fails.

## 6. Timeline reality

Acceleration removes the ~60 nights of soak; it does not remove build
time.

| Sub-project | Build effort |
|---|---|
| 0 | today |
| 1 | days |
| 2 | ~a week |
| 3 | **multi-week** — net-new `rustic_core` embed + Windows metadata layer |
| 4 | **multi-week** — net-new VHDX-from-VSS imaging, no upstream to inherit |
| 5 | medium |

Full retirement of all five legacy pieces is realistically several
weeks out, dominated by sub-projects 3 and 4. Each worker is cut over
the moment it is ready; the legacy stack shrinks one worker at a time.

## 7. Per-sub-project scope sketches

### 0 — New-stack stabilization
Fix the two bugs the 2026-05-17 soak-night-1 surfaced (`kopia-0dr.28`,
`.29`) plus land the stall-watch beads (`.23` file-mtime-growth, `.24`
child-CPU-advance, `.25` enable in `jobs.toml`). Acceptance: the new
stack orchestrates the existing legacy workers with no hangs and no
run-state corruption, stall-watch active. The beads are already
implementation-ready; this sub-project may skip a separate spec.

### 1 — Native replica
`daily_d_replica.ps1` is already a thin orchestration wrapper around
the Rust `backup-mirror`. Work: `backup-mirror` emits `Event::Progress`
JSONL on stderr (worker contract); `backup-server` runs it as a
`structured` worker directly; the script's preflight responsibilities
(E:\ ACL state, `BACKUP_REPLICA_FAIL.flag`, heartbeat) are relocated
into the worker or job config. Acceptance: one parallel-eval run shows
identical `E:` trees vs the script; cut over; retire the `.ps1`.

### 2 — Native verify
A `backup-verify` worker replacing `weekly_replica_verify.ps1` (replica
repository check against `E:`) and `verify_backups.cmd` (wbadmin VHDX
integrity). Two verify modes behind one binary.

### 3 — Native file snapshot/restore
`backup-filecopy` binary embedding `rustic_core` at a pinned exact version
(`architecture-vision.md` §6.0). Subcommands snapshot/restore/verify/
prune/list/find/mount. Windows metadata (ACL/ADS/reparse/sparse) via an
upstream PR to `rustic_core` or a surgical fork of the three relevant
modules. VSS shadow-copy mount root handed to `LocalSource` by the
orchestrator. A single long-running `backup-filecopy --query-mode` worker
serves UI reads (§5.6 decision b). This sub-project is large enough to
warrant its own brainstorm + spec before implementation.

### 4 — Native block image
`backup-blockcopy` worker producing a bootable VHDX from a VSS snapshot —
`windows::Win32::Storage::{Vhd,Vss}`, the `ntfs` crate, shelling to
`bcdboot` for the boot record (§6.2). Incrementals via the
`backup-mirror` chunk-CBT engine. Acceptance includes one verified
bare-metal restore-boot before `wbadmin` is retired.

### 5 — USN change-tracking speed layer
Per-volume USN journal cursor (`{journal_id, next_usn}`) persisted in
`backup-server` state; the server hands each worker the set of files
and byte ranges that may have changed since the last run. Workers treat
it as a hint and fall back to a full pass on journal wrap / id
mismatch / first run. Builds on the open beads `kopia-1tr` and
`kopia-61n`.

## 8. Risks

- **`rustic_core` API churn** — mitigated by pinning an exact version,
  committing `Cargo.lock`, and ratcheting tests through each minor
  bump deliberately. Never track `main`.
- **Windows-metadata fidelity** in the file tier — security
  descriptors, ADS, reparse points, sparse files must survive a
  snapshot/restore round-trip.
- **`backup-blockcopy` is net-new** — no upstream imaging engine to
  inherit; VHDX + VSS + boot-record correctness is all our code.
- **Synthetic fixtures must be trustworthy** — the operator's real
  data is never the test bed, so fixture quality is load-bearing for
  every parallel-eval.

## 9. Next steps

Sub-project 0 is planned and built today (its beads are already
implementation-ready). Sub-projects 1, 2, 4, 5 each get an
implementation plan; sub-project 3 gets its own brainstorm + spec
first. Each cut over per §4 the moment it is ready.
