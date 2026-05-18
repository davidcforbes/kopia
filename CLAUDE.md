# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working with code in
this repository — this is a personal fork of kopia plus a Windows
backup-automation stack that surrounds it.

> Two hard rules first, then the standard repo guide. Both rules
> prevent real failures from the 2026-04-29 session and bind to
> existing `superpowers:*` skills.

## Two hard rules

### Rule 1 — Verification before "errors / clean / passed / failed" claims

Before answering any question about backup state, **run
`rustback-dump.exe` first**:

```bash
/c/dev/rustback/target/release/rustback-dump.exe
```

It already scores every nightly run with a STATUS CARDS verdict and a
30-row history. Reconcile its verdict against any log sample you take.
**If they disagree, report both and the disagreement.** Do not pick a
winner.

Why this rule exists: 2026-04-29 session sampled one
`cli-logs\*-snapshot-create.0.log`, found no `errors":[1-9]` matches,
and answered "Backup logs are clean." The 4/28 nightly had actually
returned `OVERALL_RC=1` because of one Intel telemetry file
(`AppData/Local/Intel/SUR/QUEENCREEK/intermediate_data/u-000005.db`)
being locked. `rustback-dump.exe` already knew this.

Binds to `superpowers:verification-before-completion`.

### Rule 2 — Prior-art audit before designing tooling in this orbit

Before designing any new tool or script that touches backups, toasts,
log parsing, run scoring, health checks, or anything that smells
adjacent: read [`ARCHITECTURE.md`](ARCHITECTURE.md), then **explicitly
cite which existing component covers each requirement**. Only propose
new code for the explicit gaps that remain.

Why this rule exists: 2026-04-29 session shipped ~170 lines of
`post_summary_toast.ps1` plus `check_wbadmin_health.ps1` plus a
"simplified" `check_backup_health.ps1`, while `rustback-monitor.exe`
(three Rust binaries, a feature-rich dashboard, a `rustback:` URL
protocol) was sitting at `C:\dev\rustback\` already doing nearly
all of it. The pointer was inside `register_backup_monitor_toast.ps1`
and was read but not followed.

Binds to `superpowers:brainstorming`.

### Secrets and gitignore layout

`scripts/` is now tracked normally on master (the
`personal/automation` branch was retired 2026-04-29 and merged
in). The actual secret — `scripts/.kopia-pw.dat`, the DPAPI
LocalMachine-encrypted kopia repo password — is protected by three
orthogonal layers:

1. `scripts/.gitignore` ignores `.kopia-pw.dat` and `BACKUP_*.flag`
   (the inner gate, committed and shared with anyone who clones
   this fork).
2. `.git/info/exclude` carries a defensive secret-pattern safety net
   (`*.pw`, `*.pw.dat`, `*.pem`, `*.key`, `*.token`,
   `*-credentials.{json,yaml}`, `secrets.{json,yaml}`, `.env`,
   `.env.*`). Per-host, never committed; catches mistakes the inner
   gitignore might miss.
3. DPAPI LocalMachine encryption + restrictive ACLs on the file
   itself. Even a leak elsewhere would be useless: only this
   machine can decrypt.

The recreate procedure for a fresh machine lives in
[`SECRETS.md`](SECRETS.md) and `scripts/README.md`.

---

## What is Kopia?

Kopia is a fast, encrypted, open-source backup/restore tool written in
Go. It creates deduplicated, compressed, encrypted snapshots and
stores them to pluggable storage backends (S3, Azure, GCS, B2, SFTP,
WebDAV, local filesystem, etc.). It provides both a CLI and GUI
(Electron-based desktop app with embedded React UI).

This fork lives at `github.com/davidcforbes/kopia`. See
[`ARCHITECTURE.md`](ARCHITECTURE.md) for how it integrates with the
surrounding Windows backup stack (`rustback-monitor.exe`, scheduled
tasks, the `rustback:` URL protocol).

## Build commands

```bash
make -j4 ci-setup          # REQUIRED first-time setup: downloads Go modules, installs tools
make install-noui          # Fast build without UI (~5-10s) → ~/go/bin/kopia
make install               # Full build with embedded HTML UI (~10-20s)
make install-race          # Build with race detector
```

## Testing

```bash
make test                   # Unit tests (~2-4 min, uses gotestsum)
make vtest                  # Verbose unit tests
make test-with-coverage     # Unit tests with coverage → coverage.txt

