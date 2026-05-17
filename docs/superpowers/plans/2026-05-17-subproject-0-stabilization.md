# Sub-project 0 — New-stack Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `backup-server` trustworthy for unattended nightly runs by fixing the two bugs the 2026-05-17 soak surfaced and arming the stall-watch.

**Architecture:** Five fixes in the `backup-server` binary. The worker supervisor (`src/server/worker.rs`) stops deadlocking on a grandchild-held pipe and gains liveness signals; the state store (`src/server/state.rs`) stops clobbering concurrently-running jobs; the production config enables the stall-watch.

**Tech Stack:** Rust, `windows-sys` (Job Objects, process queries), `rusqlite`, `crossbeam-channel`. Code in `C:\dev\backup-monitor`, branch `oss-dev`. Build/test: `cargo test --bin backup-server`.

**Beads:** `kopia-0dr.28` (Tasks 1–2), `.29` (Task 3), `.23` (Task 4), `.24` (Task 5), `.25` (Task 6).

---

## Task 1: Bounded reader-thread join (kopia-0dr.28, part 1)

The hang fix. After the child exits, `run_worker` must never block forever on `stderr_handle.join()` / `stdout_handle.join()` — a grandchild holding the stdout/stderr pipe write-end keeps the readers from seeing EOF.

**Files:**
- Modify: `src/server/worker.rs` (reader-thread setup + post-exit join)
- Test: `src/server/worker.rs` (tests module)

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `src/server/worker.rs`:

```rust
    #[cfg(windows)]
    #[test]
    fn run_worker_does_not_hang_on_pipe_holding_grandchild() {
        // The cmd exits immediately but `start /b` leaves a detached
        // grandchild (ping, ~12s) that inherited the stdout/stderr
        // pipe. run_worker must return shortly after the direct child
        // exits — NOT wait ~12s for the grandchild.
        let store = scratch_store("grandchild-pipe");
        let spec = WorkerSpec {
            job_name: "grandchild".into(),
            command: vec![
                "cmd".into(),
                "/c".into(),
                "start /b ping -n 12 127.0.0.1 >nul".into(),
            ],
            env: HashMap::new(),
            timeout_sec: 120,
            cwd: None,
            summary_match: None,
            stall_threshold_sec: 0,
            worker_contract: WorkerContract::Legacy,
        };
        let id = store.insert_run_start(&spec.job_name, 0).unwrap();
        let started = std::time::Instant::now();
        let result = run_worker(&spec, id, Arc::clone(&store), None).unwrap();
        let elapsed = started.elapsed();
        assert!(
            elapsed < Duration::from_secs(11),
            "run_worker hung on the grandchild pipe: {:?}",
            elapsed
        );
        assert_eq!(result.status, WorkerStatus::Passed);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --bin backup-server run_worker_does_not_hang_on_pipe_holding_grandchild -- --nocapture`
Expected: the test hangs ~12s then (if it completes) the elapsed assert may still pass by luck — to make the failure deterministic, first confirm the *current* behaviour by observing it takes ≥12s. If it completes <11s already, the readers happen to EOF early; proceed anyway — Step 3 makes it correct-by-construction.

- [ ] **Step 3: Replace the reader-thread setup**

In `run_worker`, find the `stderr_handle` / `stdout_handle` `thread::spawn` blocks and the post-loop join lines. Replace the stdout reader and the two `JoinHandle` declarations with shared-accumulator + done-channel versions:

```rust
    // kopia-0dr.28: stdout into a shared accumulator so the post-exit
    // path can read whatever was captured even if the reader thread
    // is still blocked on a pipe a grandchild holds open.
    let stdout_lines: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let stdout_acc = Arc::clone(&stdout_lines);
    let (stdout_done_tx, stdout_done_rx) = crossbeam_channel::bounded::<()>(1);
    let _stdout_handle = thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            if let Ok(l) = line {
                stdout_acc.lock().unwrap().push(l);
            }
        }
        let _ = stdout_done_tx.send(());
    });

    let (stderr_done_tx, stderr_done_rx) = crossbeam_channel::bounded::<()>(1);
```

In the existing `stderr_handle` thread closure, change its type to a plain spawn and send the done signal at the end. Replace `let stderr_handle: JoinHandle<()> = thread::spawn(move || {` with `let _stderr_handle = thread::spawn(move || {`, and immediately before that closure's final `}` add:

