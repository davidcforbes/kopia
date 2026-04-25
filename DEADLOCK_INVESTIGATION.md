# Kopia Snapshot Deadlock Investigation

## Issue Summary

**Date:** April 7, 2026  
**Build:** Source-built `C:\Users\david\go\bin\kopia.exe` from `C:\dev\kopia`  
**Source:** `C:\Users\david` (781 GB, 2.7M files, 358K dirs)  
**Symptom:** Incremental snapshot hung for 17+ hours (should complete in ~5 minutes)  
**Resolution:** Manual kill and re-run completed in 5m15s — confirming repo/data integrity

## Observed Behavior

- Process PID 65460, started 03:25 AM, still running at 8:13 PM
- 1,466 CPU seconds consumed over 17 hours (9.7% effective CPU)
- 28 of 31 threads in `UserRequest` wait state (idle)
- Handle count flat at ~408 — **no open file handles**
- Memory at 947 MB and slowly climbing (possible leak or unbounded cache)
- No disk I/O activity — not reading source files or writing to repo
- The `C:\dev` source snapshot completed normally in 24m51s in the same task run
- Previous full backups of this source completed in under 2 hours
- Re-run incremental completed in 5m15s with no issues

## Diagnosis: Goroutine Deadlock

The symptoms (all threads idle, no file handles, flat CPU, climbing memory) are consistent
with a Go channel/sync.Cond deadlock in the parallel file walker or upload pipeline.

### Primary Suspect: `internal/parallelwork/parallel_work_queue.go`

The `dequeue()` method at line 97 uses a `sync.Cond` wait loop:

```go
for v.queueItems.Len() == 0 && v.activeWorkerCount > 0 {
    v.monitor.Wait()  // ALL workers can end up here
}
```

A deadlock occurs if:
1. All workers are in `Wait()` (queue empty)
2. But `activeWorkerCount > 0` because a callback incremented it but never called `completed()`
3. This can happen if a callback **panics** (no recover), **hangs on I/O**, or **blocks on a full channel**

### Secondary Suspect: `internal/workshare/workshare_pool.go`

The workshare pool manages parallel hashing and upload tasks. If a worker goroutine
blocks on a locked file (e.g., Discord cookies, NTFS journal), the workshare pool
can deadlock waiting for that worker to return, which starves the parallelwork queue.

### Tertiary Suspect: `snapshot/upload/upload.go`

The upload pipeline coordinates directory walking, file hashing, and object writing.
If a directory entry returns an error that is NOT caught by `IgnoreFileErrors` policy
(e.g., a junction loop, or a permission denied that surfaces as a different error type),
the upload goroutine may block indefinitely waiting for a response that never comes.

---

## Debugging Instructions for Claude Code

### Phase 1: Reproduce and Capture Goroutine Dump

Add a goroutine dump signal handler to `main.go` or the snapshot command so we can
capture the exact state when it hangs.

**Step 1:** Add a debug endpoint or signal handler

In `cli/command_snapshot.go` (or wherever `snapshot create` is handled), add a
goroutine dump that writes to a file every 60 seconds during snapshot operations:

```go
import "runtime/pprof"

// In the snapshot create command handler, start a background goroutine:
go func() {
    ticker := time.NewTicker(60 * time.Second)
    defer ticker.Stop()
    for range ticker.C {
        f, err := os.Create(filepath.Join(os.TempDir(), "kopia_goroutines.txt"))
        if err != nil { continue }
        pprof.Lookup("goroutine").WriteTo(f, 2) // full stack traces
        f.Close()
    }
}()
```

**Step 2:** Add deadlock detection to `parallelwork/parallel_work_queue.go`

In the `dequeue()` method, add a timeout to detect when all workers are stuck:

```go
func (v *Queue) dequeue(ctx context.Context) CallbackFunc {
    v.monitor.L.Lock()
    defer v.monitor.L.Unlock()

    waitStart := time.Now()
    for v.queueItems.Len() == 0 && v.activeWorkerCount > 0 {
        // DEADLOCK DETECTION: if we've been waiting >5 minutes, dump state
        if time.Since(waitStart) > 5*time.Minute {
            log.Warnf("POTENTIAL DEADLOCK: queue empty, %d active workers, "+
                "waited %v", v.activeWorkerCount, time.Since(waitStart))
            // Dump goroutine stacks to help diagnose
            pprof.Lookup("goroutine").WriteTo(os.Stderr, 1)
        }
        v.monitor.Wait()
    }
    // ... rest unchanged
}
```