# Run a single test:
go test -v -run TestName ./path/to/package/...

# Race detection:
make test UNIT_TEST_RACE_FLAGS=-race UNIT_TESTS_TIMEOUT=1200s
```

## Linting

```bash
make lint                   # golangci-lint (~3-4 min, config in .golangci.yml)
make lint-fix               # Auto-fix linting issues
make check-locks            # Verify mutex/lock usage
```

## Code style rules

**Forbidden patterns** (enforced by golangci-lint `forbidigo`):

- `time.Now()` → use `clock.Now()` (from `clock` package)
- `time.Since()` → use `timetrack.Timer.Elapsed()`
- `time.Until()` → never use
- `filepath.IsAbs()` → use `ospath.IsAbs()` (Windows UNC path support)
- `Envar("...")` literals → wrap with `EnvName()`

**Blocked modules:**

- `github.com/aws/aws-sdk-go` (v1 or v2) → use `github.com/minio/minio-go`
- `go.uber.org/multierr` → use `errors.Join()`

**Other style:**

- Formatters: `gofumpt` and `gci` (import order: standard, default, localmodule)
- Tests use `stretchr/testify`
- Max function length: 100 lines / 60 statements
- Max cyclomatic complexity: 15 (gocyclo), 40 (gocognit)
- CLI uses `alecthomas/kingpin/v2` for command parsing

## Architecture

### Layered design (bottom to top)

```
CLI (cli/)
  ↓
Snapshot (snapshot/) — what to backup, policies, scheduling
  ↓
Filesystem (fs/) — abstraction over local/virtual/cached filesystems
  ↓
Object (repo/object/) — content-addressable objects, chunking via splitters
  ↓
Content (repo/content/) — deduplication, indexing
  ↓
Manifest (repo/manifest/) — JSON metadata (snapshots, policies)
  ↓
Blob Storage (repo/blob/) — pluggable storage backends
  ↓
