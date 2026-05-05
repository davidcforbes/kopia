# Comprehensive Local CI/CD Pipeline — Design

**Status:** Draft (awaiting user review)
**Date:** 2026-05-05
**Author:** davidcforbes (with Claude assist)
**Supersedes:** the partial pipeline at `Makefile.local.mk` + `signing/` (extended, not replaced)

## Summary

Extend the existing build/sign pipeline at `Makefile.local.mk` into a six-phase
chain — diagnose → release → deploy-artifacts → deploy-tasks → deploy-config →
smoke-test — that takes a source edit through to a verified, deployed system
under a single `make release-and-deploy` invocation. The chain is manual-trigger
only, fail-fast, and fully idempotent. Each phase is a standalone PowerShell
script under a new `cicd/` directory, orchestrated by Make. Trigger model is
explicitly manual (`a` from Q3); diagnostics run as preflight on every sign
attempt (`b` from Q2); deploy covers artifacts + tasks + config (`d` from Q1);
smoke-test is light-dynamic (`b` from Q4).

## Background

### Why now

A 2026-05-05 session burned several hours debugging a signtool 403 that turned
out to be `Microsoft.Trusted.Signing.Client` v1.0.60 using a deprecated
api-version (the service had moved to 2024-06-15). The investigation chased
RBAC, token caching, Bitdefender HTTPS interception, and IPv6 routing
hypotheses before landing on the actual cause. The existing pipeline correctly
reported "all signatures Valid" because they were — from yesterday's run. It
had no preflight check that would have caught the api-version drift, no
diagnostic command to differentiate failure modes, and no way to surface
"infra is fine, just go" vs "something silently broke yesterday."

The user's framing: "I thought we had previously built a comprehensive CI/CD
make script that included all of these details." The honest answer was: yes,
a meaningful pipeline exists (build + sign + verify + pre-push gate +
quarantine-recovery), but it was never designed to detect drift in the
infrastructure that the pipeline depends on.

### Existing assets

```
Makefile.local.mk       # 5 targets: release, sign-all, verify-signatures,
                        # prepush-check, sign-restore
.git/hooks/pre-push     # Calls make prepush-check
signing/sign-all.ps1    # Locates signtool + dlib in NuGet, signs all targets
signing/prepush-check.ps1 # Stamp present, no .go drift, sigs Valid
signing/metadata.json   # Endpoint + account + profile (no secrets)
signing/dlib/dlib.csproj # NuGet pin for Microsoft.Trusted.Signing.Client
scripts/verify_helpers_preflight.ps1 # Daily backup gate
```

This design extends — does not replace — these.

## Goals

1. **Single-command full-stack deploy.** `make release-and-deploy` takes a
   source edit through build, sign, artifact placement, scheduled-task
   reconciliation, config validation, and smoke-test in one invocation.

2. **Catch drift before it bites.** Every sign attempt runs a diagnostic
   preflight that would have caught the 2026-05-05 dlib api-version drift
   before signtool ever returned 403.

3. **Failure modes are self-explaining.** Where today's session had to chase
   five hypotheses to find a deprecated api-version, the new pipeline reports
   the exact gap and the exact fix command in one shot.

4. **Each phase is standalone-runnable.** Debugging a failure means running
   the failing phase alone with the same arguments — no orchestration to
   reproduce.

5. **Idempotent.** A second invocation immediately after a first is a no-op
   in <10 seconds.

6. **Recovery-capable.** A fresh-machine bootstrap (or post-Bitdefender-
   reinstall recovery) is one `make bootstrap` away.

## Non-Goals

- **Cloud CI** (GitHub Actions, etc.). This is a local pipeline; the kopia
  upstream has its own CI.
- **Auto-recovery** beyond the existing `make sign-restore`. Pipeline reports
  the diagnosis and exits; user acts. (Per Section 4 of design discussion.)
- **Resumability.** Each phase is fast and idempotent; re-running the chain
  after fixing a failure is the resume mechanism.
- **Toast integration.** Deferred to a follow-up bead — `backup-monitor.exe`
  could later read `cicd/.last-deploy` and surface red runs via the existing
  `kopiamonitor:` protocol.