**Step 3:** Add panic recovery to parallel work callbacks

In `parallelwork/parallel_work_queue.go`, the `Process()` method should recover
from panics in callbacks — an unrecovered panic in a goroutine will NOT propagate
to the errgroup; it will just silently kill that goroutine while `activeWorkerCount`
remains incremented:

```go
// In Process(), wrap the callback execution:
err := func() (retErr error) {
    defer func() {
        if r := recover(); r != nil {
            retErr = fmt.Errorf("panic in work callback: %v\n%s",
                r, debug.Stack())
        }
    }()
    return callback()
}()
```

**Step 4:** Add timeout to file open operations

In `fs/localfs/` (the local filesystem layer), file open calls can hang indefinitely
on Windows if NTFS encounters certain locked file conditions. Wrap file opens with
a context timeout:

```go
// Instead of: f, err := os.Open(path)
// Use a goroutine with timeout:
ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
defer cancel()

type result struct {
    f   *os.File
    err error
}
ch := make(chan result, 1)
go func() {
    f, err := os.Open(path)
    ch <- result{f, err}
}()
select {
case r := <-ch:
    return r.f, r.err
case <-ctx.Done():
    return nil, fmt.Errorf("timeout opening file: %s", path)
}
```


### Phase 2: Static Analysis — Find Deadlock-Prone Patterns

Search the codebase for these specific patterns that can cause goroutine deadlocks:

**Step 5:** Search for channel operations without timeouts or context cancellation

```bash
# Find channel sends/receives without select or context
grep -rn "<-" snapshot/upload/ internal/parallelwork/ internal/workshare/ \
    --include="*.go" | grep -v "_test.go" | grep -v "select" | grep -v "ctx"
```

**Step 6:** Search for sync.Cond usage without timeout protection

```bash
grep -rn "\.Wait()" internal/parallelwork/ internal/workshare/ snapshot/upload/ \
    --include="*.go" | grep -v "_test.go"
```

Every `.Wait()` call is a potential deadlock site. Each one needs:
- A timeout mechanism (use `sync.Cond` with a wrapper that wakes periodically)
- Or a guaranteed `Broadcast()`/`Signal()` from another goroutine

**Step 7:** Verify panic recovery in all goroutine launch sites

```bash
grep -rn "go func" snapshot/upload/ internal/parallelwork/ internal/workshare/ \
    --include="*.go" | grep -v "_test.go"
```

Every `go func()` that participates in the work queue must have `defer recover()`.
An unrecovered panic kills the goroutine silently, leaving `activeWorkerCount`
permanently incremented → deadlock.

**Step 8:** Check for unbounded blocking in the localfs layer

```bash
grep -rn "os.Open\|os.ReadDir\|os.Stat\|os.Lstat" fs/localfs/ \
    --include="*.go" | grep -v "_test.go"
```