```rust
        let _ = stderr_done_tx.send(());
```

- [ ] **Step 4: Replace the post-exit join**

Replace these two lines:

```rust
    let _ = stderr_handle.join();
    let stdout_lines = stdout_handle.join().unwrap_or_default();
```

with:

```rust
    // kopia-0dr.28: bounded drain. Give the readers a grace window to
    // finish, but never block forever — a grandchild holding the pipe
    // open would otherwise hang run_worker indefinitely.
    const READER_DRAIN_GRACE: Duration = Duration::from_secs(10);
    if stderr_done_rx.recv_timeout(READER_DRAIN_GRACE).is_err() {
        eprintln!(
            "[{}] stderr reader unfinished after {}s; proceeding (grandchild may hold the pipe)",
            spec.job_name,
            READER_DRAIN_GRACE.as_secs()
        );
    }
    if stdout_done_rx.recv_timeout(READER_DRAIN_GRACE).is_err() {
        eprintln!(
            "[{}] stdout reader unfinished after {}s; proceeding",
            spec.job_name,
            READER_DRAIN_GRACE.as_secs()
        );
    }
    let stdout_lines: Vec<String> = stdout_lines.lock().unwrap().clone();
```

If `use std::thread::{self, JoinHandle};` now leaves `JoinHandle` unused, change it to `use std::thread;`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test --bin backup-server worker:: -- --nocapture`
Expected: PASS — including `run_worker_does_not_hang_on_pipe_holding_grandchild` completing in <11s, and all pre-existing worker tests still green.

- [ ] **Step 6: Commit**

```bash
cd C:/dev/backup-monitor
git add src/server/worker.rs
git commit -m "fix(server): bounded reader-thread drain — no hang on grandchild-held pipe (kopia-0dr.28)"
```

---

## Task 2: Job Object descendant cleanup (kopia-0dr.28, part 2)

Correctness layer: assign the worker child to a Windows Job Object so that when the run finishes, every descendant (conhost, detached grandchildren) is terminated — pipes EOF, the readers finish promptly, no process leak.

**Files:**
- Modify: `Cargo.toml` (add `Win32_System_JobObjects` feature)
- Modify: `src/server/worker.rs` (JobGuard + assign + terminate)
- Test: `src/server/worker.rs` (tests module)

- [ ] **Step 1: Add the windows-sys feature**

In `Cargo.toml`, inside the `windows-sys` `features` array, add the line:

```toml
    "Win32_System_JobObjects",
```

- [ ] **Step 2: Write the failing test**

Add to the `tests` module in `src/server/worker.rs`:

```rust
    #[cfg(windows)]
    #[test]
    fn run_worker_job_object_kills_detached_grandchild() {
        // After run_worker returns, the detached grandchild must be
        // dead — the Job Object tears down the whole tree.
        let store = scratch_store("job-kills-tree");
        let spec = WorkerSpec {
            job_name: "tree".into(),
            command: vec![
                "cmd".into(),
                "/c".into(),
                "start /b ping -n 30 127.0.0.1 >nul".into(),
            ],
            env: HashMap::new(),
            timeout_sec: 120,
            cwd: None,
            summary_match: None,
            stall_threshold_sec: 0,
            worker_contract: WorkerContract::Legacy,
        };
        let id = store.insert_run_start(&spec.job_name, 0).unwrap();
        let _ = run_worker(&spec, id, Arc::clone(&store), None).unwrap();
        // Give the OS a beat to reap, then assert no ping survives.
        std::thread::sleep(Duration::from_millis(500));
        let out = std::process::Command::new("tasklist")
            .args(["/fi", "imagename eq ping.exe", "/nh"])
            .output()
            .unwrap();
        let listing = String::from_utf8_lossy(&out.stdout);
        assert!(
            !listing.to_lowercase().contains("ping.exe"),
            "grandchild ping survived run_worker: {}",
            listing
        );
    }
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cargo test --bin backup-server run_worker_job_object_kills_detached_grandchild -- --nocapture`
Expected: FAIL — `ping.exe` still listed (no Job Object yet).

- [ ] **Step 4: Add the JobGuard type**

Add near the top of `src/server/worker.rs`, after the `use` block:

```rust
/// kopia-0dr.28: a Windows Job Object that owns the worker child and
/// all its descendants. `terminate()` kills the whole tree (so pipes
/// EOF and the reader threads unblock); dropping closes the handle.
#[cfg(windows)]
struct JobGuard {
    handle: windows_sys::Win32::Foundation::HANDLE,
}