S3 / Azure / GCS / Local / SFTP / WebDAV / B2 / rclone
```

### Key packages

- **`repo/`** — Core repository: `Repository`, `RepositoryWriter`, `DirectRepository` interfaces. Coordinates blob, content, object, and manifest subsystems.
- **`repo/blob/`** — `blob.Storage` interface (`PutBlob`, `GetBlob`, `DeleteBlob`, `ListBlobs`) with 11+ backend implementations plus decorators (logging, throttling, readonly).
- **`repo/content/`** — Content-addressable storage with deduplication and index management.
- **`repo/object/`** — Object manager that chunks files using splitters, then compresses and encrypts.
- **`repo/manifest/`** — JSON metadata storage with label-based querying.
- **`repo/compression/`**, **`repo/encryption/`**, **`repo/hashing/`**, **`repo/splitter/`** — Pluggable algorithms (compressor, encryptor, hash function, content splitter interfaces).
- **`repo/ecc/`** — Error correction codes (Reed-Solomon).
- **`snapshot/`** — Snapshot creation, restore, GC. `snapshot/policy/` has hierarchical policies (retention, scheduling, compression, file inclusion, error handling, actions).
- **`fs/`** — `fs.Entry` interface with implementations: `localfs/`, `virtualfs/`, `ignorefs/`, `cachefs/`.
- **`cli/`** — ~200 command files, one per subcommand (`command_snapshot_create.go`, etc.).
- **`internal/`** — ~74 internal utility packages (crypto, cache, metrics, grpcapi, etc.).

### Entry point

`main.go` → `cli.NewApp()` → kingpin CLI dispatch to `cli/command_*.go` files.

### HTML UI

The React UI source is in a **separate repo** (`github.com/kopia/htmlui`).
Pre-built HTML is imported as a Go module
(`github.com/kopia/htmluibuild`) and embedded via `go:embed`. Don't
look for UI source code in this repo.

## Important notes

- Do not modify `go.mod`/`go.sum` manually — use `go get`.
- Tools in `.tools/` are gitignored and populated by `make ci-setup`.
- Do not commit executables/binaries or modify `.gitignore` files.
- Go version: requires Go toolchain specified in `go.mod` (currently 1.25.x).
- Policy system is hierarchical: global → host → user@host → path.
- Format versioning (`repo/format/`) supports multiple versions for backward compatibility.

## Rule 3 — Performance work on backup-mirror: consult the optimization landscape

Before designing any speedup to `backup-mirror` (parallelism, change
detection, I/O patterns), read the **Performance optimization landscape**
section in [`ARCHITECTURE.md`](ARCHITECTURE.md). It is the authoritative
inventory of NTFS change-detection primitives and parallelism opportunities
researched 2026-05-15, and it includes the "what *not* to do" list.

Quick-reference rules that often trip up first-time optimization passes:

- **Check task priority first.** Windows Task Scheduler defaults to
  BelowNormal when `<Priority>` is omitted from XML. Propagates to all
  child processes. Causes ~3x slowdown silently. See
  `reference_taskscheduler_priority_default.md`. If a backup feels much
  slower than expected, this is the first thing to check.
- **We are I/O-bound, not CPU-bound.** SHA-256 hashing already has ~2.5×
  headroom over D:\ throughput. Multi-threaded hashing buys nothing.
  Don't reach for `rayon::par_iter` over chunks.
- **VHDX RCT is the wrong API for our case** (wbadmin output isn't
  Hyper-V-owned). Use `FSCTL_USN_TRACK_MODIFIED_RANGES` + `USN_RECORD_V4`
  instead — it works on plain NTFS. (Closed bead kopia-44w; live bead
  kopia-61n.)
- **Parallelism in cbt mode is harmful.** Multiple concurrent readers on
  the same physical E:\ head thrash (-30 to -50% throughput). Keep N=1
  for cbt mode. File-level parallelism is great for blob mode only.
- **The big win for torn-recovery** (the 5-hour failure mode we hit
  on 2026-05-15) is pipelining the rehash phase (E:\ reads) and the main
  loop (D:\ reads) on two threads — disjoint physical disks. See
  kopia-c90.
- **Don't introduce tokio.** No network I/O, no async I/O benefit on
  Windows without IOCP, pure tax. The existing `std::thread` +
  `crossbeam::channel` pattern is the right Rust stack here.

## Workflow conventions

- Use `bd` for ALL task tracking — not `TodoWrite`/`TaskCreate`. See
  [`AGENTS.md`](AGENTS.md) and run `bd prime` for full workflow context.
- Use `cp -f`, `mv -f`, `rm -f` to avoid interactive-prompt hangs in
  shells where these aliases are interactive by default.
- In `.cmd` wrappers, do NOT capture command output with
  `for /f %%X in ('"<path>" args "<other-path>"')` when the inline
  command contains two or more quoted strings — cmd's parser strips
  outer quotes wrong, the inner cmd never executes, and the variable
  silently stays empty. Use a temp file instead:
  `<cmd> > "%TEMP%\foo.txt"` then `set /p VAR=<"%TEMP%\foo.txt"`.
  This was the actual root cause of kopia-i1p (mistakenly attributed
  to S4U/DCOM for weeks) and kopia-dgd. Fixed in `daily_kopia_backup.cmd`
  on commit `045cd438`. Search `bd memories for/f` for full detail.
- Work is not complete until tests pass, code is committed, and
  `git push` succeeds (where applicable for the branch).
