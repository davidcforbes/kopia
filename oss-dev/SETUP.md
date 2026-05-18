# Backup Server — fresh-host setup

Bootstrap guide for bringing up the Backup Server control plane
(`rustback-server.exe`, epic `kopia-0dr`) on a new Windows host. This is
the `oss-dev` branch's setup doc; see [`../ARCHITECTURE.md`](../ARCHITECTURE.md)
for the full component inventory and
[`../architecture-vision.md`](../architecture-vision.md) §3.1 for the
milestone log of what has shipped.

> Scope: this covers the *server* and its scheduled-task wakers. The
> kopia repository, wbadmin image backup, and the PowerShell wrapper
> scripts have their own setup steps in `../scripts/README.md`.

---

## 1. `jobs.toml` — the config

The server reads one TOML file (default `C:RustBack\jobs.toml`,
override with `--config`). It declares the server's listen address,
state locations, and the job DAG.

Minimal template:

```toml
[server]
http_listen    = "127.0.0.1:51516"          # loopback only — see §6
state_dir      = "C:\\BackupServer\\state"
event_log      = "C:\\BackupServer\\state\\events.jsonl"
heartbeat_file = "C:\\BackupServer\\state\\heartbeat.txt"

[[job]]
name       = "kopia_snapshot"
cron       = "0 0 3 * * *"                   # 6-field: sec min hour dom mon dow
command    = ["powershell", "-NoProfile", "-File", "C:\\dev\\kopia\\scripts\\daily_kopia_backup.cmd"]
timeout_sec = 36000
retry_max   = 1
# Optional: native toast policy (default "never" during the Phase 1.3
# soak — the legacy scripts still toast). Flip to "on_failure" once a
# native Rust worker replaces the script.
toast       = "never"
# Optional: DPAPI-encrypted secret, resolved at spawn time (see §3).
# env = { KOPIA_PASSWORD = "@dpapi:C:\\dev\\kopia\\scripts\\.kopia-pw.dat" }
```

Validate without starting the listener:

```
rustback-server.exe --config C:RustBack\jobs.toml --check
```

`--check` parses the file, runs DAG validation (no cycles, no
duplicate names, no unknown `depends_on`), and exits.

---

## 2. RustBackWaker scheduled tasks

The server is not a long-running service in Phase 1.3 — it is woken
per job. One scheduled task per job invokes
`rustback-server --run-once --job <name>`. The XMLs live in
[`../scripts/scheduled-tasks/`](../scripts/scheduled-tasks/)
(`RustBackWaker-*.xml`).

Register them (elevated PowerShell):

```powershell
$base = "C:\dev\kopia\scripts\scheduled-tasks"
foreach ($x in "Replica","Kopia","WeeklyReplicaVerify","WeeklyBackupVerify") {
    Register-ScheduledTask -Xml (Get-Content "$base\RustBackWaker-$x.xml" -Raw) `
        -TaskName "RustBackWaker-$x" -TaskPath "\Backup\" -Force
}
```

**`Priority=5` is mandatory in every task XML.** Windows Task
Scheduler defaults an omitted `<Priority>` to `BelowNormal`, which
propagates to every child process and silently costs ~3× backup
throughput. The shipped XMLs already set `Priority=5`; if you hand-
author a task, do not omit it. See
`../scripts/reference_taskscheduler_priority_default.md`.

When cutting over from a legacy task, **disable** the old task in the
same window you register the waker (both fire at the same wall-clock
time — leaving both enabled double-runs the job):

```powershell
Disable-ScheduledTask -TaskPath "\Backup\" -TaskName DailyKopiaSnapshotV2
```

---

## 3. DPAPI password vault

Job secrets (the kopia repository password) are never stored in
`jobs.toml` in plaintext. An `env` value of the form
`@dpapi:<path>` is decrypted in-process at worker-spawn time via
`CryptUnprotectData`; the plaintext flows only into the child's env
block — never to disk, logs, or `events.jsonl`.

Recreating the encrypted vault file on a fresh host is documented in
[`../SECRETS.md`](../SECRETS.md) and `../scripts/README.md` — follow
that procedure, then point a job's `env` at the resulting `.dat`
file. The vault is DPAPI **LocalMachine**-scoped, so only this
machine can decrypt it.

---

## 4. Signing pipeline pre-flight

`rustback-server.exe`, `rustback-tray.exe`, and the other Rust
binaries must be Authenticode-signed before the nightly preflight
will run them — an unsigned binary FATAL-fails the preflight check.
After any `cargo build --release`, re-sign:

```
pwsh C:\dev\kopia\signing\sign-all.ps1
```

`sign-all.ps1` signs every produced `.exe`/`.ps1` and refreshes the
`D:\Recovery` cache. If signing reports a file is locked, the most
common cause is a running instance — stop `rustback-server.exe` /
`rustback-tray.exe` and the dashboard, then retry (see
`kopia-tpl`).

---

## 5. State store — SQLite WAL + crash recovery

`state_dir/state.db` is opened in **WAL mode** with
`synchronous=NORMAL`. A crash mid-write cannot corrupt the file; the
worst case is losing the last in-flight transaction. On every
startup the server runs an **orphan-run sweep**: any row still marked
`running` (a previous instance died before finalizing it) is
re-classified `killed` with a synthetic `end_unix`, and an `Error`
event is appended to `events.jsonl` so the post-mortem has a
canonical reason. No manual recovery step is required after a crash —
just restart the server. (kopia-0dr.6)

---

## 6. HTTP listener — loopback only

`http_listen` must bind a loopback address (`127.0.0.1` or `[::1]`).
The server **rejects `0.0.0.0`, `[::]`, and any routable address at
startup** with a precise error message. There is no authentication
layer in Phase 1; loopback-only is the security boundary. Do not
attempt to expose the API to the network. (kopia-0dr.5)

The API is plain HTTP, JSON request/response. Routes:
`GET /api/status`, `/api/health`, `/api/jobs`, `/api/runs`,
`/api/metrics`; `POST /api/jobs/{name}/run`, `/api/jobs/{name}/cancel`,
`/api/admin/reload`.

---

## 7. Logs and event stream

| Path | What | Retention |
|---|---|---|
| `state_dir/state.db` | SQLite run history (queryable) | unbounded |
| `state_dir/events.jsonl` | append-only progress event stream | rotated daily |
| `state_dir/events-YYYY-MM-DD.jsonl` | rotated day files | gzipped after 7 days |
| `state_dir/events-YYYY-MM-DD.jsonl.gz` | compressed archives | pruned after 365 days |
| `heartbeat_file` | touched every ~30 s to prove liveness | overwritten |

Rotation runs inline on the first append of each new day; it never
fails a job (errors are logged to stderr). `events.jsonl` is the
durable post-mortem source of truth — it survives SQLite schema
migrations. (kopia-0dr.7)

To watch the server live:

```
rustback-tray.exe                 # tray icon, polls /api/status
rustback-dump.exe --server-url            # STATUS CARDS from the REST API
rustback-monitor.exe --server-url         # full dashboard, server-sourced
```