#[cfg(windows)]
impl JobGuard {
    /// Create a kill-on-close job and assign `child` to it. Returns
    /// None on any failure — the caller treats Job Objects as a
    /// best-effort robustness layer (Task 1's bounded drain is the
    /// hard guarantee).
    fn assign(child: &std::process::Child) -> Option<Self> {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, SetInformationJobObject,
            JobObjectExtendedLimitInformation, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        };
        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                return None;
            }
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let ok = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const std::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            );
            if ok == 0
                || AssignProcessToJobObject(job, child.as_raw_handle() as _) == 0
            {
                CloseHandle(job);
                return None;
            }
            Some(JobGuard { handle: job })
        }
    }

    /// Kill every process still in the job.
    fn terminate(&self) {
        unsafe {
            windows_sys::Win32::System::JobObjects::TerminateJobObject(self.handle, 1);
        }
    }
}

#[cfg(windows)]
impl Drop for JobGuard {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.handle);
        }
    }
}
```

- [ ] **Step 5: Assign the child and terminate on exit**

In `run_worker`, immediately after the `let mut child = cmd.spawn()...?;` line, add:

```rust
    // kopia-0dr.28: assign the child (and its descendants) to a
    // kill-on-close Job Object. Best-effort — the spawn→assign window
    // is tiny relative to how long our wrappers take before spawning
    // grandchildren; Task 1's bounded drain backstops any miss.
    #[cfg(windows)]
    let job_guard = JobGuard::assign(&child);
