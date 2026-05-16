# Handoff — Tree B rsync hang diagnosis (needs elevated shell)

**Session date:** 2026-05-13
**Status:** Implementation complete, production smoke test partially worked, Tree B hung
**Beads:** `kopia-vzu` (follow-up fix), `kopia-8tn` (epic, all 3 stages closed)

## TL;DR for the elevated session

The `magical-cooking-jellyfish` plan (kopia-8tn) is fully
implemented + committed + pushed to `fork/master`. The first
production smoke test (`schtasks /Run /TN \Backup\DailyDReplica`
at 2026-05-13 12:00:37) revealed:

- **Tree A works perfectly**: kopia repo synced in 60 seconds,
  only 6 MB transferred for a 2.34 TB scan.
- **Tree B hung**: emitted exactly one itemize line
  (`.d..t...... ChrisLaptop2/Backup 2026-05-13 090023/`) at
  12:01:59, then 4 hours of silence, then was killed externally.
  No `[done]` line, no FAIL flag from this run, VSS junction
  orphaned.

The likely cause is that without `--link-dest` (graceful first-run
fallthrough), rsync's `--no-whole-file --inplace` quick-check was
defeated by mtime drift between the VSS-shadow source and the
E: destination, falling into a silent multi-hour rolling-checksum
read pass on the multi-GB VHDXes.

## Why you need elevation

From the non-elevated shell, I could not:

- `Get-Acl 'D:\WindowsImageBackup\ChrisLaptop2'` → "Attempted to
  perform an unauthorized operation."
- `icacls 'D:\WindowsImageBackup\ChrisLaptop2'` → "Access is
  denied."
- `Get-ChildItem 'D:\WindowsImageBackup\ChrisLaptop2'` past first
  level → "Access to the path ... is denied."
- Launch `C:\cwrsync\bin\rsync.exe` (ACL: `Read, Synchronize`
  only for `david`; `FullControl` for Administrators/SYSTEM).

The scheduled task runs as `CHRISLAPTOP2\david` with
`RunLevel=HighestAvailable`, so it gets the admin token via UAC
that an interactive shell doesn't have by default. An elevated
PowerShell will be able to do everything rsync could, which is
exactly what we need for repro.

## Goal of the elevated diagnosis

Confirm or refute the **mtime drift / silent rolling-checksum**
hypothesis. Specifically:

1. **Compare source-vs-destination mtimes** on the wbadmin VHDX
   files. If they drift by even sub-seconds, `--modify-window=2`
   is the fix.
2. **Reproduce the hang in a small isolated rsync run** so we can
   capture exactly where it blocks.
3. **Decide whether to ship `--modify-window=2` + `--info=name`
   patches before tomorrow's 05:00 scheduled run** or just let
   the run proceed (since `--link-dest` will engage tomorrow and
   should sidestep the quick-check question entirely).

## Diagnostic commands to run (in the elevated PowerShell)

### 1. Quick state check

```powershell
# Confirm elevation
$current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
"Elevated: $($current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
# Expected: True

# Walk to the destination dated folder and inspect each VHDX
$dst = 'E:\WindowsImageBackup\ChrisLaptop2'
Get-ChildItem $dst -Directory -Filter 'Backup *' | Sort-Object Name -Descending |
    Select-Object -First 1 | ForEach-Object {
        Write-Host "Folder: $($_.Name)  mtime: $($_.LastWriteTime.Ticks) ticks"
        Get-ChildItem $_.FullName -Filter '*.vhdx' |
            Select-Object Name, Length, @{n='MtimeTicks';e={$_.LastWriteTime.Ticks}}, LastWriteTime |
            Format-Table -AutoSize
    }
```

### 2. Compare source (VSS-shadow) vs destination mtimes

The orphan junction from the hung run may still be live (it was as
of the previous session — see check below). If it's gone, take a
fresh VSS shadow.