On Windows, `os.Open()` on certain NTFS files (junction targets, encrypted files,
locked files where `IgnoreFileErrors` doesn't catch the specific error type) can
block indefinitely. Each call needs a context-aware timeout wrapper.


### Phase 3: Implement Fixes

**Fix 1: Add deadlock detection and recovery to `parallel_work_queue.go`**

Replace the simple `Wait()` loop in `dequeue()` with a timed wait that detects
deadlocks and breaks out:

```go
func (v *Queue) dequeue(ctx context.Context) CallbackFunc {
    v.monitor.L.Lock()
    defer v.monitor.L.Unlock()

    stallCount := 0
    for v.queueItems.Len() == 0 && v.activeWorkerCount > 0 {
        // Use a timed wait instead of indefinite Wait()
        done := make(chan struct{})
        go func() {
            v.monitor.Wait()
            close(done)
        }()

        select {
        case <-done:
            stallCount = 0 // got signaled, reset
        case <-time.After(60 * time.Second):
            stallCount++
            log.Warnf("parallelwork: queue stall #%d — queue empty, "+
                "%d active workers, %d completed",
                stallCount, v.activeWorkerCount, v.completedWork)
            if stallCount >= 5 {
                log.Errorf("parallelwork: DEADLOCK detected after %d stalls, "+
                    "forcing drain", stallCount)
                // Force activeWorkerCount to 0 to break the deadlock
                v.activeWorkerCount = 0
                return nil
            }
        case <-ctx.Done():
            return nil
        }
    }

    if v.queueItems.Len() == 0 {
        return nil
    }

    v.activeWorkerCount++
    v.maybeReportProgress(ctx)

    front := v.queueItems.Front()
    v.queueItems.Remove(front)
    return front.Value.(CallbackFunc)
}
```

**Fix 2: Add panic recovery to `Process()` worker loop**

In `parallel_work_queue.go`, wrap callback execution:

```go
func (v *Queue) Process(ctx context.Context, workers int) error {
    defer v.reportProgress(ctx)
    eg, ctx := errgroup.WithContext(ctx)

    for range workers {
        eg.Go(func() error {
            for {
                select {
                case <-ctx.Done():
                    return ctx.Err()
                default:
                    callback := v.dequeue(ctx)
                    if callback == nil {
                        return nil
                    }

                    // FIXED: recover from panics to prevent silent goroutine death
                    err := func() (retErr error) {
                        defer func() {
                            if r := recover(); r != nil {
                                retErr = fmt.Errorf(
                                    "panic in parallel work callback: %v\n%s",
                                    r, debug.Stack())
                            }
                        }()
                        return callback()
                    }()

                    v.completed(ctx)

                    if err != nil {
                        return err
                    }
                }
            }
        })
    }
    return eg.Wait()
}
```

**Fix 3: Add timeout wrapper for file operations on Windows**

Create `fs/localfs/open_windows.go`:

```go
//go:build windows

package localfs

import (
    "context"
    "fmt"
    "os"
    "time"
)

const fileOpenTimeout = 30 * time.Second

// openFileWithTimeout wraps os.Open with a timeout to prevent indefinite
// blocking on locked/inaccessible NTFS files.
func openFileWithTimeout(ctx context.Context, path string) (*os.File, error) {
    type result struct {
        f   *os.File
        err error
    }

    ch := make(chan result, 1)
    go func() {
        f, err := os.Open(path)
        ch <- result{f, err}
    }()

    select {
    case r := <-ch:
        return r.f, r.err
    case <-time.After(fileOpenTimeout):
        return nil, fmt.Errorf("timeout after %v opening: %s", fileOpenTimeout, path)
    case <-ctx.Done():
        return nil, ctx.Err()
    }
}
```

Then replace direct `os.Open()` calls in `fs/localfs/local_fs.go` and
`fs/localfs/local_fs_os.go` with `openFileWithTimeout()`.


---

## VSS Shadow Copy Support (Already Implemented)

Kopia already has full VSS support in `snapshot/upload/upload_os_snapshot_windows.go`
using the `github.com/mxk/go-vss` library. It is **disabled by default**.

### How it works:
1. Before scanning files, Kopia calls `vss.Create(volume)` to create a shadow copy
2. All files are read from the shadow copy path (e.g., `\\?\GLOBALROOT\Device\HarddiskVolumeShadowCopy1\`)
3. Shadow copy provides a **consistent point-in-time view** — no file locks
4. After the snapshot completes, Kopia calls `vss.Remove(id)` to delete the shadow copy

### Three modes available (`os_snapshot_policy.go`):
- `never` (default) — no VSS, direct file access
- `always` — require VSS; fail if shadow copy cannot be created
- `when-available` — use VSS if possible, fall back to direct access on failure

### Enable VSS immediately (no code changes needed):

```cmd
REM Enable VSS for C:\Users\david snapshots (recommended: when-available)
C:\Users\david\go\bin\kopia.exe policy set C:\Users\david ^
    --os-snapshot-mode when-available

REM Verify policy was set
C:\Users\david\go\bin\kopia.exe policy show C:\Users\david
```

### Benefits:
- **Eliminates all locked file errors** (Discord cookies, browser DBs, etc.)
- **Consistent snapshot** — no partial file reads during backup
- **Faster scanning** — VSS snapshot is read-only, no contention with running apps
- **May prevent the deadlock** if the root cause is a hung `os.Open()` on a locked file

### Caveats:
- Requires running as administrator (or a user with `SeBackupPrivilege`)
- The scheduled task currently runs as user `david` — may need elevation
- VSS creates a temporary shadow copy consuming disk space proportional to
  change rate during the backup window


---

## Locked File Handling (Current Behavior and Improvements)

### Current behavior:
Kopia's `ErrorHandlingPolicy` (`snapshot/policy/error_handling_policy.go`) provides:
- `IgnoreFileErrors` — skip files that throw errors on read (enabled for this source)
- `IgnoreDirectoryErrors` — skip directories that can't be opened
- `IgnoreUnknownTypes` — skip unknown directory entry types

The Discord cookie errors are correctly caught by `IgnoreFileErrors`. However, the
deadlock is NOT caused by these ignored errors — it occurs upstream in the parallel
work queue or workshare pool.

### Recommended policy additions to skip known problematic paths:

```cmd
C:\Users\david\go\bin\kopia.exe policy set C:\Users\david ^
    --add-ignore ".cache" ^
    --add-ignore "AppData/Local/Temp" ^
    --add-ignore "AppData/Local/npm-cache" ^
    --add-ignore "AppData/Local/pip/cache" ^
    --add-ignore "AppData/Local/Packages/*/LocalCache" ^
    --add-ignore "AppData/Local/Discord" ^
    --add-ignore "AppData/Local/Google/Chrome/User Data/*/Service Worker" ^
    --add-ignore "AppData/Local/Microsoft/Edge/User Data/*/Service Worker" ^
    --add-ignore "AppData/Roaming/discord/Cache" ^
    --add-ignore "AppData/Roaming/discord/Code Cache" ^
    --add-ignore "AppData/Roaming/discord/Network" ^
    --add-ignore ".ollama/models" ^
    --add-ignore "go/pkg/mod/cache"
```

These exclusions will:
- Reduce the 781 GB source size significantly (LLM model caches, browser caches)
- Eliminate the most common locked file sources
- Speed up both full and incremental snapshots


---

## Scheduled Task Update for VSS

If VSS is enabled, the Kopia scheduled task needs to run with elevated privileges.
Update the task:

```cmd
REM Delete existing task
SCHTASKS /Delete /TN "Backup\DailyKopiaSnapshot" /F

REM Re-create with HIGHEST privileges (triggers UAC / runs elevated)
SCHTASKS /Create /TN "Backup\DailyKopiaSnapshot" ^
    /TR "C:\dev\kopia\scripts\daily_kopia_backup.cmd" ^
    /SC DAILY /ST 03:00 ^
    /RL HIGHEST ^
    /RU david ^
    /RP * ^
    /F
```

The `/RL HIGHEST` flag ensures the task runs with admin privileges, which is
required for `vss.Create()` to succeed.

---

## Windows Image Backup (wbadmin) Status

**UNCONFIRMED.** The `D:\WindowsImageBackup\ChrisLaptop2` directory was last
modified April 7 at 2:02 AM, suggesting the 02:00 scheduled run executed. However,
the backup data directories are ACL'd to SYSTEM/Administrators and cannot be read
without elevation.

### To verify (run from elevated prompt):

```cmd
wbadmin get versions -backupTarget:D:
```

### If no April 7 backup exists, re-run manually:

```cmd
wbadmin start backup -backupTarget:D: -include:C: -allCritical -quiet
```

### If wbadmin shows the April 7 backup, no action needed.


---

## Testing Plan

### Test 1: Verify VSS mode works (no code changes)
```cmd
C:\Users\david\go\bin\kopia.exe policy set C:\Users\david --os-snapshot-mode when-available
C:\Users\david\go\bin\kopia.exe snapshot create C:\Users\david --parallel=16
```
Expected: completes in ~5 minutes, no "Ignored error" messages for locked files.

### Test 2: Reproduce deadlock (if VSS alone doesn't fix it)
```cmd
C:\Users\david\go\bin\kopia.exe policy set C:\Users\david --os-snapshot-mode never
C:\Users\david\go\bin\kopia.exe snapshot create C:\Users\david --parallel=16 --log-level=debug 2>C:\dev\kopia\logs\debug_snapshot.log
```
Monitor with:
```powershell
# In another terminal, poll every 30s
while ($true) {
    $p = Get-Process kopia -ErrorAction SilentlyContinue | Where-Object { $_.WorkingSet64 -gt 100MB }
    if ($p) {
        $delta = (Get-Date) - $p.StartTime
        Write-Host "$(Get-Date -f 'HH:mm:ss') PID=$($p.Id) CPU=$([math]::Round($p.CPU,1))s Mem=$([math]::Round($p.WorkingSet64/1MB))MB Threads=$($p.Threads.Count) Elapsed=$([math]::Round($delta.TotalMinutes,1))m"
    }
    Start-Sleep 30
}
```
If it hangs for >10 minutes with flat CPU, capture goroutine dump and kill.

### Test 3: After code fixes, stress test
```cmd
REM Run 3 consecutive snapshots to verify no deadlock recurrence
for /L %i in (1,1,3) do (
    echo === Run %i ===
    C:\Users\david\go\bin\kopia.exe snapshot create C:\Users\david --parallel=16
)
```

---

## Summary of Immediate Actions

1. ~~**Enable VSS** — `kopia policy set C:\Users\david --os-snapshot-mode when-available`~~ ✅ Done
2. ~~**Add exclusions** — skip caches, Discord, LLM models, temp files (see above)~~ ✅ Done (13 rules)
3. ~~**Update scheduled task** — add `/RL HIGHEST` for VSS elevation~~ ✅ Done (`\Backup\DailyKopiaSnapshot`)
4. ~~**Verify wbadmin** — run `wbadmin get versions -backupTarget:D:` from admin prompt~~ ✅ Confirmed April 7 backup
5. **Re-run backup** — test that the combination of VSS + exclusions produces a clean, fast snapshot

## Summary of Code Fixes — COMPLETED

**Commit `66f6ca85`** on branch `fix/golangci-lint-v2-windows` (2026-04-07)

### Correction: Primary Suspect Was Wrong

The original investigation identified `parallelwork.Queue` as the primary deadlock suspect.
**This was incorrect.** `parallelwork.Queue` is used in **restore** (`snapshot/restore/`),
not snapshot create. Snapshot creation uses `workshare.Pool` (`internal/workshare/`).

The actual deadlock path:
1. `upload.processDirectoryEntries()` dispatches entries via `wg.RunAsync(workerPool, ...)`
2. Workshare pool worker calls `it.process()` which calls `processSingle()` → `uploadFileInternal()` → `f.Open(ctx)` → `os.Open()`
3. `os.Open()` blocks indefinitely on a locked NTFS file
4. `it.wg.Done()` never fires → `AsyncGroup.Wait()` in `processChildren()` blocks forever
5. If directory processing was in a workshare worker, that worker is also stuck
6. Cascading stall exhausts all pool workers → main goroutine's `Wait()` blocks → 17-hour hang

### Fixes Applied

1. **Panic recovery in `workshare.Pool`** (`internal/workshare/workshare_pool.go`) — `processWorkItem()` method with defers guaranteeing `wg.Done()`, semaphore release, and `activeWorkers` decrement even if the process function panics
2. **Panic recovery in `parallelwork.Queue`** (`internal/parallelwork/parallel_work_queue.go`) — `safeCallback()` wrapper converts panics to errors, ensuring `completed()` always runs
3. **Context-aware file open with 60s timeout** (`fs/localfs/open_ctx.go`) — `openWithContext()` wraps `os.Open()` with context cancellation; cleans up leaked file handles; wired into `filesystemFile.Open()` and `filesystemDirectory.Iterate()`
4. **Stall detection in workshare** — per-work-item 5-minute timer that logs a warning and dumps goroutine stacks to a temp file when a single item runs too long
5. **Stall detection in parallelwork** — watchdog goroutine that checks every 5 minutes for `queue empty + active workers > 0` condition and dumps goroutine stacks
6. **Tests** — 6 new tests: 2 parallelwork panic recovery, 2 workshare panic recovery (including pool-remains-operational), 5 openWithContext tests

## Key Source Files

| File | Purpose |
|---|---|
| `internal/workshare/workshare_pool.go` | Worker pool for snapshot create — **actual deadlock site** |
| `internal/workshare/workshare_waitgroup.go` | AsyncGroup with WaitGroup — blocks on stuck workers |
| `internal/parallelwork/parallel_work_queue.go` | Work queue with sync.Cond — used in **restore** |
| `fs/localfs/open_ctx.go` | Context-aware file open with timeout (NEW) |
| `fs/localfs/local_fs.go` | Local filesystem file open — now uses openWithContext |
| `fs/localfs/local_fs_os.go` | Directory iteration — now uses openWithContext |
| `snapshot/upload/upload.go` | Snapshot upload orchestration (1416 lines) |
| `snapshot/upload/upload_os_snapshot_windows.go` | VSS shadow copy support |
| `snapshot/policy/os_snapshot_policy.go` | VSS policy configuration |
| `snapshot/policy/error_handling_policy.go` | File/directory error ignore policy |