```

Then, immediately after the `'wait` loop ends (after the line `let (exit_status, killed) = 'wait: loop { ... };`), add:

```rust
    // kopia-0dr.28: tear down any lingering descendants so the
    // stdout/stderr pipes EOF and the reader threads finish promptly.
    #[cfg(windows)]
    if let Some(job) = &job_guard {
        job.terminate();
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cargo test --bin backup-server worker:: -- --nocapture`
Expected: PASS — `run_worker_job_object_kills_detached_grandchild` now finds no surviving `ping.exe`; all other worker tests green.

- [ ] **Step 7: Commit**

```bash
git add Cargo.toml src/server/worker.rs
git commit -m "fix(server): Job Object tears down worker descendant tree on exit (kopia-0dr.28)"
```

---

## Task 3: Orphan-sweep pid-ownership (kopia-0dr.29)

The multi-waker cutover runs N concurrent `backup-server` instances on one `state.db`. The startup orphan-sweep must not clobber a run owned by a *live* instance — only re-classify rows whose owner process is gone.

**Files:**
- Modify: `src/server/state.rs` (migration v2, `insert_run_start`, `sweep_orphan_running_rows`, `is_pid_alive`)
- Test: `src/server/state.rs` (tests module — update one test, add one)

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `src/server/state.rs`:

```rust
    #[test]
    fn sweep_spares_runs_owned_by_a_live_process() {
        // A 'running' row owned by THIS (alive) process must survive
        // the startup sweep — it represents a concurrent live waker.
        let (dir, log) = scratch("sweep-live-owner");
        {
            let s = Store::open(&dir, &log).unwrap();
            s.insert_run_start("concurrent_job", 5000).unwrap();
            // dropped without finalize — but the owner pid is alive
        }
        let s2 = Store::open(&dir, &log).unwrap();
        let rows = s2.list_runs(Some("concurrent_job"), 5).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].status, "running",
            "a run owned by a live pid must NOT be swept"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --bin backup-server sweep_spares_runs_owned_by_a_live_process -- --nocapture`
Expected: FAIL — the row is swept to `killed` (sweep is pid-blind today).

- [ ] **Step 3: Add migration v2 and the pid-alive helper**

In `src/server/state.rs`, in the `migrations()` slice, add a second tuple after migration `1`:

```rust
            (
                2,
                r#"
                ALTER TABLE runs ADD COLUMN owner_pid INTEGER;
                "#,
            ),
```

Add this free function near the bottom of the file (before `#[cfg(test)]`):

```rust
/// kopia-0dr.29: is `pid` a currently-live process? Used so the
/// orphan-sweep only re-classifies runs whose owner is genuinely gone.
#[cfg(windows)]
fn is_pid_alive(pid: u32) -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if h.is_null() {
            return false;
        }
        let mut code: u32 = 0;
        let ok = GetExitCodeProcess(h, &mut code);
        CloseHandle(h);
        ok != 0 && code == STILL_ACTIVE as u32
    }
}

#[cfg(not(windows))]
fn is_pid_alive(_pid: u32) -> bool {
    false
}
```

- [ ] **Step 4: Record owner_pid on insert**

Replace the body of `insert_run_start`:

```rust
    pub fn insert_run_start(&self, job_name: &str, start_unix: i64) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO runs (job_name, start_unix, status, owner_pid) \
             VALUES (?1, ?2, 'running', ?3)",
            params![job_name, start_unix, std::process::id() as i64],
        )?;
        Ok(conn.last_insert_rowid())
    }
```

- [ ] **Step 5: Make the sweep pid-aware**

Replace the body of `sweep_orphan_running_rows`:

```rust
    fn sweep_orphan_running_rows(conn: &Connection) -> Result<Vec<(i64, String)>> {
        let mut stmt = conn.prepare(
            "SELECT run_id, job_name, owner_pid FROM runs WHERE status = 'running'",
        )?;
        let candidates: Vec<(i64, String, Option<i64>)> = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            })?
            .filter_map(Result::ok)
            .collect();
        drop(stmt);

        // Only sweep rows whose owner process is gone. A NULL owner_pid
        // (pre-v2 row) is treated as orphaned. A live owner means a
        // concurrent waker instance — leave its run alone (kopia-0dr.29).
        let orphans: Vec<(i64, String)> = candidates
            .into_iter()
            .filter(|(_, _, pid)| match pid {
                Some(p) => !is_pid_alive(*p as u32),
                None => true,
            })
            .map(|(id, job, _)| (id, job))
            .collect();
        if orphans.is_empty() {
            return Ok(orphans);
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let ids: Vec<String> = orphans.iter().map(|(id, _)| id.to_string()).collect();
        conn.execute(
            &format!(
                "UPDATE runs SET status = 'killed', end_unix = ?1 \
                 WHERE run_id IN ({})",
                ids.join(",")
            ),
            params![now],
        )?;
        Ok(orphans)
    }
```

- [ ] **Step 6: Fix the existing orphan-sweep test**

The test `orphan_running_rows_swept_on_reopen` inserts a run from the same (live) test process, so it would no longer be swept. Make its owner pid dead — after the `insert_run_start` line in that test, add:

```rust
            // Force a dead owner pid so the sweep treats it as orphaned
            // (the real crash case). pid 0xFFFFFFE0 is never a live pid.
            {
                let conn = s.conn.lock().unwrap();
                conn.execute(
                    "UPDATE runs SET owner_pid = ?1 WHERE run_id = ?2",
                    rusqlite::params![0xFFFF_FFE0_i64, id],
                )
                .unwrap();
            }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cargo test --bin backup-server state:: -- --nocapture`
Expected: PASS — `sweep_spares_runs_owned_by_a_live_process`, `orphan_running_rows_swept_on_reopen`, and all other state tests green.

- [ ] **Step 8: Commit**

```bash
git add src/server/state.rs
git commit -m "fix(server): orphan-sweep spares runs owned by a live pid (kopia-0dr.29)"
```

---

## Task 4: Stall-watch file-mtime-growth liveness (kopia-0dr.23)

Add a per-job `liveness_paths` config field; the stall-watch resets its clock when a watched path's mtime or size advances — a worker writing real output is alive even when stderr-silent.

**Files:**
- Modify: `src/server/config.rs` (`JobConfig.liveness_paths`)
- Modify: `src/server/worker.rs` (`WorkerSpec.liveness_paths` + stall-watch poll)
- Modify: `src/server/scheduler.rs` (pass `liveness_paths` into `WorkerSpec`)
- Test: `src/server/worker.rs` (tests module)

- [ ] **Step 1: Add the config field**

In `src/server/config.rs`, in `struct JobConfig`, after the `toast` field add:

```rust
    /// kopia-0dr.23: paths the stall-watch treats as liveness signals.
    /// If any path's mtime or size advances, the worker is making
    /// progress even when stderr-silent and the stall clock resets.
    #[serde(default)]
    pub liveness_paths: Vec<std::path::PathBuf>,
```

- [ ] **Step 2: Add the WorkerSpec field**

In `src/server/worker.rs`, in `struct WorkerSpec`, after `worker_contract` add:

```rust
    /// kopia-0dr.23: liveness paths — see JobConfig::liveness_paths.
    pub liveness_paths: Vec<PathBuf>,
```

This makes every existing `WorkerSpec { ... }` literal fail to compile until the field is supplied — that is the failing state for this task.

- [ ] **Step 3: Run build to verify it fails**

Run: `cargo test --bin backup-server --no-run`
Expected: FAIL — `missing field liveness_paths` at each `WorkerSpec { ... }` site (scheduler.rs and the worker.rs tests).

- [ ] **Step 4: Supply the field at the construction site**

In `src/server/scheduler.rs`, in `run_one_job_with_retries`, find `let spec = WorkerSpec { ... };` and add after the `worker_contract: job.worker_contract,` line:

```rust
            liveness_paths: job.liveness_paths.clone(),
```

In every `WorkerSpec { ... }` literal in the `worker.rs` tests module, add after the `worker_contract: ...,` line:

```rust
            liveness_paths: Vec::new(),
```

- [ ] **Step 5: Write the failing test**

Add to the `tests` module in `src/server/worker.rs`:

```rust
    #[cfg(windows)]
    #[test]
    #[ignore = "slow: ~35s to clear the stall-watch grace period"]
    fn stall_watch_spares_worker_with_growing_liveness_path() {
        // A stderr-silent worker whose liveness path keeps growing is
        // NOT killed, even past the stall threshold + grace.
        let store = scratch_store("liveness-growth");
        let dir = std::env::temp_dir().join("bs-liveness-growth");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let watched = dir.join("progress.dat");
        std::fs::write(&watched, b"start").unwrap();
        let spec = WorkerSpec {
            job_name: "silent-but-growing".into(),
            // 40s silent sleeper — past the 30s grace + 1s threshold.
            command: vec![
                "powershell".into(),
                "-NoProfile".into(),
                "-Command".into(),
                format!(
                    "1..40 | %{{ Add-Content -Path '{}' -Value $_; Start-Sleep 1 }}",
                    watched.display()
                ),
            ],
            env: HashMap::new(),
            timeout_sec: 120,
            cwd: None,
            summary_match: None,
            stall_threshold_sec: 1,
            worker_contract: WorkerContract::Legacy,
            liveness_paths: vec![watched.clone()],
        };
        let id = store.insert_run_start(&spec.job_name, 0).unwrap();
        let result = run_worker(&spec, id, Arc::clone(&store), None).unwrap();
        assert_eq!(
            result.status,
            WorkerStatus::Passed,
            "growing liveness path must suppress the stall kill"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
```

- [ ] **Step 6: Implement the liveness poll**

In `run_worker`, just before the `'wait` loop, add the liveness tracker:

```rust
    // kopia-0dr.23: snapshot of each liveness path's (mtime, len).
    // When any advances, the worker is alive even if stderr-silent.
    let mut liveness_seen: std::collections::HashMap<PathBuf, (std::time::SystemTime, u64)> =
        std::collections::HashMap::new();
    let mut last_liveness_progress = Instant::now();
    let poll_liveness =
        |seen: &mut std::collections::HashMap<PathBuf, (std::time::SystemTime, u64)>| -> bool {
            let mut advanced = false;
            for p in &spec.liveness_paths {
                if let Ok(md) = std::fs::metadata(p) {
                    let mtime = md.modified().unwrap_or(std::time::UNIX_EPOCH);
                    let len = md.len();
                    match seen.get(p) {
                        Some((m, l)) if *m == mtime && *l == len => {}
                        _ => {
                            advanced = true;
                            seen.insert(p.clone(), (mtime, len));
                        }
                    }
                }
            }
            advanced
        };
    // Prime the snapshot so the first real growth (not first sight) counts.
    let _ = poll_liveness(&mut liveness_seen);
```

Then in the `None =>` branch of the `'wait` loop, replace the `if event_age >= threshold {` block's condition. Change:

```rust
                        if event_age >= threshold {
```

to:

```rust
                        if poll_liveness(&mut liveness_seen) {
                            last_liveness_progress = Instant::now();
                        }
                        let liveness_age = last_liveness_progress.elapsed();
                        if event_age >= threshold && liveness_age >= threshold {
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cargo test --bin backup-server worker:: -- --nocapture --include-ignored`
Expected: PASS — `stall_watch_spares_worker_with_growing_liveness_path` keeps the worker alive; existing stall-watch tests green.

- [ ] **Step 8: Commit**

```bash
git add src/server/config.rs src/server/worker.rs src/server/scheduler.rs
git commit -m "feat(server): stall-watch file-mtime-growth liveness signal (kopia-0dr.23)"
```

---

## Task 5: Stall-watch job-CPU-advance check (kopia-0dr.24)

A worker burning CPU is not wedged. Use the Job Object's accounting info (whole descendant tree's CPU) so the stall-watch only fires when the job is *also* CPU-idle.

