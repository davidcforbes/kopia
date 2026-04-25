# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Kopia?

Kopia is a fast, encrypted, open-source backup/restore tool written in Go. It creates deduplicated, compressed, encrypted snapshots and stores them to pluggable storage backends (S3, Azure, GCS, B2, SFTP, WebDAV, local filesystem, etc.). It provides both a CLI and GUI (Electron-based desktop app with embedded React UI).

## Build Commands

```bash
make -j4 ci-setup          # REQUIRED first-time setup: downloads Go modules, installs tools
make install-noui           # Fast build without UI (~5-10s) → ~/go/bin/kopia
make install                # Full build with embedded HTML UI (~10-20s)
make install-race           # Build with race detector
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

## Code Style Rules

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

### Layered Design (bottom to top)

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

### Key Packages

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

### Entry Point

`main.go` → `cli.NewApp()` → kingpin CLI dispatch to `cli/command_*.go` files.

### HTML UI

The React UI source is in a **separate repo** (`github.com/kopia/htmlui`). Pre-built HTML is imported as a Go module (`github.com/kopia/htmluibuild`) and embedded via `go:embed`. Don't look for UI source code in this repo.

## Important Notes

- Do not modify `go.mod`/`go.sum` manually — use `go get`.
- Tools in `.tools/` are gitignored and populated by `make ci-setup`.
- Do not commit executables/binaries or modify `.gitignore` files.
- Go version: requires Go toolchain specified in `go.mod` (currently 1.25.x).
- Policy system is hierarchical: global → host → user@host → path.
- Format versioning (`repo/format/`) supports multiple versions for backward compatibility.