- **Pester unit tests.** Phase 6's smoke-test serves as the runtime
  validation; standalone-runnable phases serve as the debug substitute.
- **Auto-pushing config.** Phase 5 validates only — never overwrites
  `metadata.json`, `repository.config`, or anything in the secrets domain.

## Architecture

The pipeline is six phases run sequentially. Each phase is a PowerShell
script with its own exit code; orchestration is in `Makefile.local.mk`.
State passes between phases via files (extends the existing `.last-sign`
pattern), not in-memory — so any phase can be invoked standalone.

```
┌─ make release-and-deploy ────────────────────────────────────────────┐
│                                                                       │
│  1. DIAGNOSE       fast preflight — token + RBAC + dlib version +    │
│     (~5-10s)        endpoint reachability + BD MITM check +          │
│                     sign-API smoke probe (HTTP 400 on empty body)    │
│                                                                       │
│  2. RELEASE        existing — install-noui + sign-all +              │
│     (~30s)          verify-signatures + write .last-sign             │
│                                                                       │
│  3. DEPLOY-ARTIFACTS  copy ~/go/bin/kopia.exe → D:\KopiaServer\bin\,  │
│     (~5s)             KopiaUI bundle path. Verify each landing has   │
│                       Status=Valid signature.                         │
│                                                                       │
│  4. DEPLOY-TASKS   diff scripts/scheduled-tasks/*.xml against        │
│     (~5s)           registered tasks; if drift, schtasks /delete +   │
│                     /create. Emit list of changed tasks.             │
│                                                                       │
│  5. DEPLOY-CONFIG  validate metadata.json + repository.config schema │
│     (~2s)           checksum/size; refuse to overwrite secrets       │
│                     (.kopia-pw.dat) — those stay DPAPI-only.         │
│                                                                       │
│  6. SMOKE-TEST     start kopia server briefly + GET /api/v1/repo/    │
│     (~30-60s)       status; run verify_helpers_preflight.ps1; query  │
│                     Task Scheduler "next run time" for each task.    │
│                                                                       │
│  ✓ write cicd/.last-deploy (timestamp + phases-run + verdict)        │
└───────────────────────────────────────────────────────────────────────┘
```

Total successful run: ~80-110 seconds end-to-end.

### Key properties

- **Fail-fast.** Any phase exits non-zero ⇒ chain stops immediately,
  `.last-deploy` records which phase failed and why. No partial deploys.
- **Idempotent.** Re-running any phase when nothing changed is a no-op.
- **Standalone-runnable.** Every phase has its own `make <phase>` target.
- **Phase 1 also gates `make sign-all`.** Per Q2(b) — any sign attempt
  through any path gets the same diagnostic preflight.
- **`make bootstrap` is a separate top-level target** for fresh-machine
  setup or post-Bitdefender-reinstall recovery: runs `dotnet restore`,
  prompts for `az login` if needed, runs `make release-and-deploy`.

## Components

### New directory: `cicd/`

```
cicd/
├── diagnose-signing.ps1     # Phase 1
├── deploy-artifacts.ps1     # Phase 3
├── deploy-tasks.ps1         # Phase 4
├── deploy-config.ps1        # Phase 5
├── smoke-test.ps1           # Phase 6
├── lib/
│   └── pipeline-state.ps1   # shared: write/read .last-deploy, structured logging
├── .last-deploy             # JSON state file (gitignored)
└── README.md                # phase reference, manual test recipes
```

### New tracked dir: `scripts/scheduled-tasks/`

One `.xml` per task — **desired-state** representation, reconciled by
`make deploy-tasks`:

- `DailyKopiaSnapshotV2.xml`
- `KopiaHeartbeatWatchdog.xml`
- `KopiaStallGuardWatchdog.xml`
- (and any others currently registered under `\Backup\`)

Seeded once via `schtasks /query /xml /tn '\Backup\<name>'`.

### Modified files

| File | Change |
|---|---|
| `Makefile.local.mk` | Add: `diagnose`, `deploy-artifacts`, `deploy-tasks`, `deploy-config`, `smoke-test`, `release-and-deploy`, `bootstrap`, `verify-deployment`, `test-pipeline`. `release` gains `diagnose` as a Make dependency. |
| `signing/sign-all.ps1` | Top of script invokes `cicd/diagnose-signing.ps1`; aborts on non-zero. |
| `.gitignore` (or scoped) | Add `cicd/.last-deploy`. |

### Phase script contract

Every phase script:

- Takes no required arguments. Optional switches: `-VerifyOnly` (for
  test-pipeline mode), `-Force` (skip idempotency early-exit).
- Exit `0` = success; exit `1` = expected failure with structured reason in
  `.last-deploy`; exit `2` = unexpected error.
- Writes a `phase` entry to `cicd/.last-deploy` (JSON) with
  `{ status, durationMs, message, recommendedAction?, timestamp }`.
- Logs via `Write-Host` for console; via `lib/pipeline-state.ps1` helper
  for state-file writes.

## Data Flow

### Source-of-truth map

| Authoritative source | Derived/destination |
|---|---|
| `signing/dlib/dlib.csproj` (`Version="1.0.95"`) | NuGet cache `~\.nuget\packages\microsoft.trusted.signing.client\1.0.95\` |
| `signing/metadata.json` | Loaded by signtool via `/dmdf` |
| `~/go/bin/kopia.exe` (output of `install-noui`) | `D:\KopiaServer\bin\kopia.exe`, KopiaUI bundle path |
| `scripts/*.ps1` | Signed in place (no copy — same path is both src and dst) |
| `scripts/scheduled-tasks/*.xml` | Registered Task Scheduler entries under `\Backup\` |
| `signing/.last-sign` | Read by `prepush-check.ps1` for staleness check |
| `cicd/.last-deploy` | Read by `make verify-deployment`; future toast integration |

### Per-phase I/O

```
PHASE 1: diagnose-signing.ps1
  reads:  signing/metadata.json
          signing/dlib/dlib.csproj (version pin)
          az CLI token cache (via az account get-access-token)
          NuGet API (https://api.nuget.org/v3-flatcontainer/microsoft.trusted.signing.client/index.json)
          eus.codesigning.azure.net (curl -4 + REST POST {} probe)
          Cert:\CurrentUser\Root for Bitdefender CA presence
  writes: cicd/.last-deploy["phases"]["diagnose"]
  fails:  expired/missing token | missing role | dlib > N versions behind |
          MITM cert detected on signing endpoint | sign API not 400 on empty POST

PHASE 2: release  (existing — install-noui + sign-all + verify-signatures)
  reads:  Go source tree, signing/* artifacts
  writes: ~/go/bin/kopia.exe, scripts/*.ps1 (signed in place), signing/.last-sign

PHASE 3: deploy-artifacts.ps1
  reads:  ~/go/bin/kopia.exe (must have Status=Valid)
  writes: D:\KopiaServer\bin\kopia.exe                                          (server-mode binary)
          C:\dev\kopia\dist\kopia-ui\win-unpacked\resources\server\kopia.exe    (UI bundle)
  fails:  source not signed | dest not writable | post-copy sig drift
  guards: refuses to overwrite a destination if any kopia.exe process holds it

PHASE 4: deploy-tasks.ps1
  reads:  scripts/scheduled-tasks/*.xml
          schtasks /query /xml /tn '\Backup\<name>'
  writes: Registered tasks (via schtasks /delete + /create)
  fails:  XML parse error | schtasks non-zero | missing run-as user | task currently running

PHASE 5: deploy-config.ps1  [conservative — validate only]
  reads:  signing/metadata.json (schema check)
          D:\KopiaServer\repository.config (JSON parse check)
          scripts/.kopia-pw.dat (existence + ACL check, NEVER reads content)
  writes: nothing (read-only validation; emits warnings to .last-deploy)
  fails:  invalid JSON | metadata.json missing required fields |
          .kopia-pw.dat ACL too permissive

PHASE 6: smoke-test.ps1
  reads:  All artifacts placed by phases 2-4
  writes: Temporarily starts kopia server (background), shuts it down after probe
          cicd/.last-deploy["phases"]["smoke-test"]
  fails:  server doesn't start | /api/v1/repo/status != 200 |
          verify_helpers_preflight.ps1 fails | any task missing/disabled
  guards: refuses to run if any kopia.exe process already exists
```

### State file shape (`cicd/.last-deploy`)

```json
{
  "runId": "2026-05-05T16:42:11-04:00",
  "trigger": "make release-and-deploy",
  "verdict": "success",
  "phases": {
    "diagnose":         { "status": "ok", "durationMs": 4200,  "message": "all checks passed" },
    "release":          { "status": "ok", "durationMs": 28100, "message": "10 artifacts signed" },
    "deploy-artifacts": { "status": "ok", "durationMs": 4800,  "message": "kopia.exe → 2 paths" },
    "deploy-tasks":     { "status": "ok", "durationMs": 3500,  "message": "no drift, 3 tasks current" },
    "deploy-config":    { "status": "ok", "durationMs": 1900,  "message": "all configs valid" },
    "smoke-test":       { "status": "ok", "durationMs": 42600, "message": "server 200, helpers Valid, 3 tasks scheduled" }
  }
}
```

On failure, the failing phase's entry includes a `recommendedAction` string
with the exact next command to run, and downstream phases get
`{ "status": "skipped", "reason": "phase X failed" }`.

### Failure-stop behavior

`make release-and-deploy` is implemented as a Make rule chain:

```make
release-and-deploy: diagnose release deploy-artifacts deploy-tasks deploy-config smoke-test
```

Make's natural behavior on Windows (with `$ErrorActionPreference = 'Stop'` in
PowerShell child processes) gives fail-fast for free.

## Error Handling & Recovery

### Failure taxonomy

| # | Category | Example (from 2026-05-05 session) | Phase 1 detects? | Recovery |
|---|---|---|---:|---|
| **1** | Signing infra drift | dlib v1.0.60 → service deprecated its api-version | ✅ (NuGet version diff + sign-API smoke probe) | `make diagnose` reports exact gap; user bumps `dlib.csproj`; `dotnet restore`; rerun |
| **2** | Identity / RBAC | Chris missing `Signer` role at profile scope | ✅ (token decode + role list) | Phase 1 emits the exact `az role assignment create` command needed |
| **3** | Network / endpoint | BD MITM, IPv6 hang, DNS resolution | ✅ (curl -4 probe + cert chain inspection) | Phase 1 reports which check failed; user fixes BD/network/DNS manually |
| **4** | Artifact placement | kopia.exe locked by running server | ❌ (Phase 3 detects) | Phase 3 emits "stop kopia process PID NNN, then `make deploy-artifacts`"; doesn't auto-stop |
| **5** | Runtime / smoke-test | Server starts but `/api/v1/repo/status` fails | ❌ (Phase 6 detects) | Phase 6 captures server stderr + the failed HTTP response into `.last-deploy`; user acts |

### Recovery model

**No auto-recovery.** Pipeline reports the diagnosis + suggested fix, exits
non-zero, and lets the user act. This is deliberate per CLAUDE.md's
"executing actions with care" guidance — automating recovery for category
2-4 means writing privileged Azure / process / Task Scheduler operations
that the user might not want triggered automatically.

The exception: **`make sign-restore`** stays as the one auto-recovery
target (BD-quarantine recovery from `C:\Temp\kopia-restore\`).

### Surfacing

| Surface | Content |
|---|---|
| **Console** (Write-Host) | Live human-readable log of each phase, color-coded |
| **`cicd/.last-deploy`** | Structured JSON: phase status + duration + message + (on failure) `recommendedAction` |
| **Exit code** | `0` success; `1` expected failure (with .last-deploy explaining); `2` unexpected error |
| **Toast** | Deferred to follow-up bead. `backup-monitor.exe` could read `.last-deploy` and surface red runs via `kopiamonitor:` protocol. |

### Bypass mechanisms

- **`--no-verify` on `git push`** — already exists, unchanged.
- **`make sign-all SKIP_DIAGNOSE=1`** — env var allows skipping the new
  Phase 1 preflight if the diagnostic itself is broken. Console output
  flags the bypass loudly.
- **No bypass for individual deploy phases** — they're fail-fast individually
  but you can run each one independently, so if Phase 4 fails you can fix
  the XML and re-run just `make deploy-tasks`.

### Resumability

**Not resumable** by design. Each phase is fast and idempotent, so re-running
the chain after fixing the failed phase is equivalent to "resume" but
simpler. If rerun cost ever becomes a problem (e.g., Phase 2 starts taking
5 minutes), revisit.

## Testing

For a single-machine personal pipeline, formal unit tests would be over-
engineering. Testing leverages the design's own properties:

1. **Phase 6 is the runtime test of phases 1-5.** If smoke-test is green,
   phases 1-5 demonstrably worked.
2. **Idempotency is a contract, exercised every run.** A second invocation
   that does work would be immediately visible.
3. **Standalone-runnable phases are the unit-test substitute.** Edit a task
   XML and run `make deploy-tasks` to "test" Phase 4's diff logic.

### v1 testing deliverables

| Item | What |
|---|---|
| **`make test-pipeline`** | Runs every phase in `-VerifyOnly` / read-only mode (no writes). Reports findings to console + `.last-deploy`. ~30 seconds. |
| **First-run validation** | After implementation, run `make release-and-deploy` end-to-end. Verify each phase's `.last-deploy` entry shows `status: ok`. |
| **Idempotency check** | Run `make release-and-deploy` immediately after the first success. Confirm runtime drops to <10s and every phase reports a "no work needed" message. |
| **Failure-injection spot-checks** | Bump `dlib.csproj` to a non-existent version (e.g., `9.9.9`) and confirm Phase 1 catches it with a clear error. Stop the kopia server and confirm Phase 6's "refuse if running" guard fires. Each takes <1 minute. |
| **`cicd/README.md`** | Documents manual test recipes — one per failure category from the table above. |

No Pester. No CI runner. The pipeline IS the test harness.

## Open Questions / Follow-ups

1. **Toast integration with `backup-monitor.exe`.** Out of scope for v1,
   filed as a follow-up bead during implementation.
2. **`scripts/scheduled-tasks/*.xml` initial seed.** First implementation
   step is to export the currently-registered task XMLs into the new
   directory, then commit. This locks in current state as the desired
   state — drift detection becomes meaningful from that point forward.
3. **Phase 1's "dlib > N versions behind" threshold.** N is currently
   undefined. Recommendation: `N = 0` initially (warn on any newer version
   on NuGet) to surface drift early, with a way to silence specific known-
   bad newer versions if needed.
4. **Phase 6's kopia server lifecycle.** The smoke-test starts and stops
   a brief server. Need to confirm this doesn't conflict with the
   "real" kopia server that `start_kopia_server.ps1` may have running.
   The Phase 6 guard refuses to run in that case — but a "the server is
   already up, just probe it" mode might be valuable later.

## References

### Today's session commits (foundation for this work)

- `31811507` — Wrapper PID + cache fixes (kopia-i1p, kopia-0m5)
- `e3721f45` — `metadata.json` ExcludeCredentials pinning to az CLI
- `8b5e24c3` — **Dlib bump 1.0.60 → 1.0.95** — actual fix for the 2026-05-05 403
- `416466cf` — Add `get_parent_pid.ps1` to sign-all targets

### Beads

- `kopia-2lf` — closed by 8b5e24c3 + 416466cf (sign get_parent_pid + add to verifier)
- `kopia-2vk` — Bitdefender HTTPS interception breaking IPv6 to management.azure.com (still open; relevant to Phase 1's network checks)
- `kopia-bsv` — dedicated `kopia` cert profile (separate concern)

### Memory

- `reference_trusted_signing_rbac.md` — RBAC + dlib version + DefaultAzureCredential chain (today's takeaways, with "check dlib version FIRST" as step 0)
- `reference_backup_architecture.md` — backup-monitor + scheduled task topology (informs Phase 4)

### Existing pipeline

- `Makefile.local.mk` — extended by this design
- `signing/README.md` — current pipeline documentation; will be updated to reference `cicd/README.md` for the new phases
- `signing/sign-all.ps1` — gains a Phase 1 invocation at the top
- `signing/prepush-check.ps1` — unchanged; still gates push on stamp + .go drift + sigs Valid
- `scripts/verify_helpers_preflight.ps1` — invoked by Phase 6 against freshly-signed helpers