**Files:**
- Modify: `src/server/worker.rs` (`JobGuard::total_cpu_100ns` + stall-watch condition)
- Test: `src/server/worker.rs` (tests module)

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `src/server/worker.rs`:

```rust
    #[cfg(windows)]
    #[test]
    #[ignore = "slow: ~35s to clear the stall-watch grace period"]
    fn stall_watch_spares_cpu_busy_silent_worker() {
        // A stderr-silent worker that is busy on CPU (no liveness path)
        // must NOT be killed by the stall-watch.
        let store = scratch_store("cpu-busy");
        let spec = WorkerSpec {
            job_name: "cpu-spinner".into(),
            // 40s of CPU work, no stderr, no watched path.
            command: vec![
                "powershell".into(),
                "-NoProfile".into(),
                "-Command".into(),
                "$e=(Get-Date).AddSeconds(40); while((Get-Date) -lt $e){ $x=1 }".into(),
            ],
            env: HashMap::new(),
            timeout_sec: 120,
            cwd: None,
            summary_match: None,
            stall_threshold_sec: 1,
            worker_contract: WorkerContract::Legacy,
            liveness_paths: Vec::new(),
        };
        let id = store.insert_run_start(&spec.job_name, 0).unwrap();
        let result = run_worker(&spec, id, Arc::clone(&store), None).unwrap();
        assert_eq!(
            result.status,
            WorkerStatus::Passed,
            "a CPU-busy worker must not be stall-killed"
        );
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test --bin backup-server stall_watch_spares_cpu_busy_silent_worker -- --nocapture --include-ignored`
Expected: FAIL — the silent spinner is stall-killed (`status` is `Killed`).