```powershell
# Check if the orphan junction is still pointing at a live shadow
$junction = Get-ChildItem 'C:\Users\david\AppData\Local\Temp' -Directory -Filter 'kopia-replica-shadow-*' -EA SilentlyContinue |
            Select-Object -First 1
if ($junction) {
    Write-Host "Orphan junction: $($junction.FullName)"
    # Test readability — should NOT hang
    Get-ChildItem "$($junction.FullName)\WindowsImageBackup\ChrisLaptop2" -Directory -EA SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 | ForEach-Object {
            Write-Host "Source dated folder: $($_.Name)  mtime: $($_.LastWriteTime.Ticks) ticks"
            Get-ChildItem $_.FullName -Filter '*.vhdx' |
                Select-Object Name, Length, @{n='MtimeTicks';e={$_.LastWriteTime.Ticks}}, LastWriteTime |
                Format-Table -AutoSize
        }
} else {
    Write-Host "No orphan junction — need fresh VSS shadow (run the diagnose-replica.ps1 helper if needed)"
}
```

**What to look for:** If destination MtimeTicks ≠ source MtimeTicks
(even by < 1 second), that's evidence for the drift theory.

### 3. Minimal rsync repro with verbose output

If the source junction is still readable, do a tiny rsync that
mimics Tree B but with extra verbosity and a list-only mode (no
actual transfer) to bisect where the hang lives:

```powershell
$rsync = 'C:\cwrsync\bin\rsync.exe'
$srcCyg = '/cygdrive/c/Users/david/AppData/Local/Temp/' +
          ($junction.Name) + '/WindowsImageBackup/'
$dstCyg = '/cygdrive/e/WindowsImageBackup/'

# Phase A: just enumerate, no transfer
& $rsync --recursive --links --times --list-only -vv `
    "$srcCyg" "$dstCyg" 2>&1 | Tee-Object -FilePath "$env:TEMP\rsync-list-only.log" |
    Select-Object -First 50
```

If `--list-only` completes quickly, the hang is in the
transfer/delta phase, not the file-list build.

```powershell
# Phase B: actual mirror with extra verbosity (DRY-RUN, no destination changes)
& $rsync --recursive --links --times --inplace --no-whole-file `
    --delete-after --dry-run --info=name,progress2,stats2 -vv `
    "$srcCyg" "$dstCyg" 2>&1 | Tee-Object -FilePath "$env:TEMP\rsync-dryrun.log"
```

`--dry-run` means no actual writes, but rsync still does the
quick-check decisions. The per-file output should show exactly
which files rsync decides to transfer (and therefore which files
have mtime/size mismatches).

### 4. Test `--modify-window=2` to see if it changes the decisions

```powershell
# Same dry-run + --modify-window=2 — if this reduces the "to transfer" list, we have our fix
& $rsync --recursive --links --times --inplace --no-whole-file `
    --delete-after --dry-run --modify-window=2 --info=name,progress2,stats2 -vv `
    "$srcCyg" "$dstCyg" 2>&1 | Tee-Object -FilePath "$env:TEMP\rsync-dryrun-mw2.log"
```

Diff the two log files — if the `+++++++` (whole-file) lines drop
when `--modify-window=2` is added, the drift theory is confirmed.

## Cleanup before tomorrow's 05:00 run

Regardless of diagnosis, do this housekeeping:

```powershell
# 1. Clear stale FAIL flag (it's from the 11:46 dry-run, not the 12:00 hung run)
Remove-Item -LiteralPath 'C:\dev\kopia\logs\BACKUP_REPLICA_FAIL.flag' -Force -EA SilentlyContinue

