#!/usr/bin/env bash
# push_and_pr_kopia.sh — push the in-flight fix branches to the fork and
# open upstream PRs against kopia/kopia. Interactive: each step asks
# y/n before acting so you can stop at any time.
#
# Run from c:/dev/kopia in git-bash. Requires gh CLI and an authenticated
# `gh auth status` (run `gh auth login --hostname github.com` first if
# needed). GITHUB_TOKEN must be unset — it lacks push scope on this box.

set -uo pipefail

# ---- preflight ---------------------------------------------------------

cd "$(dirname "$0")/.." || exit 1

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "ERROR: GITHUB_TOKEN is set. Run 'unset GITHUB_TOKEN' first." >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found in PATH." >&2
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh not authenticated. Run 'gh auth login --hostname github.com'." >&2
    exit 1
fi

if ! git remote get-url fork >/dev/null 2>&1; then
    echo "ERROR: 'fork' remote not configured (expected davidcforbes/kopia)." >&2
    exit 1
fi

UPSTREAM_REPO="kopia/kopia"
FORK_USER="davidcforbes"

confirm() {
    local prompt="$1"
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

push_branch() {
    local branch="$1"
    if confirm "Push $branch to fork?"; then
        git push fork "$branch"
    else
        echo "  skipped."
    fi
}

create_pr() {
    local branch="$1" title="$2" body="$3"
    if confirm "Create PR for $branch?"; then
        gh pr create \
            --repo "$UPSTREAM_REPO" \
            --base master \
            --head "${FORK_USER}:${branch}" \
            --title "$title" \
            --body "$body"
    else
        echo "  skipped."
    fi
}

# ---- PR 1: workshare deadlock + preflight ------------------------------

echo
echo "========== PR 1: workshare-deadlock-prevention =========="
push_branch fix/workshare-deadlock-prevention
create_pr fix/workshare-deadlock-prevention \
"fix(snapshot): prevent workshare/parallelwork deadlock + preflight locked files" \
"$(cat <<'EOF'
## Summary

Two-commit fix for snapshot-create hangs caused by workshare-pool worker stalls on locked Windows files.

- Add panic recovery in workshare pool workers and parallelwork queue callbacks; add \`openWithContext\` with 60s timeout. An unrecovered worker panic was leaving \`activeWorkers\`, semaphore, and \`WaitGroup\` counters out of sync, so \`AsyncGroup.Wait()\` blocked forever.
- Add optional \`fs.Preflightable\` interface; \`localfs.filesystemFile\` implements as \`os.Open\` + \`Close\`. \`Uploader.processSingle\` calls \`Preflight\` before workshare assignment so locked files surface as ignored errors immediately instead of stalling the pipeline.

## Why

Reproduced as a 17h+ hang on a 781 GB / 2.7M-file Windows source where \`os.Open\` blocked on an NTFS-locked file. Manual kill + re-run completed in 5m15s, confirming repo integrity.

## Test plan

- [ ] \`make test\` — existing tests + new \`open_ctx_test.go\`, additions to \`parallel_work_queue_test.go\` and \`workshare_test.go\`
- [ ] \`make lint\` — passes locally
- [ ] Manual: \`kopia snapshot create C:\\Users\\...\` on Windows source with in-use Office temp files; locked-file errors should surface as Ignored errors, no hang
EOF
)"

# ---- PR 2: maintenance cleanups ----------------------------------------

echo
echo "========== PR 2: maintenance-cleanup =========="
push_branch fix/maintenance-cleanup
create_pr fix/maintenance-cleanup \
"fix(maintenance): x/exp removal, lz4 v4, listBlobWorker, context, timeZone global" \
"$(cat <<'EOF'
## Summary

Six small maintenance fixes from a comprehensive review pass:

- Replace \`golang.org/x/exp/constraints\` with stdlib inline constraints
- Migrate \`pierrec/lz4\` v2+incompatible → v4
- Implement \`listBlobWorker\` in provider validation (was a TODO)
- Replace \`context.TODO()\` with \`context.Background()\` in log sweep
- Add timeout context in test server startup
- Move package-level \`timeZone\` global into \`App\` struct

## Test plan

- [ ] \`make test\` — no behavior changes, all existing tests should pass
- [ ] \`make lint\` — passes
EOF
)"

# ---- PR 3: server security hardening -----------------------------------

echo
echo "========== PR 3: server-security-hardening =========="
push_branch fix/server-security-hardening
create_pr fix/server-security-hardening \
"fix(server): JWT v5, request limits, cookie flags, metrics auth, header injection" \
"$(cat <<'EOF'
## Summary

Eight server-side security fixes:

- **JWT v4 → v5** with explicit algorithm validation and issuer/audience verification
- 20 MB request-body size limit on the HTTP handler matching the gRPC limit
- \`HttpOnly\` and \`SameSite\` flags added to auth and session cookies
- Require auth for \`/metrics\` endpoint (was anonymous on the main server)
- Use \`mime.FormatMediaType\` for \`Content-Disposition\` header (prevents header injection via filename)
- Add \`kopia:sensitive\` tag to RClone \`EmbeddedConfig\` so it's never logged
- Strip SSH config from SFTP dial error message (was leaking host/port/user)
- Deduplicate \`reportSeverity\` into the notification package

Includes a new \`internal/server/security_test.go\` (~200 LOC) covering each fix.

## Test plan

- [ ] \`make test ./internal/server/...\` — new tests + existing
- [ ] \`make lint\`
- [ ] Manual: hit \`/metrics\` without auth → 401; hit with auth → 200
EOF
)"

# ---- PR 4: performance hotpaths ----------------------------------------

echo
echo "========== PR 4: performance-allocation-hotpaths =========="
push_branch fix/performance-allocation-hotpaths
create_pr fix/performance-allocation-hotpaths \
"fix(perf): allocation reduction, buffer reuse, fsync, cache scan" \
"$(cat <<'EOF'
## Summary

Six allocation/hotpath fixes:

- Replace \`fmt.Sprintf\` with fast path in \`contentCacheKeyForInfo\`
- Use raw bytes instead of \`String()\` in index \`shard()\`
- Add fast path for single-char prefix in \`comparePrefix\`
- Reuse chunk buffer in object reader
- Add \`fsync\` before rename in disk index cache (durability)
- Store only \`ModTime\` in \`expireUnused\` map (less memory per entry)

Includes new benchmark/unit tests:
- \`repo/content/content_cache_key_test.go\`
- \`repo/content/index/id_test.go\`
- \`repo/content/index/shard_bench_test.go\`

## Test plan

- [ ] \`make test\`
- [ ] \`go test -bench=. ./repo/content/index/...\` — verify shard fast path improves
- [ ] \`make lint\`
EOF
)"

# ---- PR 5: stability ---------------------------------------------------

echo
echo "========== PR 5: stability-error-handling =========="
push_branch fix/stability-error-handling
create_pr fix/stability-error-handling \
"fix(stability): error propagation, cache panic safety, sweep I/O" \
"$(cat <<'EOF'
## Summary

Four stability fixes:

- Propagate callback errors for uncommitted content in \`IterateContents\`
- Fix double-panic in \`PersistentCache.Put\` on invariant violation
- Capture parallel-worker cleanup errors on early return (was swallowed)
- Move cache sweep I/O outside \`listCacheMutex\` (reduces lock hold time)

Adds tests in \`internal/cache/persistent_lru_cache_test.go\` and \`repo/content/content_manager_test.go\`.

## Test plan

- [ ] \`make test\`
- [ ] \`make lint\`
EOF
)"

# ---- WinFsp / Go workspace / lint v2 — split required ------------------

echo
echo "========== WinFsp / workspace / lint-v2 =========="
echo
echo "fix/golangci-lint-v2-windows currently bundles 5 unrelated topics."
echo "It must be split into 3 focused branches before PR'ing."
echo
echo "If you confirm, I'll cherry-pick the commits onto three new branches"
echo "off master:"
echo "  feat/winfsp-mount    <- 9b9a16b7 639b604e 0fa1f5b8 d453f978"
echo "  chore/go-workspace-1.25  <- 6eb8b4ae"
echo "  fix/golangci-v2-windows  <- 9d2cdeb0"
echo "(The duplicate deadlock commit 66f6ca85 is dropped — already in PR 1.)"
echo
if confirm "Split now?"; then
    git switch -c feat/winfsp-mount master \
        && git cherry-pick 9b9a16b7 639b604e 0fa1f5b8 d453f978 \
        && echo "  feat/winfsp-mount: 4 commits"

    git switch -c chore/go-workspace-1.25 master \
        && git cherry-pick 6eb8b4ae \
        && echo "  chore/go-workspace-1.25: 1 commit"

    git switch -c fix/golangci-v2-windows master \
        && git cherry-pick 9d2cdeb0 \
        && echo "  fix/golangci-v2-windows: 1 commit"

    push_branch feat/winfsp-mount
    create_pr feat/winfsp-mount \
"feat(mount): WinFsp/FUSE mount backend for Windows" \
"$(cat <<'EOF'
## Summary

Adds WinFsp/FUSE mount support as an alternative to WebDAV+net use on Windows. Mounted snapshots now appear as local filesystems, enabling Explorer preview pane, thumbnails, and search.

- \`internal/winfsp/winfspfs.go\` — cgofuse filesystem with read-only snapshot access
- \`internal/mount/mount_winfsp.go\` — WinFsp controller with \`PreferWebDAV\` fallback
- \`internal/mount/mount_net_use_helper.go\` — extracted shared WebDAV+net-use logic
- Build with \`-tags winfsp\` (requires CGO + WinFsp SDK)
- Default Windows build (no tag) keeps WebDAV unchanged

Plus three follow-on fixes:
- Free-drive-letter assignment when caller passes \`*\` (cgofuse doesn't grok net-use's \`*\` convention)
- Set \`FileSystemName=NTFS\` so Explorer trusts the volume (preview pane works)
- Always clean up mount state on \`Unmount\` failure — previously left dead controllers in \`s.mounts\`
- Open-file IPC: \`file-viewer.js\` + \`open-file\` IPC handler so the htmlui can open snapshot files in the system default viewer (15 Playwright tests). Companion htmlui PR adds the View button.

## Test plan

- [ ] \`make test\`
- [ ] Manual: \`kopia mount\` a snapshot on Windows; verify Explorer preview pane works
- [ ] Manual: trigger an unmount failure (e.g. file open from another process); verify a subsequent mount works (was permanently broken before \`0fa1f5b8\`)
EOF
)"

    push_branch chore/go-workspace-1.25
    create_pr chore/go-workspace-1.25 \
"chore: update Go workspace to support Go 1.25+ for local htmlui dev" \
"$(cat <<'EOF'
## Summary

Bump \`tools/localhtmlui.work\` to allow Go 1.25 toolchain for local htmlui development workflows.

## Test plan

- [ ] \`make ci-setup\` succeeds with Go 1.25 installed
EOF
)"

    push_branch fix/golangci-v2-windows
    create_pr fix/golangci-v2-windows \
"fix(tools): drop incompatible linter flags for golangci-lint v2 on Windows" \
"$(cat <<'EOF'
## Summary

\`golangci-lint\` v2 reclassified \`gofmt\` and \`goimports\` as formatters, so the \`-D\` flag (which disables linters) no longer accepts them. Since \`.golangci.yml\` controls formatter configuration, these flags are unnecessary.

## Test plan

- [ ] \`make lint\` succeeds on Windows with golangci-lint v2.x
EOF
)"
fi

# ---- comprehensive-review-fixes — do not PR ---------------------------

echo
echo "========== fix/comprehensive-review-fixes =========="
echo "This is a meta-branch that bundles PRs 2-5 together. Maintainers"
echo "won't merge a 600-line multi-topic PR. Skipping PR creation."
echo
if confirm "Push to fork as a snapshot anyway? (no PR)"; then
    push_branch fix/comprehensive-review-fixes
fi

# ---- summary -----------------------------------------------------------

echo
echo "========== Done =========="
echo
echo "Open PRs filed against $UPSTREAM_REPO. Review and add labels/reviewers"
echo "via the GitHub UI as needed."
echo
echo "Remaining manual steps:"
echo "  - Bitdefender exclusion for C:/dev/backup-monitor/target/ (kopia-fuo)"
echo "  - Watch CI on each PR; address feedback"