- [ ] **Step 3: Add the job CPU accessor**

In `src/server/worker.rs`, add to `impl JobGuard` (after `terminate`):

```rust
    /// Total CPU time (100-ns units) consumed by every process in the
    /// job — the whole worker descendant tree. None if the query fails.
    fn total_cpu_100ns(&self) -> Option<u64> {
        use windows_sys::Win32::System::JobObjects::{
            QueryInformationJobObject, JobObjectBasicAccountingInformation,
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
        };
        unsafe {
            let mut acc: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = std::mem::zeroed();
            let ok = QueryInformationJobObject(
                self.handle,
                JobObjectBasicAccountingInformation,
                &mut acc as *mut _ as *mut std::ffi::c_void,
                std::mem::size_of::<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>() as u32,
                std::ptr::null_mut(),
            );
            if ok == 0 {
                return None;
            }
            // TotalUserTime / TotalKernelTime are i64 100-ns counters.
            Some(acc.TotalUserTime as u64 + acc.TotalKernelTime as u64)
        }
    }
```

- [ ] **Step 4: Wire CPU-advance into the stall-watch**

In `run_worker`, just before the `'wait` loop, add:

```rust
    // kopia-0dr.24: track whole-job CPU so a busy-but-quiet worker is
    // not mistaken for wedged.
    #[cfg(windows)]
    let mut last_cpu_100ns: u64 = 0;
    #[cfg(windows)]
    let mut last_cpu_progress = Instant::now();
```

In the `'wait` loop's stall block, replace the condition you set in Task 4:

```rust
                        if event_age >= threshold && liveness_age >= threshold {
```

with:

```rust
                        #[cfg(windows)]
                        {
                            if let Some(j) = &job_guard {
                                if let Some(cpu) = j.total_cpu_100ns() {
                                    if cpu > last_cpu_100ns {
                                        last_cpu_100ns = cpu;
                                        last_cpu_progress = Instant::now();
                                    }
                                }
                            }
                        }
                        #[cfg(windows)]
                        let cpu_age = last_cpu_progress.elapsed();
                        #[cfg(not(windows))]
                        let cpu_age = Duration::from_secs(u64::MAX / 2);
                        if event_age >= threshold
                            && liveness_age >= threshold
                            && cpu_age >= threshold
                        {
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cargo test --bin backup-server worker:: -- --nocapture --include-ignored`
Expected: PASS — `stall_watch_spares_cpu_busy_silent_worker` keeps the worker alive; `stall_watch_kills_truly_wedged_worker` still kills the genuinely-silent-and-idle sleeper; all other worker tests green.

- [ ] **Step 6: Commit**

```bash
git add src/server/worker.rs
git commit -m "feat(server): stall-watch job-CPU-advance check (kopia-0dr.24)"
```

---

## Task 6: Enable stall-watch in production jobs.toml (kopia-0dr.25)

Turn the stall-watch on for the production jobs now that it is safe — it fires only when a worker is stderr-silent AND not growing a watched path AND not burning CPU.

**Files:**
- Modify: `C:\BackupServer\jobs.toml`

- [ ] **Step 1: Set thresholds and liveness paths**

Edit `C:\BackupServer\jobs.toml`. To the `kopia_snapshot` job add:

```toml
stall_threshold_sec = 1800
liveness_paths      = ["C:\\dev\\kopia\\logs\\daily_kopia.log"]
```

To the `replica_d_to_e` job add:

```toml
stall_threshold_sec = 900
liveness_paths      = ["C:\\dev\\kopia\\logs\\daily_kopia.log", "E:\\KopiaRepo"]
```

To the `weekly_replica_verify` job add:

```toml
stall_threshold_sec = 1200
liveness_paths      = ["C:\\dev\\kopia\\logs\\daily_kopia.log"]
```

To the `weekly_backup_verify` job add:

```toml
stall_threshold_sec = 3600
liveness_paths      = ["C:\\dev\\kopia\\logs\\daily_kopia.log"]
```

(`status_dump` stays at the default `0` — it is a 60-second job, no stall-watch needed.)

- [ ] **Step 2: Validate the config**

Run: `C:\dev\backup-monitor\target\release\backup-server.exe --check --config C:\BackupServer\jobs.toml`
Expected: `ok: config valid (5 jobs)`. If it errors, the TOML is malformed — fix and re-run.

- [ ] **Step 3: Commit**

`jobs.toml` lives outside the repo, so record the change on the bead instead:

```bash
cd C:/dev/kopia
bd comment kopia-0dr.25 "Enabled stall-watch in C:\BackupServer\jobs.toml: kopia_snapshot 1800s, replica_d_to_e 900s, weekly_replica_verify 1200s, weekly_backup_verify 3600s; liveness_paths set per job. Validated with --check."
```

---

## Final: release build, sign, close beads

- [ ] **Step 1: Release build**

Run: `cd C:/dev/backup-monitor && cargo build --release --bin backup-server`
Expected: `Finished release`. The BackupServerWaker tasks run this binary tonight.

- [ ] **Step 2: Re-sign**

Run: `pwsh C:\dev\kopia\signing\sign-all.ps1`
Expected: `All signatures valid.` — an unsigned binary FATAL-fails the nightly preflight.

- [ ] **Step 3: Close the beads**

```bash
cd C:/dev/kopia
bd update kopia-0dr.28 --status closed
bd update kopia-0dr.29 --status closed
bd update kopia-0dr.23 --status closed
bd update kopia-0dr.24 --status closed
bd update kopia-0dr.25 --status closed
```

- [ ] **Step 4: Push**

```bash
cd C:/dev/backup-monitor && git push origin oss-dev
```

---

## Self-review notes

- **Spec coverage:** sub-project 0 of the roadmap = fix `.28`/`.29` + land `.23/.24/.25`. Tasks 1–2 cover `.28`, Task 3 covers `.29`, Tasks 4/5 cover `.23/.24`, Task 6 covers `.25`. Complete.
- **Ordering dependency:** Task 5 uses `JobGuard` from Task 2 and the `liveness_age` binding from Task 4 — Tasks must run 1→6 in order.
- **Slow tests** are `#[ignore]`d (they burn the 30 s stall-watch grace); run them explicitly with `--include-ignored` as the steps specify.