# 2. Sweep the orphan VSS junction (preflight WILL do this, but doing now avoids
#    confusion if you re-run diagnostics)
Get-ChildItem 'C:\Users\david\AppData\Local\Temp' -Directory -Filter 'kopia-replica-shadow-*' -EA SilentlyContinue |
    ForEach-Object {
        # Junction is a SymbolicLink (ReparsePoint) — remove with rmdir, not rm -recurse
        cmd /c "rmdir `"$($_.FullName)`""
    }

# 3. Confirm scheduled task is ready for 05:00 trigger
schtasks /Query /TN "\Backup\DailyDReplica" /FO LIST /V | Select-String 'Status|Next Run'
# Expected: Status=Ready, NextRunTime=5/14/2026 5:00 AM
```

## Decision point: edit the script or wait?

**Option A — Edit + re-sign + let 05:00 run test the patched code:**

Edit `scripts/daily_d_replica.ps1` Tree B rsync args (around line
407–416) to add:

```powershell
$rsyncArgsB = @(
    '--recursive'
    '--links'
    '--times'
    '--inplace'
    '--no-whole-file'
    '--delete-after'
    '--modify-window=2'                          # NEW: tolerate mtime drift
    '--info=name,progress2,stats2'               # CHANGED: per-file visibility
    "--log-file=$rsyncLog"
)
```

Then `pwsh.exe -ExecutionPolicy Bypass -File signing\sign-all.ps1`
to re-sign. Commit + push.

**Option B — Wait for 05:00 with current code:**

With two wbadmin dated folders on E: by then,
`Get-PriorWbadminFolder` returns yesterday's basis, `--link-dest`
engages, and rsync hardlinks identical files via metadata
(skipping the quick-check question entirely). This is the design
the plan was actually optimized for. Today's smoke test was off
the happy path because we only had one folder.

**Recommendation:** Option B if diagnosis confirms link-dest will
engage tomorrow (i.e., E: still has the 2026-05-13 folder, source
D: produces a new 2026-05-14 folder at 02:00 wbadmin), and we
trust the design. Option A if you want defense-in-depth and don't
mind one more re-sign cycle.

## Useful paths and IDs

| Item | Value |
|------|-------|
| Repo | `C:\dev\kopia` |
| Script | `scripts\daily_d_replica.ps1` |
| Replica log | `C:\dev\kopia\logs\daily_d_replica.log` |
| rsync sub-log | `C:\dev\kopia\logs\daily_d_replica.log.rsync` |
| Daily kopia log | `C:\dev\kopia\logs\daily_kopia.log` |
| FAIL flag | `C:\dev\kopia\logs\BACKUP_REPLICA_FAIL.flag` (stale, clear it) |
| backup-dump | `C:\dev\backup-monitor\target\release\backup-dump.exe` |
| Scheduled task | `\Backup\DailyDReplica` (next run 5/14 05:00) |
| Bead epic | kopia-8tn (closed) |
| Bead bug   | kopia-vzu (open, P2) |
| Last commit | 7910caff (pushed to fork/master) |
| Today's hung-run trigger time | 12:00:37 (Last Result 267014 = SCHED_S_TASK_TERMINATED) |

## Files NOT to touch unless deliberately changing

These are signed and verified in the pre-push hook:

- `scripts/daily_d_replica.ps1` — any edit invalidates signature; must re-sign before push
- `scripts/weekly_replica_verify.ps1` — same
- All other `scripts/*.ps1` — same

The pre-push hook (`Makefile.local.mk` / `prepush-check`) verifies
signatures match HEAD; if you edit a script and forget to re-sign,
the push will fail with a clear message.

---

**When you restart:** read this file, then resume diagnosis from
section "Diagnostic commands to run." The first command to run is
the elevation check, then proceed top-to-bottom through sections 1–4.

---

## Postmortem (2026-05-13 elevated session, commit 3e987f49)

The elevated diagnosis ran. The mtime-drift hypothesis above is
**refuted**. The real cause is different and matters for future
change-block-tracking design.

### What the section-2 comparison actually found

Source (live VSS shadow on D:, `HarddiskVolumeShadowCopy35`) vs
destination (`E:\WindowsImageBackup\ChrisLaptop2\Backup 2026-05-13 090023`):

| File | Src size | Dst size | Δ size | Δ mtime |
|---|---|---|---|---|
| `5efa1bda-….vhdx` | 1,119,879,168 (1.12 GB) | same | 0 | **0 ticks** (exact) |
| `Esp.vhdx` | 207,618,048 (208 MB) | same | 0 | **0 ticks** (exact) |
| `d88fe253-….vhdx` | 2,816,722,599,936 (2.82 TB) | 1,688,441,192,448 (1.69 TB) | **−1.13 TB** | **+7h 51m** (dst newer) |

Two of three VHDXes had zero-tick mtime agreement and identical size.
`--modify-window=2` would have changed nothing for them, and would
not have changed the decision on the third either (size mismatch alone
forces transfer).

### Real cause of the "hang"

`d88fe253-….vhdx` on E: was a **1.69 TB partial write** left over from
the 12:00 run when it was externally killed at ~10:37 AM (dst mtime
matches kill time). The 12:00 invocation ran `rsync --inplace
--no-whole-file` against a destination 1.13 TB smaller than the
source. Under `--inplace --no-whole-file`, rsync does not retransfer
whole files; it computes rolling checksums on the existing destination
file and the source file to find matching blocks, then writes only the
deltas in place.

For multi-TB VHDXes, that "delta computation" is itself a multi-hour
read pass: rsync has to read the entire 1.69 TB destination plus the
entire 2.82 TB source to align blocks. At the existing `--info`
verbosity (`stats2,progress2` only, no `name`), per-file progress is
not emitted until the file completes — so a 4-hour delta read pass
looks identical to a hang.

It was working, not hung. The 4 hours of silence was rsync grinding
through 4.5 TB of rolling-checksum I/O without surfacing per-file
progress.

### Why this rules out the original fix and motivates CBT

- **`--modify-window=2` is the wrong knob.** It only relaxes mtime
  comparison; mtimes were already exact on the unchanged files and
  the changed file failed quick-check on size, not mtime.
- **`--whole-file` would skip the rolling-checksum step**, but trades
  4.5 TB of read I/O for 2.82 TB of write I/O on the destination every
  run where the file changed at all. That doesn't help long-term.
- **`--link-dest` works only when there's a prior intact dated folder
  to use as basis.** It hardlinks identical-by-metadata files, which
  is perfect when the wbadmin VHDX hasn't changed between runs but
  useless on the (common) case where the big OS-volume VHDX has
  changed since the last basis.
- **rsync's rolling-checksum mechanism is the wrong tool for the
  multi-TB-VHDX case.** Two specific things make it expensive:
  - **VHDX files are mostly sparse-allocated/zeroed.** The weak
    checksum (Adler-32 derivative) has many false-positive hits in
    zero regions, each triggering a strong-checksum (MD5) read on
    both sides.
  - **rsync has no a-priori knowledge of which blocks actually
    changed.** It has to discover this by reading everything. The
    *filesystem* (or wbadmin itself) actually knows: NTFS USN
    Journal, Hyper-V Resilient Change Tracking (RCT) on `.vhdx`, and
    VSS `IVssBackupComponents::GetWriterMetadata` all expose
    per-extent change information that rsync ignores.

### Implications for a future CBT design

The expensive operation here is "given source.vhdx and dst.vhdx where
dst is a partial/older copy of source, find changed blocks." Things
this postmortem suggests are worth knowing if we ever build our own
CBT layer:

1. **wbadmin already writes VHDX files**, which carry an RCT GUID and
   a parent-changelog when chained — but standalone wbadmin VHDXes
   don't chain, so RCT alone won't help here. We'd need our own
   block index.
2. **The natural unit of change tracking is the VHDX block (typically
   2 MB)**, not the byte. A sidecar `<vhdx>.cbt` file holding a Merkle
   tree of 2 MB-block hashes would let us identify changed blocks in
   ~1.4 GB of hash reads for a 2.82 TB file (vs 2.82 TB of full
   reads). For unchanged files (the common case after a system idle
   night), only the top-level Merkle root differs decision is needed.
3. **The destination "partial file" problem is real and recurs.**
   Any in-place delta scheme has to handle the case where dst was
   truncated mid-write. The CBT design should distinguish "dst is a
   committed snapshot" from "dst is a torn write" — e.g. by writing
   a `<vhdx>.cbt.ok` marker only after the full write+fsync
   completes, and treating absence-of-marker as "discard and start
   over with `--whole-file` semantics."
4. **Observability is non-negotiable.** Whatever runs the per-file
   delta has to emit per-block progress to log so a 2-hour run is
   visibly progressing, not silently consuming I/O. This commit's
   `--info=name` addition is the minimum rsync-side version of that.
5. **The 4.5 TB problem only happens during recovery from a torn
   write.** On a steady-state day where `--link-dest` engages, both
   trees finish in minutes. The CBT layer's value is bounded by how
   often we hit the recovery path — which is "every wbadmin run
   that's been killed or where the prior dst is corrupt." Today's
   smoke test was that case. Tomorrow's run (5/14 05:00) is not.

### Resolution applied this session

1. Surgical delete of the partial `d88fe253-….vhdx` on E: (1.57 TB).
   The two intact small VHDXes on E: were preserved so
   `--link-dest` can hardlink them tomorrow.
2. Swept the orphan VSS junction (`HarddiskVolumeShadowCopy35`).
3. Cleared stale `BACKUP_REPLICA_FAIL.flag` from the 11:46 dry-run.
4. Edited `scripts/daily_d_replica.ps1` to change `--info` from
   `stats2,progress2` to `name,progress2,stats2` on **both** tree A
   and tree B for per-file visibility. Pure observability change.
5. Re-signed the script (commit `3e987f49`, pushed to `fork/master`).
   All 13 signed artifacts verified Valid via the pre-push hook.

### What tomorrow's 05:00 run is expected to do

- wbadmin produces fresh `Backup 2026-05-14 …` on D: at 02:00.
- Tree A (kopia repo): ~60s as observed today.
- Tree B (wbadmin): `--link-dest=Backup 2026-05-13 090023` engages.
  The two small VHDXes and 13 XML metadata files hardlink instantly.
  The big `d88fe253-….vhdx` writes fresh (no basis on E: anymore,
  since we removed the corrupt one). Expect ~2–4 hours at local
  disk speed, this time with per-file rsync progress in
  `daily_d_replica.log.rsync`.
- From 5/15 onward, both VHDXes have valid basis on E: → both
  hardlink → run completes in minutes.

The bead `kopia-vzu` (P2 follow-up) is still open and should be
updated with this finding; the diagnosis fix it described
(`--modify-window=2`) is not what we shipped.

## Final resolution (2026-05-16, epic `kopia-bmy`)

The `--modify-window=2` / rsync-tuning path was abandoned in favor
of replacing rsync entirely with a native Rust chunk-CBT mirror
(`backup-mirror.exe`, repo `C:\dev\backup-monitor`). The hypothesis
that rsync's rolling-checksum mechanism is fundamentally wrong for
multi-TB mostly-zeroed VHDX files held up under deeper analysis:
no rolling-checksum tuning can avoid reading the whole file when
the basis differs by >1 TB from a killed prior run.

Cutover landed in commit `67df89d7` (2026-05-13). `kopia-vzu` was
closed at that time. The new flow:

- One `backup-mirror.exe` invocation per top-level subtree on the
  D:\ shadow (`KopiaRepo`, `WindowsImageBackup`, …).
- 4 MiB chunk-CBT manifests on `C:\BackupMirror\state\` (NVMe,
  isolated from D:/E: I/O).
- `WindowsImageBackup` uses `--manifest-key basename` so wbadmin's
  nightly dated-folder rotation doesn't invalidate matches.
- Replica `summary` line in `daily_kopia.log` carries
  `tool=backup-mirror` plus `chunks_changed`/`chunks_total`.

Post-cutover wall-clock on this host: typically ~1 h end-to-end,
with one ~5.5 h outlier on 2026-05-15 during a torn-recovery rehash
(addressed by bead `kopia-c90`'s producer/consumer pipeline + bead
`kopia-xl2`'s rehash-progress events). 10+ consecutive clean
nightlies as of 2026-05-16.

The 4 h `ExecutionTimeLimit` on `\Backup\DailyDReplica` is
deliberately retained: tightening to 2 h would cover the
steady-state envelope but the torn-recovery outlier shows the
headroom is sometimes used. The scheduled-task XML
(`scripts/scheduled-tasks/DailyDReplica.xml`) is the authoritative
source if a fresh host needs to re-register.

Related closures: `kopia-bmy.1` (probe), `kopia-bmy.2` (build),
`kopia-bmy.3` (parallel-eval, superseded), `kopia-bmy.4` (cutover),
`kopia-bmy.6` (BD exclusions), `kopia-bmy.7`/`kopia-bmy.9`
(finally-block share-violation), `kopia-bmy.8` (ACL workaround),
`kopia-c90` (pipelining), `kopia-ag6`/`kopia-8j4` (trust marker),
`kopia-8fc` (dst alignment), `kopia-10r` (alignment logging),
`kopia-xl2` (rehash progress events).
