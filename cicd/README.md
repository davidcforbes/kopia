# cicd/

Local CI/CD pipeline. Six phases, manual trigger, fail-fast, idempotent.

See [`docs/superpowers/specs/2026-05-05-cicd-pipeline-design.md`](../docs/superpowers/specs/2026-05-05-cicd-pipeline-design.md) for the design rationale.

## Quick start

```bash
make release-and-deploy   # full chain: diagnose → release → deploy → smoke-test
make verify-deployment    # idempotent read-only re-check (~15s)
make bootstrap            # fresh-machine setup (dotnet restore + az login + full chain)
```

## Phases

| # | Make target            | Script                              | Time | Exits non-zero on |
|---|------------------------|-------------------------------------|------|-------------------|
| 1 | `make diagnose`        | `cicd/diagnose-signing.ps1`         | ~10s | bad token, missing role, dlib drift, endpoint unreachable, MITM cert |
| 2 | `make release`         | (existing) `signing/sign-all.ps1`   | ~30s | sign failure, sig drift |
| 3 | `make deploy-artifacts`| `cicd/deploy-artifacts.ps1`         |  ~5s | source not signed, dest locked, source-read transient I/O |
| 4 | `make deploy-tasks`    | `cicd/deploy-tasks.ps1`             |  ~5s | XML parse error, schtasks failure (often elevation) |
| 5 | `make deploy-config`   | `cicd/deploy-config.ps1`            |  ~2s | invalid JSON, `.kopia-pw.dat` ACL flagged |
| 6 | `make smoke-test`      | `cicd/smoke-test.ps1`               | ~45s | server can't start, helper sig invalid, task disabled, kopia already running |

Phase 1 also runs as a preflight inside `make sign-all` (so any sign attempt — through any path — gets the same gate). Set `SKIP_DIAGNOSE=1` to bypass (loud warning; emergency only).

## State file

`cicd/.last-deploy` (gitignored) — JSON record of the last run. Schema:

```json
{
  "runId": "<ISO timestamp>",
  "trigger": "<originating script path>",
  "verdict": "success" | "failure" | "in_progress",
  "phases": {
    "diagnose":         { "status": "ok|failed|skipped|running", "durationMs": N, "message": "...", "timestamp": "...", "recommendedAction": "..." },
    "release":          { ... },
    "deploy-artifacts": { ... },
    "deploy-tasks":     { ... },
    "deploy-config":    { ... },
    "smoke-test":       { ... }
  }
}
```

`verdict` is sticky: any failed phase pins it to `failure`. Only Phase 6 (smoke-test) finalizes it to `success` on a clean run. `running` placeholders are written at phase start so a crash mid-phase still leaves a marker.

`recommendedAction` (failures only) is the exact command to run next.

## Conventions

- **`Makefile.local.mk` is gitignored** on this fork. New targets are added locally, not committed. To replicate the targets on another machine, copy them from this README's quickstart section or regenerate from the design spec.
- **`scripts/scheduled-tasks/*.xml` are PER-HOST snapshots.** They hardcode the user SID and absolute paths; they reproduce the registered tasks ON THIS machine, not portable to other hosts.
- **Tasks with `RunLevel=HighestAvailable`** (e.g., `WbadminHealthCheck`, `KopiaServer`) require an elevated PowerShell session for `make deploy-tasks` to apply changes. A non-elevated invocation will safely report those as failed without modifying state — the prior registration stays intact (atomic `/create /f`).
- **`signing/metadata.json` `ExcludeCredentials`** pins the dlib's identity chain to az CLI and excludes `interactivebrowsercredential` so a credential miss FAILS LOUDLY rather than silently opening a Chrome auth tab.

## Manual test recipes (one per failure category)

| Failure category | How to inject | Expected behavior |
|------------------|---------------|-------------------|
| **Signing infra drift** (dlib version) | edit `signing/dlib/dlib.csproj` → `9.9.9` | Phase 1 emits `[WARN] dlib pin: 9.9.9 (latest 1.0.95)` (warning, not failure) |
| **Identity / RBAC** | `az logout` | Phase 1 fails Check 3 with token-acquisition error + `recommendedAction` of `az login` |
| **Network / endpoint** | block `eus.codesigning.azure.net` in firewall | Phase 1 Check 5 reports TCP failure |
| **Artifact placement (locked)** | `kopia server start` then `make deploy-artifacts` | Phase 3 reports `[FAIL] ... locked by PID N` |
| **Artifact source read** | hold `~/go/bin/kopia.exe` open in another process | Phase 3 cleanly fails with "source unreadable, wait for in-flight signtool" |
| **Task drift** | edit one `scripts/scheduled-tasks/*.xml` | Phase 4 reports `[ok] updated`; revert and re-run reports `current` |
| **Task elevation needed** | edit a `RunLevel=HighestAvailable` XML, run `make deploy-tasks` non-elevated | Phase 4 reports `[FAIL] ... ERROR: Access is denied` (task left intact via `/create /f` atomicity) |
| **Config invalid** | corrupt `D:\KopiaServer\repository.config` JSON | Phase 5 reports `[FAIL] ... unexpected character` |
| **Smoke-test conflict** | start `kopia server` then `make smoke-test` | Phase 6 refuses to run with `[FAIL] kopia already running (PID N)` |

## Bypass mechanisms

- **`git push --no-verify`** — skips the pre-push gate (existing).
- **`SKIP_DIAGNOSE=1 make sign-all`** — bypasses Phase 1 preflight (emergency only; loud warning).
- **No bypass for individual deploy phases** — fix the issue, re-run the failing phase alone.

## Phase script contract (for adding new phases)

Every phase script:

- Sources `cicd/lib/pipeline-state.ps1`.
- Calls `Start-PhaseRun -Phase '<phase-name>'` first; receives a `$run` handle.
- Calls `Complete-PhaseRun -Run $run -Status ok|failed|skipped -Message '...' [-RecommendedAction '...']` at every exit path.
- Exit code: `0` success, `1` expected failure with structured reason in `.last-deploy`, `2` unexpected error.
- Logs via `Write-PhaseLog -Message '...' -Level info|ok|warn|err` for color-coded console output.
- Wraps the body in `try { ... } catch { ... exit 2 }` so unexpected errors emit code 2 cleanly.
- Does NOT call `Set-RunVerdict` (that's Phase 6's job — only the final phase finalizes the run-level verdict).

See `cicd/diagnose-signing.ps1` for a representative example.
