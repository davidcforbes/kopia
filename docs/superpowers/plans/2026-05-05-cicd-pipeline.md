# CI/CD Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the six-phase local CI/CD pipeline specified in `docs/superpowers/specs/2026-05-05-cicd-pipeline-design.md` (commit `be666dd8`), one phase at a time, with each phase validated before the next begins.

**Architecture:** PowerShell scripts under a new `cicd/` directory implement individual phases; `Makefile.local.mk` orchestrates them. State passes between phases via `cicd/.last-deploy` JSON. Phase 1 (diagnose) gates Phase 2 (sign-all). Phases 3-5 reconcile artifacts/tasks/config. Phase 6 smoke-tests the result. The full chain is `make release-and-deploy`.

**Tech Stack:** PowerShell 7+ (`pwsh`), GNU Make on Windows, `signtool.exe`, `Microsoft.Trusted.Signing.Client` v1.0.95 dlib, `az` CLI, `schtasks`, kopia (Go binary).

**Working dir:** `C:\dev\kopia` (Git Bash for `make` and `git`; PowerShell for direct script work).

---

## Task 1: Scaffold `cicd/` directory + shared state library

**Files:**
- Create: `cicd/lib/pipeline-state.ps1`
- Create: `cicd/.gitignore`
- Create: `cicd/README.md` (placeholder; final content in Task 11)
- Modify: `.gitignore` (root) — add `cicd/.last-deploy`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p /c/dev/kopia/cicd/lib
```

- [ ] **Step 2: Write `cicd/lib/pipeline-state.ps1`**

Create `C:\dev\kopia\cicd\lib\pipeline-state.ps1`:

```powershell
# pipeline-state.ps1 — shared helpers for cicd/ phase scripts.
# - Read/write cicd/.last-deploy JSON
# - Structured per-phase logging
# - Color-coded console output
#
# Sourced via: . "$PSScriptRoot\..\lib\pipeline-state.ps1"

$script:CicdRoot     = (Resolve-Path "$PSScriptRoot\..").Path
$script:StateFile    = Join-Path $CicdRoot '.last-deploy'

function Get-PipelineState {
    if (-not (Test-Path $script:StateFile)) {
        return [pscustomobject]@{
            runId   = $null
            trigger = $null
            verdict = $null
            phases  = [ordered]@{}
        }
    }
    $raw = Get-Content $script:StateFile -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{ runId = $null; trigger = $null; verdict = $null; phases = [ordered]@{} }
    }
    return $raw | ConvertFrom-Json
}

function Set-PipelineState {
    param([Parameter(Mandatory)] $State)
    $json = $State | ConvertTo-Json -Depth 10
    Set-Content -Path $script:StateFile -Value $json -Encoding UTF8
}

function Start-PhaseRun {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [string]$Trigger = $MyInvocation.PSCommandPath
    )
    $state = Get-PipelineState
    if (-not $state.runId -or $state.verdict -in @('success', 'failure')) {
        # Start a new run
        $state = [pscustomobject]@{
            runId   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
            trigger = $Trigger
            verdict = 'in_progress'
            phases  = [ordered]@{}
        }
    }
    Set-PipelineState $state
    return [pscustomobject]@{
        Phase     = $Phase
        StartTime = Get-Date
    }
}

function Complete-PhaseRun {
    param(
        [Parameter(Mandatory)] $Run,
        [Parameter(Mandatory)][ValidateSet('ok', 'failed', 'skipped')] $Status,
        [Parameter(Mandatory)][string] $Message,
        [string] $RecommendedAction
    )
    $state = Get-PipelineState
    $entry = [ordered]@{
        status      = $Status
        durationMs  = [int]((Get-Date) - $Run.StartTime).TotalMilliseconds
        message     = $Message
        timestamp   = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
    }
    if ($RecommendedAction) { $entry.recommendedAction = $RecommendedAction }

    # PSObject -> hashtable mutation
    $phases = [ordered]@{}
    if ($state.phases) {
        $state.phases.PSObject.Properties | ForEach-Object { $phases[$_.Name] = $_.Value }
    }
    $phases[$Run.Phase] = $entry
    $state.phases = $phases

    if ($Status -eq 'failed') { $state.verdict = 'failure' }
    elseif ($Status -eq 'ok' -and $state.verdict -eq 'in_progress') { $state.verdict = 'in_progress' }

    Set-PipelineState $state
}

function Write-PhaseLog {
    param([string]$Message, [ValidateSet('info','ok','warn','err')]$Level = 'info')
    $color = switch ($Level) {
        'ok'   { 'Green' }
        'warn' { 'Yellow' }
        'err'  { 'Red' }
        default { 'White' }
    }
    Write-Host $Message -ForegroundColor $color
}

function Set-RunVerdict {
    param([Parameter(Mandatory)][ValidateSet('success','failure','in_progress')]$Verdict)
    $state = Get-PipelineState
    $state.verdict = $Verdict
    Set-PipelineState $state
}
```

- [ ] **Step 3: Write `cicd/.gitignore`**

Create `C:\dev\kopia\cicd\.gitignore`:

```
.last-deploy
```

- [ ] **Step 4: Add to root `.gitignore` defensively**

Add a single line to `C:\dev\kopia\.gitignore` if not already present:

```
cicd/.last-deploy
```

- [ ] **Step 5: Create placeholder `cicd/README.md`**

Create `C:\dev\kopia\cicd\README.md`:

```markdown
# cicd/

Local CI/CD pipeline scripts. See
[`docs/superpowers/specs/2026-05-05-cicd-pipeline-design.md`](../docs/superpowers/specs/2026-05-05-cicd-pipeline-design.md)
for the design.

Final phase reference + manual test recipes will be filled in once all
phases are implemented (see plan Task 11).
```

- [ ] **Step 6: Smoke-test the state library**

Run from PowerShell:

```powershell
. C:\dev\kopia\cicd\lib\pipeline-state.ps1
$run = Start-PhaseRun -Phase 'test'
Complete-PhaseRun -Run $run -Status 'ok' -Message 'smoke test'
Get-Content C:\dev\kopia\cicd\.last-deploy
Remove-Item C:\dev\kopia\cicd\.last-deploy
```

Expected: a `.last-deploy` JSON appears with one phase entry under `phases.test` with `status: "ok"`.

- [ ] **Step 7: Commit**

```bash
cd /c/dev/kopia
git add cicd/lib/pipeline-state.ps1 cicd/.gitignore cicd/README.md .gitignore
git commit -m "cicd: scaffold cicd/ directory + pipeline-state library

Shared PowerShell helpers for the new six-phase pipeline:
- Get/Set-PipelineState read/write cicd/.last-deploy JSON
- Start/Complete-PhaseRun bracket each phase invocation with timing
- Write-PhaseLog gives color-coded console output

Per design spec be666dd8 / Task 1 of plan."
```

---

## Task 2: Phase 1 — `diagnose-signing.ps1`

**Files:**
- Create: `cicd/diagnose-signing.ps1`
- Modify: `Makefile.local.mk` (add `diagnose` target)
- Modify: `signing/sign-all.ps1` (invoke diagnose at top, respect `SKIP_DIAGNOSE` env var)

- [ ] **Step 1: Write `cicd/diagnose-signing.ps1`**

Create `C:\dev\kopia\cicd\diagnose-signing.ps1`:

```powershell
# diagnose-signing.ps1 — Phase 1 of the cicd pipeline.
# Verifies every prerequisite for a successful Trusted Signing operation:
#   1. signing/metadata.json present + parses
#   2. signing/dlib/dlib.csproj version vs latest on NuGet
#   3. az CLI token valid + correct audience + correct identity
#   4. Role assignment present at the cert profile or account scope
#   5. Endpoint reachable over IPv4 (kopia-2vk: IPv6 to mgmt.azure.com is broken)
#   6. Sign API returns 400 (not 403) on empty POST — proves auth/RBAC OK
#   7. Bitdefender MITM CA NOT intercepting the signing endpoint
#
# Exit codes: 0 success, 1 expected failure with reason, 2 unexpected error.

[CmdletBinding()]
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\pipeline-state.ps1"

$run = Start-PhaseRun -Phase 'diagnose'
$failures = @()
$warnings = @()
$repo = 'C:\dev\kopia'

Write-PhaseLog "[diagnose] Phase 1 — signing infrastructure preflight" -Level info

# Check 1 — metadata.json
try {
    $metaPath = Join-Path $repo 'signing\metadata.json'
    $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
    foreach ($f in 'Endpoint','CodeSigningAccountName','CertificateProfileName') {
        if (-not $meta.$f) { throw "metadata.json missing required field: $f" }
    }
    Write-PhaseLog "  [ok] metadata.json: $($meta.CodeSigningAccountName)/$($meta.CertificateProfileName)" -Level ok
} catch {
    $failures += "metadata.json: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] metadata.json: $($_.Exception.Message)" -Level err
}

# Check 2 — dlib version vs NuGet latest
try {
    $csproj = [xml](Get-Content (Join-Path $repo 'signing\dlib\dlib.csproj'))
    $pinned = ($csproj.Project.ItemGroup.PackageReference | Where-Object Include -eq 'Microsoft.Trusted.Signing.Client').Version
    $idx = Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/microsoft.trusted.signing.client/index.json' -ErrorAction Stop
    $latest = $idx.versions[-1]
    if ($pinned -ne $latest) {
        $warnings += "dlib pinned at $pinned; NuGet latest is $latest"
        Write-PhaseLog "  [WARN] dlib pin: $pinned (latest $latest)" -Level warn
    } else {
        Write-PhaseLog "  [ok] dlib pin: $pinned (matches NuGet latest)" -Level ok
    }
} catch {
    $warnings += "could not verify dlib version: $($_.Exception.Message)"
    Write-PhaseLog "  [WARN] dlib version check: $($_.Exception.Message)" -Level warn
}

# Check 3 — az token valid for codesigning audience
try {
    $az = (Get-Command az.cmd -ErrorAction SilentlyContinue).Source
    if (-not $az) { $az = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' }
    $rawToken = & $az account get-access-token --resource 'https://codesigning.azure.net' --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az get-access-token failed: $rawToken" }
    $payloadB64 = ($rawToken -split '\.')[1]
    while ($payloadB64.Length % 4 -ne 0) { $payloadB64 += '=' }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
        $payloadB64.Replace('-','+').Replace('_','/'))) | ConvertFrom-Json
    if ($claims.aud -ne 'https://codesigning.azure.net') {
        throw "token audience mismatch: $($claims.aud)"
    }
    $expiresIn = ([DateTimeOffset]::FromUnixTimeSeconds($claims.exp).LocalDateTime - (Get-Date)).TotalMinutes
    if ($expiresIn -lt 5) { throw "token expires in $([int]$expiresIn) min — refresh with az login" }
    Write-PhaseLog "  [ok] az token: $($claims.upn) ($([int]$expiresIn) min remaining)" -Level ok
    $script:tokenOid = $claims.oid
    $script:tokenUpn = $claims.upn
} catch {
    $failures += "az token: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] az token: $($_.Exception.Message)" -Level err
}

# Check 4 — role assignment present
if ($script:tokenOid) {
    try {
        $scope = "/subscriptions/$($meta.SubscriptionId ?? '0dee2894-9caa-4e29-a059-6b241427c811')/resourceGroups/codesign/providers/Microsoft.CodeSigning/codeSigningAccounts/$($meta.CodeSigningAccountName)"
        $assignments = & $az role assignment list --assignee $script:tokenOid --scope $scope --include-inherited --query "[?roleDefinitionName=='Artifact Signing Certificate Profile Signer'].roleDefinitionName" -o tsv 2>&1
        if (-not $assignments) {
            $rec = "az role assignment create --assignee $($script:tokenOid) --role 'Artifact Signing Certificate Profile Signer' --scope `"$scope/certificateProfiles/$($meta.CertificateProfileName)`""
            $failures += "role 'Artifact Signing Certificate Profile Signer' not assigned to $($script:tokenUpn) at $scope or descendants"
            Write-PhaseLog "  [FAIL] no Signer role for $($script:tokenUpn)" -Level err
            Write-PhaseLog "         Suggested fix: $rec" -Level warn
            $script:roleFix = $rec
        } else {
            Write-PhaseLog "  [ok] Signer role assigned (visible at $scope or descendant)" -Level ok
        }
    } catch {
        $warnings += "role assignment check failed: $($_.Exception.Message)"
        Write-PhaseLog "  [WARN] role check: $($_.Exception.Message)" -Level warn
    }
}

# Check 5 — endpoint reachable over IPv4
try {
    $endpoint = $meta.Endpoint
    $host = ([uri]$endpoint).Host
    $tcp = Test-NetConnection -ComputerName $host -Port 443 -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) { throw "TCP to ${host}:443 failed" }
    Write-PhaseLog "  [ok] $host reachable (v4: $($tcp.RemoteAddress))" -Level ok
} catch {
    $failures += "endpoint reachability: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] endpoint: $($_.Exception.Message)" -Level err
}

# Check 6 — sign API returns 400 on empty POST (proves auth+RBAC OK; isolates dlib drift)
if ($script:tokenOid -and $rawToken) {
    try {
        $url = "$($meta.Endpoint)/codesigningaccounts/$($meta.CodeSigningAccountName)/certificateprofiles/$($meta.CertificateProfileName)/sign?api-version=2024-06-15"
        $curl = (Get-Command curl.exe).Source
        $resp = & $curl -4 -s -o NUL -w '%{http_code}' -X POST -H "Authorization: Bearer $rawToken" -H 'Content-Type: application/json' -d '{}' --max-time 15 $url 2>&1
        if ($resp -eq '400') {
            Write-PhaseLog "  [ok] sign API smoke probe: HTTP 400 (auth+RBAC accepted, body rejected as expected)" -Level ok
        } elseif ($resp -eq '403') {
            $failures += "sign API returns 403 — RBAC issue or service-side deny"
            Write-PhaseLog "  [FAIL] sign API: HTTP 403 — auth was rejected" -Level err
        } else {
            $warnings += "sign API smoke probe returned HTTP $resp (expected 400)"
            Write-PhaseLog "  [WARN] sign API: HTTP $resp" -Level warn
        }
    } catch {
        $warnings += "sign API smoke probe error: $($_.Exception.Message)"
        Write-PhaseLog "  [WARN] sign API probe: $($_.Exception.Message)" -Level warn
    }
}

# Check 7 — Bitdefender MITM CA in trust store (informational)
$bdCa = Get-ChildItem Cert:\CurrentUser\Root,Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -match 'Bitdefender' }
if ($bdCa) {
    $warnings += "Bitdefender MITM CA present in trust store ($(($bdCa | Select-Object -First 1).Thumbprint)) — verify HTTPS-scan exemptions if signing fails"
    Write-PhaseLog "  [WARN] Bitdefender MITM CA detected in trust store" -Level warn
} else {
    Write-PhaseLog "  [ok] no MITM CA in trust store" -Level ok
}

# Verdict
$message = if ($failures) {
    "FAIL: $($failures.Count) failure(s); $($warnings.Count) warning(s)"
} elseif ($warnings) {
    "OK with $($warnings.Count) warning(s)"
} else {
    "all checks passed"
}

if ($failures) {
    Complete-PhaseRun -Run $run -Status 'failed' -Message $message -RecommendedAction ($script:roleFix)
    Write-PhaseLog "[diagnose] $message" -Level err
    foreach ($f in $failures) { Write-PhaseLog "  - $f" -Level err }
    exit 1
} else {
    Complete-PhaseRun -Run $run -Status 'ok' -Message $message
    Write-PhaseLog "[diagnose] $message" -Level ok
    foreach ($w in $warnings) { Write-PhaseLog "  - $w" -Level warn }
    exit 0
}
```

- [ ] **Step 2: Add `diagnose` target to `Makefile.local.mk`**

Append to `C:\dev\kopia\Makefile.local.mk`:

```make
.PHONY: diagnose

# Phase 1 — signing infra preflight (token, RBAC, dlib version, endpoint, BD MITM)
diagnose:
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(CURDIR)/cicd/diagnose-signing.ps1"
```

Also update the `.PHONY` line at the top — change:

```make
.PHONY: release sign-all verify-signatures prepush-check sign-restore
```

to:

```make
.PHONY: release sign-all verify-signatures prepush-check sign-restore diagnose
```

- [ ] **Step 3: Modify `signing/sign-all.ps1` to invoke diagnose**

In `C:\dev\kopia\signing\sign-all.ps1`, immediately after the `param(...)` block and `$ErrorActionPreference = 'Stop'` line (around line 12), insert:

```powershell
# Phase 1 preflight (skippable for emergency only).
if (-not $env:SKIP_DIAGNOSE) {
    & "$PSScriptRoot\..\cicd\diagnose-signing.ps1"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "diagnose-signing.ps1 reported failures (exit $LASTEXITCODE) — aborting sign-all." -ForegroundColor Red
        Write-Host "  Set `$env:SKIP_DIAGNOSE = '1' to bypass (not recommended)." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "[sign-all] SKIP_DIAGNOSE=1 — bypassing Phase 1 preflight (not recommended)." -ForegroundColor Yellow
}
```

- [ ] **Step 4: Smoke-test diagnose standalone**

Run:

```bash
cd /c/dev/kopia && make diagnose
```

Expected output: phase log shows `[ok]` for each of 7 checks (or `[WARN]` for BD), and exits 0 with `[diagnose] all checks passed` or `OK with N warning(s)`. Confirm `cicd/.last-deploy` has a `phases.diagnose` entry with `status: "ok"`.

- [ ] **Step 5: Failure-injection test — bump dlib to nonsense version**

Edit `signing/dlib/dlib.csproj` and temporarily change the version to `9.9.9` (a nonexistent version). Run:

```bash
make diagnose
```

Expected: Check 2 emits `[WARN] dlib pin: 9.9.9 (latest 1.0.95)` (warning, not failure — version check is non-blocking). Then revert the change.

- [ ] **Step 6: Failure-injection test — wrong audience**

Run:

```bash
SKIP_DIAGNOSE=1 make sign-all 2>&1 | head -3
```

Expected: warning printed about bypass, sign-all proceeds. Confirms the env-var bypass works.

- [ ] **Step 7: Test that sign-all without bypass invokes diagnose**

Run:

```bash
unset SKIP_DIAGNOSE
make sign-all 2>&1 | head -10
```

Expected: see `[diagnose] Phase 1 — signing infrastructure preflight` BEFORE any signtool output.

- [ ] **Step 8: Commit**

```bash
cd /c/dev/kopia
git add cicd/diagnose-signing.ps1 Makefile.local.mk signing/sign-all.ps1
git commit -m "cicd: phase 1 — diagnose-signing preflight

Validates token, RBAC, dlib version, endpoint reachability, sign-API
auth handshake (400 = OK, 403 = RBAC problem), and Bitdefender MITM
presence. Runs on every \`make sign-all\` unless SKIP_DIAGNOSE=1.

Would have caught the 2026-05-05 dlib v1.0.60 deprecation in <5s
instead of after several hours of investigation.

Per plan Task 2."
```

---

## Task 3: Phase 2 — wire `release` target to depend on `diagnose`

**Files:**
- Modify: `Makefile.local.mk` — `release` target

- [ ] **Step 1: Update `release` target dependency**

In `C:\dev\kopia\Makefile.local.mk`, find:

```make
release: install-noui sign-all verify-signatures
```

Change to:

```make
release: diagnose install-noui sign-all verify-signatures
```

(Phase 1 runs both via this Make dep AND inside sign-all's PowerShell. Belt and suspenders — the Make dep makes it visible in `make release`'s execution log; the embedded call ensures bypass also gets diagnosed when called directly.)

- [ ] **Step 2: Run release end-to-end**

```bash
cd /c/dev/kopia
make release 2>&1 | tail -20
```

Expected: diagnose runs first (you'll see its log), then install-noui builds kopia.exe, then sign-all signs everything, then verify-signatures confirms Valid status. Exits 0.

- [ ] **Step 3: Commit**

```bash
git add Makefile.local.mk
git commit -m "cicd: gate release target on Phase 1 diagnose

Per plan Task 3."
```

---

## Task 4: Phase 3 — `deploy-artifacts.ps1`

**Files:**
- Create: `cicd/deploy-artifacts.ps1`
- Modify: `Makefile.local.mk` (add `deploy-artifacts` target)

- [ ] **Step 1: Identify deploy destinations**

Run to confirm the destination paths exist on this machine:

```powershell
Test-Path 'D:\KopiaServer\bin'                                                              # server-mode binary location
Test-Path 'C:\dev\kopia\dist\kopia-ui\win-unpacked\resources\server\kopia.exe'              # UI bundle (may not exist if UI not built)
```

Note which return `$true`. Only deploy to existing destinations — don't auto-create. The plan assumes at least `D:\KopiaServer\bin` exists.

- [ ] **Step 2: Write `cicd/deploy-artifacts.ps1`**

Create `C:\dev\kopia\cicd\deploy-artifacts.ps1`:

```powershell
# deploy-artifacts.ps1 — Phase 3 of the cicd pipeline.
# Copies signed kopia.exe from build location to runtime locations, refusing
# to overwrite if any kopia.exe process holds the destination.
#
# Idempotent: if dest is already byte-identical to source AND has Status=Valid,
# the copy is skipped. Re-running on an already-deployed system is a no-op.

[CmdletBinding()]
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\pipeline-state.ps1"

$run = Start-PhaseRun -Phase 'deploy-artifacts'
Write-PhaseLog "[deploy-artifacts] Phase 3 — placing signed binaries at runtime locations" -Level info

$source = "$env:USERPROFILE\go\bin\kopia.exe"
$destinations = @(
    'D:\KopiaServer\bin\kopia.exe',
    'C:\dev\kopia\dist\kopia-ui\win-unpacked\resources\server\kopia.exe'
)

# Source must exist + be signed Valid
if (-not (Test-Path $source)) {
    Complete-PhaseRun -Run $run -Status 'failed' -Message "source not found: $source" `
        -RecommendedAction "make release   (rebuilds + signs kopia.exe)"
    Write-PhaseLog "  [FAIL] source missing: $source" -Level err
    exit 1
}

$srcSig = Get-AuthenticodeSignature $source
if ($srcSig.Status -ne 'Valid') {
    Complete-PhaseRun -Run $run -Status 'failed' -Message "source signature: $($srcSig.Status)" `
        -RecommendedAction "make release   (rebuilds + signs kopia.exe)"
    Write-PhaseLog "  [FAIL] source not Valid: $source ($($srcSig.Status))" -Level err
    exit 1
}

$srcHash = (Get-FileHash $source -Algorithm SHA256).Hash
Write-PhaseLog "  source: $source ($([int]((Get-Item $source).Length/1MB)) MB, $srcHash)" -Level info

$copied = @()
$skipped = @()
$errors = @()

foreach ($dest in $destinations) {
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) {
        Write-PhaseLog "  [skip] $dest (parent $destDir not present — destination disabled on this host)" -Level warn
        $skipped += "$dest (parent missing)"
        continue
    }

    # Refuse if held by a running process
    $procs = Get-Process -Name 'kopia' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $dest }
    if ($procs) {
        $pids = ($procs.Id -join ', ')
        $errors += "$dest is locked by kopia.exe (PID $pids)"
        Write-PhaseLog "  [FAIL] $dest locked by PID $pids" -Level err
        continue
    }

    # Idempotency: skip if already identical
    if (Test-Path $dest) {
        $destHash = (Get-FileHash $dest -Algorithm SHA256).Hash
        if ($destHash -eq $srcHash) {
            $destSig = Get-AuthenticodeSignature $dest
            if ($destSig.Status -eq 'Valid') {
                Write-PhaseLog "  [ok] $dest already current (hash + sig match)" -Level ok
                $skipped += "$dest (already current)"
                continue
            }
        }
    }

    if ($VerifyOnly) {
        Write-PhaseLog "  [would-copy] $dest" -Level info
        continue
    }

    try {
        Copy-Item $source $dest -Force
        $verifySig = Get-AuthenticodeSignature $dest
        if ($verifySig.Status -ne 'Valid') {
            throw "post-copy signature: $($verifySig.Status)"
        }
        Write-PhaseLog "  [ok] copied → $dest" -Level ok
        $copied += $dest
    } catch {
        $errors += "$dest: $($_.Exception.Message)"
        Write-PhaseLog "  [FAIL] $dest: $($_.Exception.Message)" -Level err
    }
}

if ($errors) {
    $msg = "$($errors.Count) error(s); $($copied.Count) copied; $($skipped.Count) skipped"
    Complete-PhaseRun -Run $run -Status 'failed' -Message $msg `
        -RecommendedAction "stop the kopia.exe process holding the destination, then re-run make deploy-artifacts"
    Write-PhaseLog "[deploy-artifacts] $msg" -Level err
    exit 1
} else {
    $msg = "$($copied.Count) copied; $($skipped.Count) skipped"
    Complete-PhaseRun -Run $run -Status 'ok' -Message $msg
    Write-PhaseLog "[deploy-artifacts] $msg" -Level ok
    exit 0
}
```

- [ ] **Step 3: Add `deploy-artifacts` target to Makefile**

Append to `C:\dev\kopia\Makefile.local.mk`:

```make
.PHONY: deploy-artifacts

# Phase 3 — copy signed kopia.exe from build location to runtime locations.
deploy-artifacts:
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(CURDIR)/cicd/deploy-artifacts.ps1"
```

Also add `deploy-artifacts` to the `.PHONY:` line at the top.

- [ ] **Step 4: First-run validation**

```bash
cd /c/dev/kopia && make deploy-artifacts
```

Expected: source kopia.exe identified, two destinations probed, copies happen (or skipped if already current). Exit 0.

- [ ] **Step 5: Idempotency check**

Immediately re-run:

```bash
make deploy-artifacts
```

Expected: every destination reported as `[ok] ... already current (hash + sig match)`, total runtime <2 seconds.

- [ ] **Step 6: Failure-injection — running process locks dest**

In a separate terminal, start a kopia process pointing at one of the destinations (or simply leave KopiaUI running). Then re-run `make deploy-artifacts`. Expected: the locked destination reports `[FAIL] ... locked by PID N` with the recommendedAction. Other destinations succeed. Phase exits 1.

- [ ] **Step 7: Commit**

```bash
git add cicd/deploy-artifacts.ps1 Makefile.local.mk
git commit -m "cicd: phase 3 — deploy-artifacts.ps1

Copies signed kopia.exe from ~/go/bin/ to D:\KopiaServer\bin\ and the
KopiaUI bundle path. Idempotent (hash compare); refuses to overwrite
if a running kopia.exe holds the destination.

Per plan Task 4."
```

---

## Task 5: Phase 4 — `deploy-tasks.ps1` + seed `scripts/scheduled-tasks/`

**Files:**
- Create: `scripts/scheduled-tasks/*.xml` (seeded from current registrations)
- Create: `cicd/deploy-tasks.ps1`
- Modify: `Makefile.local.mk` (add `deploy-tasks` target)

- [ ] **Step 1: Enumerate currently-registered backup tasks**

Run:

```powershell
schtasks /query /fo csv /tn '\Backup\' 2>$null | Select-Object -Skip 1 |
  ForEach-Object { ($_ -split ',')[0].Trim('"') } | Sort-Object -Unique
```

Expected: list of `\Backup\<name>` task paths. Note them — likely includes `\Backup\DailyKopiaSnapshotV2`, `\Backup\KopiaHeartbeatWatchdog`, `\Backup\KopiaStallGuardWatchdog`, plus any others.

- [ ] **Step 2: Export each task to `scripts/scheduled-tasks/`**

```bash
mkdir -p /c/dev/kopia/scripts/scheduled-tasks
```

For each task name from Step 1 (using PowerShell — schtasks /xml has encoding quirks):

```powershell
$tasks = @('\Backup\DailyKopiaSnapshotV2', '\Backup\KopiaHeartbeatWatchdog', '\Backup\KopiaStallGuardWatchdog')
# (replace with actual list from Step 1)
foreach ($t in $tasks) {
    $name = ($t -split '\\')[-1]
    $xml = schtasks /query /xml /tn $t
    if ($LASTEXITCODE -eq 0) {
        # schtasks emits UTF-16 with BOM; normalize to UTF-8
        $xml -join "`n" | Set-Content -Path "C:\dev\kopia\scripts\scheduled-tasks\$name.xml" -Encoding UTF8
        Write-Host "exported $t → $name.xml"
    }
}
```

- [ ] **Step 3: Verify the exports parse and contain expected fields**

```powershell
Get-ChildItem C:\dev\kopia\scripts\scheduled-tasks\*.xml | ForEach-Object {
    $x = [xml](Get-Content $_.FullName)
    "$($_.Name): triggers=$($x.Task.Triggers.InnerXml.Length>0); actions=$($x.Task.Actions.Exec.Command)"
}
```

Expected: each XML has triggers and an `Exec.Command`. If not, fix the export before continuing.

- [ ] **Step 4: Write `cicd/deploy-tasks.ps1`**

Create `C:\dev\kopia\cicd\deploy-tasks.ps1`:

```powershell
# deploy-tasks.ps1 — Phase 4 of the cicd pipeline.
# Reconciles registered Task Scheduler tasks under \Backup\ against the
# desired-state XMLs in scripts/scheduled-tasks/.
#
# For each .xml in scripts/scheduled-tasks/:
#   - If task not registered: schtasks /create
#   - If registered but XML differs: schtasks /delete + /create
#   - If currently running: skip (don't disrupt active backups)
# Idempotent: a no-drift run is fast and silent.

[CmdletBinding()]
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\pipeline-state.ps1"

$run = Start-PhaseRun -Phase 'deploy-tasks'
Write-PhaseLog "[deploy-tasks] Phase 4 — reconciling Task Scheduler entries" -Level info

$desiredDir = 'C:\dev\kopia\scripts\scheduled-tasks'
if (-not (Test-Path $desiredDir)) {
    Complete-PhaseRun -Run $run -Status 'failed' -Message "missing $desiredDir" `
        -RecommendedAction "see plan Task 5 step 2 — seed scripts/scheduled-tasks/ from current registrations"
    Write-PhaseLog "  [FAIL] $desiredDir not present" -Level err
    exit 1
}

$created  = @()
$updated  = @()
$current  = @()
$skipped  = @()
$errors   = @()

# Normalize XML for comparison (strip whitespace + dynamic Date fields)
function Normalize-Xml([string]$xmlText) {
    $doc = [xml]$xmlText
    # Remove RegistrationInfo/Date which schtasks updates on every change
    $regInfo = $doc.SelectSingleNode("//*[local-name()='RegistrationInfo']/*[local-name()='Date']")
    if ($regInfo) { $regInfo.ParentNode.RemoveChild($regInfo) | Out-Null }
    $sw = New-Object IO.StringWriter
    $w  = New-Object Xml.XmlTextWriter($sw)
    $w.Formatting = 'None'
    $doc.WriteTo($w)
    return $sw.ToString()
}

foreach ($file in Get-ChildItem $desiredDir -Filter '*.xml') {
    $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $taskPath = "\Backup\$name"
    $desired = Get-Content $file.FullName -Raw

    # Is it currently running?
    try {
        $info = schtasks /query /tn $taskPath /v /fo csv 2>$null | Select-Object -Skip 1
        if ($info) {
            $statusField = ($info -split ',')[3] -replace '"', ''
            if ($statusField -match 'Running') {
                Write-PhaseLog "  [skip] $taskPath — currently Running, will reconcile next time" -Level warn
                $skipped += "$taskPath (running)"
                continue
            }
        }
    } catch { }

    # Compare to current registration
    $registered = $null
    schtasks /query /xml /tn $taskPath 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $registered = (schtasks /query /xml /tn $taskPath) -join "`n"
    }

    if ($registered -and (Normalize-Xml $registered) -eq (Normalize-Xml $desired)) {
        Write-PhaseLog "  [ok] $taskPath current" -Level ok
        $current += $taskPath
        continue
    }

    if ($VerifyOnly) {
        Write-PhaseLog "  [would-update] $taskPath" -Level info
        continue
    }

    try {
        if ($registered) {
            schtasks /delete /tn $taskPath /f 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "schtasks /delete returned $LASTEXITCODE" }
        }
        schtasks /create /tn $taskPath /xml $file.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "schtasks /create returned $LASTEXITCODE" }
        if ($registered) {
            $updated += $taskPath; Write-PhaseLog "  [ok] updated $taskPath" -Level ok
        } else {
            $created += $taskPath; Write-PhaseLog "  [ok] created $taskPath" -Level ok
        }
    } catch {
        $errors += "$taskPath: $($_.Exception.Message)"
        Write-PhaseLog "  [FAIL] $taskPath: $($_.Exception.Message)" -Level err
    }
}

if ($errors) {
    $msg = "$($errors.Count) error(s); $($created.Count) created; $($updated.Count) updated; $($current.Count) current; $($skipped.Count) skipped"
    Complete-PhaseRun -Run $run -Status 'failed' -Message $msg
    Write-PhaseLog "[deploy-tasks] $msg" -Level err
    exit 1
} else {
    $msg = "$($created.Count) created; $($updated.Count) updated; $($current.Count) current; $($skipped.Count) skipped"
    Complete-PhaseRun -Run $run -Status 'ok' -Message $msg
    Write-PhaseLog "[deploy-tasks] $msg" -Level ok
    exit 0
}
```

- [ ] **Step 5: Add `deploy-tasks` target to Makefile**

Append to `C:\dev\kopia\Makefile.local.mk`:

```make
.PHONY: deploy-tasks

# Phase 4 — reconcile scheduled tasks under \Backup\ from scripts/scheduled-tasks/*.xml
deploy-tasks:
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(CURDIR)/cicd/deploy-tasks.ps1"
```

Add `deploy-tasks` to `.PHONY:` line.

- [ ] **Step 6: First-run validation (must be a no-op)**

Since you exported the XMLs FROM the current registrations in Step 2, deploy-tasks should detect zero drift:

```bash
cd /c/dev/kopia && make deploy-tasks
```

Expected: every task reported as `[ok] ... current`. Total runtime <5 seconds. If any task shows as drift on first run, the export-then-reconcile loop has a normalization bug — investigate before proceeding.

- [ ] **Step 7: Drift-detection test**

Edit one task XML (e.g., bump a description field by one character) and run again:

```bash
make deploy-tasks
```

Expected: that task is `[ok] updated`; others `[ok] current`. Then revert the XML change and re-run; expected: all `current` again.

- [ ] **Step 8: Commit**

```bash
git add scripts/scheduled-tasks/ cicd/deploy-tasks.ps1 Makefile.local.mk
git commit -m "cicd: phase 4 — deploy-tasks + seed scripts/scheduled-tasks/

Exports the currently-registered \Backup\* tasks as desired-state XMLs.
deploy-tasks.ps1 reconciles registered tasks against these XMLs;
running tasks are skipped to avoid disrupting an active backup.

Per plan Task 5."
```

---

## Task 6: Phase 5 — `deploy-config.ps1`

**Files:**
- Create: `cicd/deploy-config.ps1`
- Modify: `Makefile.local.mk` (add `deploy-config` target)

- [ ] **Step 1: Write `cicd/deploy-config.ps1`**

Create `C:\dev\kopia\cicd\deploy-config.ps1`:

```powershell
# deploy-config.ps1 — Phase 5 of the cicd pipeline.
# CONSERVATIVE: validate-only. Never overwrites secrets or production config.
# Confirms each known config artifact is well-formed and protected.

[CmdletBinding()]
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\pipeline-state.ps1"

$run = Start-PhaseRun -Phase 'deploy-config'
Write-PhaseLog "[deploy-config] Phase 5 — validating config files (read-only)" -Level info

$failures = @()
$warnings = @()

# 1. signing/metadata.json — must parse + contain required fields
try {
    $meta = Get-Content 'C:\dev\kopia\signing\metadata.json' -Raw | ConvertFrom-Json
    foreach ($f in 'Endpoint','CodeSigningAccountName','CertificateProfileName') {
        if (-not $meta.$f) { throw "missing field: $f" }
    }
    Write-PhaseLog "  [ok] signing/metadata.json valid" -Level ok
} catch {
    $failures += "signing/metadata.json: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] signing/metadata.json: $($_.Exception.Message)" -Level err
}

# 2. D:\KopiaServer\repository.config — JSON parse only (server-mode config)
$serverCfg = 'D:\KopiaServer\repository.config'
if (Test-Path $serverCfg) {
    try {
        $cfg = Get-Content $serverCfg -Raw | ConvertFrom-Json
        Write-PhaseLog "  [ok] D:\KopiaServer\repository.config parses" -Level ok
    } catch {
        $failures += "D:\KopiaServer\repository.config: $($_.Exception.Message)"
        Write-PhaseLog "  [FAIL] $serverCfg" -Level err
    }
} else {
    $warnings += "D:\KopiaServer\repository.config absent (server mode may not be configured on this host)"
    Write-PhaseLog "  [warn] $serverCfg not present (informational)" -Level warn
}

# 3. scripts/.kopia-pw.dat — exists + ACL is owner-only (NEVER read content)
$pwVault = 'C:\dev\kopia\scripts\.kopia-pw.dat'
if (Test-Path $pwVault) {
    $acl = Get-Acl $pwVault
    $perms = $acl.Access | Where-Object { -not $_.IsInherited } |
        Where-Object { $_.IdentityReference -notmatch 'SYSTEM|Administrators|' + [Environment]::UserName }
    if ($perms) {
        $failures += "scripts/.kopia-pw.dat ACL has unexpected entries: $($perms.IdentityReference -join ', ')"
        Write-PhaseLog "  [FAIL] .kopia-pw.dat ACL too permissive" -Level err
    } else {
        Write-PhaseLog "  [ok] scripts/.kopia-pw.dat ACL owner-only" -Level ok
    }
} else {
    $warnings += "scripts/.kopia-pw.dat absent (recreate via SECRETS.md procedure)"
    Write-PhaseLog "  [warn] .kopia-pw.dat not present (informational)" -Level warn
}

# Verdict
if ($failures) {
    $msg = "$($failures.Count) failure(s); $($warnings.Count) warning(s)"
    Complete-PhaseRun -Run $run -Status 'failed' -Message $msg
    Write-PhaseLog "[deploy-config] $msg" -Level err
    foreach ($f in $failures) { Write-PhaseLog "  - $f" -Level err }
    exit 1
} else {
    $msg = if ($warnings) { "OK with $($warnings.Count) warning(s)" } else { "all configs valid" }
    Complete-PhaseRun -Run $run -Status 'ok' -Message $msg
    Write-PhaseLog "[deploy-config] $msg" -Level ok
    foreach ($w in $warnings) { Write-PhaseLog "  - $w" -Level warn }
    exit 0
}
```

- [ ] **Step 2: Add `deploy-config` target to Makefile**

Append to `C:\dev\kopia\Makefile.local.mk`:

```make
.PHONY: deploy-config

# Phase 5 — read-only config validation (NEVER overwrites secrets/config).
deploy-config:
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(CURDIR)/cicd/deploy-config.ps1"
```

Add `deploy-config` to `.PHONY:` line.

- [ ] **Step 3: Run validation**

```bash
cd /c/dev/kopia && make deploy-config
```

Expected: each of three checks reports `[ok]` or `[warn]` for absent files. Exit 0.

- [ ] **Step 4: Commit**

```bash
git add cicd/deploy-config.ps1 Makefile.local.mk
git commit -m "cicd: phase 5 — deploy-config (validate-only)

Confirms signing/metadata.json, D:\KopiaServer\repository.config, and
scripts/.kopia-pw.dat ACL are well-formed and protected. NEVER reads
secret content or overwrites production config.

Per plan Task 6."
```

---

## Task 7: Phase 6 — `smoke-test.ps1`

**Files:**
- Create: `cicd/smoke-test.ps1`
- Modify: `Makefile.local.mk` (add `smoke-test` target)

- [ ] **Step 1: Write `cicd/smoke-test.ps1`**

Create `C:\dev\kopia\cicd\smoke-test.ps1`:

```powershell
# smoke-test.ps1 — Phase 6 of the cicd pipeline.
# Light dynamic check that the deployed system actually works.
#   - Refuses to run if any kopia.exe is already running (would conflict)
#   - Briefly starts kopia server, GETs /api/v1/repo/status, shuts down
#   - Runs verify_helpers_preflight.ps1 against freshly-signed helpers
#   - Queries Task Scheduler for "next run time" of \Backup\ tasks

[CmdletBinding()]
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\pipeline-state.ps1"

$run = Start-PhaseRun -Phase 'smoke-test'
Write-PhaseLog "[smoke-test] Phase 6 — light dynamic validation" -Level info

# Guard: refuse if kopia already running
$running = Get-Process -Name 'kopia' -ErrorAction SilentlyContinue
if ($running) {
    $pids = ($running.Id -join ', ')
    Complete-PhaseRun -Run $run -Status 'failed' -Message "kopia.exe already running (PID $pids)" `
        -RecommendedAction "stop the existing kopia process(es), then re-run make smoke-test"
    Write-PhaseLog "  [FAIL] kopia already running (PID $pids)" -Level err
    exit 1
}

$failures = @()

# Check A — kopia server starts + repo status responds
$serverProc = $null
try {
    $kopiaExe = "$env:USERPROFILE\go\bin\kopia.exe"
    if (-not (Test-Path $kopiaExe)) { throw "kopia.exe missing at $kopiaExe" }

    # Start a transient server on a unique port to avoid colliding with a real one
    $port = 51515
    $serverProc = Start-Process -FilePath $kopiaExe `
        -ArgumentList @('server', 'start', "--address=127.0.0.1:$port", '--insecure', '--no-ui') `
        -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 4

    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/v1/repo/status" `
        -TimeoutSec 5 -UseBasicParsing -SkipHttpErrorCheck
    if ($resp.StatusCode -eq 200) {
        Write-PhaseLog "  [ok] kopia server: /api/v1/repo/status → 200" -Level ok
    } else {
        $failures += "kopia server: /api/v1/repo/status → HTTP $($resp.StatusCode)"
        Write-PhaseLog "  [FAIL] /api/v1/repo/status → HTTP $($resp.StatusCode)" -Level err
    }
} catch {
    $failures += "kopia server probe: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] kopia server: $($_.Exception.Message)" -Level err
} finally {
    if ($serverProc -and -not $serverProc.HasExited) {
        Stop-Process -Id $serverProc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}

# Check B — verify_helpers_preflight.ps1 against freshly-signed helpers
try {
    & 'C:\dev\kopia\scripts\verify_helpers_preflight.ps1'
    if ($LASTEXITCODE -ne 0) {
        $failures += "verify_helpers_preflight.ps1 exit $LASTEXITCODE"
        Write-PhaseLog "  [FAIL] verify_helpers_preflight returned $LASTEXITCODE" -Level err
    } else {
        Write-PhaseLog "  [ok] verify_helpers_preflight passed" -Level ok
    }
} catch {
    $failures += "verify_helpers_preflight: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] verify_helpers_preflight: $($_.Exception.Message)" -Level err
}

# Check C — every \Backup\ task has a future Next Run Time
try {
    $tasks = schtasks /query /fo csv /tn '\Backup\' 2>$null | ConvertFrom-Csv
    foreach ($t in $tasks) {
        if (-not $t.'TaskName' -or $t.'TaskName' -eq 'TaskName') { continue }
        if ($t.'Next Run Time' -eq 'N/A' -or $t.'Status' -eq 'Disabled') {
            $failures += "$($t.'TaskName') Status=$($t.'Status') NextRun=$($t.'Next Run Time')"
            Write-PhaseLog "  [FAIL] $($t.'TaskName'): $($t.'Status'), next run $($t.'Next Run Time')" -Level err
        } else {
            Write-PhaseLog "  [ok] $($t.'TaskName'): next $($t.'Next Run Time')" -Level ok
        }
    }
} catch {
    $failures += "task scheduler query: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] task query: $($_.Exception.Message)" -Level err
}

# Verdict
if ($failures) {
    $msg = "$($failures.Count) failure(s)"
    Complete-PhaseRun -Run $run -Status 'failed' -Message $msg
    Write-PhaseLog "[smoke-test] $msg" -Level err
    exit 1
} else {
    Complete-PhaseRun -Run $run -Status 'ok' -Message "server 200, helpers Valid, all tasks scheduled"
    Set-RunVerdict -Verdict 'success'
    Write-PhaseLog "[smoke-test] all checks passed" -Level ok
    exit 0
}
```

- [ ] **Step 2: Add `smoke-test` target to Makefile**

Append to `C:\dev\kopia\Makefile.local.mk`:

```make
.PHONY: smoke-test

# Phase 6 — light dynamic validation (start server briefly, probe, stop)
smoke-test:
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(CURDIR)/cicd/smoke-test.ps1"
```

Add `smoke-test` to `.PHONY:` line.

- [ ] **Step 3: Verify no kopia.exe is running**

```bash
powershell -c "Get-Process kopia -ErrorAction SilentlyContinue | Format-Table Id, Name"
```

If anything appears, stop it (close KopiaUI, stop the server task) before continuing.

- [ ] **Step 4: Run smoke-test**

```bash
cd /c/dev/kopia && make smoke-test
```

Expected: Check A starts a transient server (~4s warm-up), gets 200; Check B runs the helper verifier; Check C lists task next-run times. Exit 0. Total ~30-60 seconds.

- [ ] **Step 5: Failure-injection — leave kopia running**

Start KopiaUI (or `kopia server start`) on the default port so a kopia.exe is up. Run `make smoke-test`. Expected: phase exits 1 with `[FAIL] kopia already running (PID N)` and recommendedAction.

- [ ] **Step 6: Commit**

```bash
git add cicd/smoke-test.ps1 Makefile.local.mk
git commit -m "cicd: phase 6 — smoke-test

Light dynamic validation: starts kopia server transiently, GETs
/api/v1/repo/status, runs verify_helpers_preflight, confirms each
\Backup\ task is enabled with a future next-run-time. Refuses to run
if kopia.exe is already up.

Per plan Task 7."
```

---

## Task 8: Wire `release-and-deploy` + `bootstrap` + `verify-deployment` + `test-pipeline`

**Files:**
- Modify: `Makefile.local.mk` (add four orchestration targets)

- [ ] **Step 1: Add the four orchestration targets**

Append to `C:\dev\kopia\Makefile.local.mk`:

```make
.PHONY: release-and-deploy bootstrap verify-deployment test-pipeline

# Full chain — Phase 1 → 6. Fail-fast via Make's natural dep behavior.
release-and-deploy: diagnose release deploy-artifacts deploy-tasks deploy-config smoke-test
	@echo ""
	@echo "✓ release-and-deploy complete — see cicd/.last-deploy"

# Fresh-machine bootstrap — restore dlib, prompt for az login if needed,
# then run the full chain.
bootstrap:
	@echo "→ bootstrap"
	@cd "$(CURDIR)/signing/dlib" && dotnet restore
	@powershell.exe -NoProfile -Command "if (-not (& 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' account show 2>`$null)) { Write-Host 'az login required'; & 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' login }"
	@$(MAKE) -f $(MAKEFILE_LIST) release-and-deploy

# Idempotent re-verify — runs every phase in -VerifyOnly mode (no writes).
# Useful as a "is everything still where it should be?" pre-flight.
verify-deployment:
	@echo "→ verify-deployment (read-only)"
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(CURDIR)/cicd/diagnose-signing.ps1"
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(CURDIR)/cicd/deploy-artifacts.ps1" -VerifyOnly
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(CURDIR)/cicd/deploy-tasks.ps1" -VerifyOnly
	@powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(CURDIR)/cicd/deploy-config.ps1"
	@echo "✓ verify-deployment complete"

# Test-pipeline — same as verify-deployment but ensures every phase is reachable.
test-pipeline: verify-deployment
	@echo "✓ all phases reachable; cicd/.last-deploy reflects last run"
```

Update the top `.PHONY:` line to include all of these.

- [ ] **Step 2: First end-to-end run**

Stop any running kopia processes (KopiaUI, server tasks) so smoke-test can start its transient server. Then:

```bash
cd /c/dev/kopia
make release-and-deploy 2>&1 | tee /tmp/full-run.log
```

Expected: each phase logs in order, every phase reports `[ok]`, total runtime ~80-110 seconds, exit 0. Verify:

```bash
cat cicd/.last-deploy | python -m json.tool
```

All six phases should show `status: "ok"` and `verdict: "success"`.

- [ ] **Step 3: Idempotency check**

Immediately re-run:

```bash
make release-and-deploy
```

Expected: every phase reports its no-op message (e.g., `[ok] release: no work needed since stamp`, `deploy-artifacts: 2 skipped (already current)`, `deploy-tasks: N current`). Total runtime <30s (release phase still rebuilds Go in ~10s; everything else is fast).

- [ ] **Step 4: verify-deployment without writes**

```bash
make verify-deployment
```

Expected: same checks as Phase 1 + each deploy phase in `-VerifyOnly`. No writes; runtime <15s.

- [ ] **Step 5: Commit**

```bash
git add Makefile.local.mk
git commit -m "cicd: orchestration targets — release-and-deploy, bootstrap, verify-deployment, test-pipeline

\`make release-and-deploy\` chains all six phases via Make deps; fail-fast
is automatic. \`make bootstrap\` is the fresh-machine entry point.
\`make verify-deployment\` is the idempotent dry-run.

Per plan Task 8."
```

---

## Task 9: `cicd/README.md` (final content)

**Files:**
- Modify: `cicd/README.md` (replace placeholder from Task 1)

- [ ] **Step 1: Replace placeholder with full reference**

Overwrite `C:\dev\kopia\cicd\README.md`:

```markdown
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
| 1 | `make diagnose`        | `cicd/diagnose-signing.ps1`         | ~10s | bad token, missing role, dlib drift, endpoint unreachable, BD MITM |
| 2 | `make release`         | (existing) `signing/sign-all.ps1`   | ~30s | sign failure, sig drift |
| 3 | `make deploy-artifacts`| `cicd/deploy-artifacts.ps1`         |  ~5s | source not signed, dest locked |
| 4 | `make deploy-tasks`    | `cicd/deploy-tasks.ps1`             |  ~5s | XML parse error, schtasks failure |
| 5 | `make deploy-config`   | `cicd/deploy-config.ps1`            |  ~2s | invalid JSON, .kopia-pw.dat ACL |
| 6 | `make smoke-test`      | `cicd/smoke-test.ps1`               | ~45s | server can't start, helper sig invalid, task disabled |

## State file

`cicd/.last-deploy` (gitignored) — JSON record of the last run:

```json
{
  "runId": "<ISO timestamp>",
  "trigger": "make release-and-deploy",
  "verdict": "success" | "failure" | "in_progress",
  "phases": {
    "diagnose":         { "status": "ok|failed|skipped", "durationMs": N, "message": "...", "recommendedAction": "..." (failures only) },
    ...
  }
}
```

## Manual test recipes (one per failure category)

| Failure category | How to inject | Expected behavior |
|------------------|---------------|-------------------|
| Signing infra drift | edit `signing/dlib/dlib.csproj` → `9.9.9` | Phase 1 emits `[WARN] dlib pin: 9.9.9 (latest 1.0.95)` |
| Identity / RBAC | `az logout` | Phase 1 fails Check 3 with token-acquisition error + suggests `az login` |
| Network / endpoint | block `eus.codesigning.azure.net` in firewall | Phase 1 Check 5 reports TCP failure |
| Artifact placement (locked) | `kopia server start` then `make deploy-artifacts` | Phase 3 reports `[FAIL] ... locked by PID N` |
| Runtime (server fails) | corrupt `D:\KopiaServer\repository.config` | Phase 6 Check A times out / non-200 |

## Bypass mechanisms

- `git push --no-verify` — skips the pre-push gate (existing).
- `SKIP_DIAGNOSE=1 make sign-all` — bypasses Phase 1 preflight (emergency only; loud warning).
- No bypass for individual deploy phases — fix the issue, re-run the failing phase alone.
```

- [ ] **Step 2: Commit**

```bash
git add cicd/README.md
git commit -m "cicd: full README with phase reference + manual test recipes

Per plan Task 9."
```

---

## Task 10: Update `signing/README.md` to reference `cicd/`

**Files:**
- Modify: `signing/README.md`

- [ ] **Step 1: Add cross-reference at top**

In `C:\dev\kopia\signing\README.md`, after the first paragraph (the "Daily backups..." line), insert:

```markdown
> **For the full local CI/CD pipeline** — six phases including diagnose, deploy-artifacts, deploy-tasks, deploy-config, and smoke-test — see [`../cicd/README.md`](../cicd/README.md). This README covers the signing layer specifically.
```

- [ ] **Step 2: Update the "Daily workflow" section**

Find the section that starts with `## Daily workflow` and replace its `make release` block with:

```bash
# Edit Go source or any signed .ps1
make release-and-deploy   # full chain — diagnose → release → deploy → smoke-test
git push                  # pre-push hook runs `make prepush-check`
```

- [ ] **Step 3: Commit**

```bash
git add signing/README.md
git commit -m "signing: cross-reference cicd/README.md from signing/README.md

Per plan Task 10."
```

---

## Task 11: Final acceptance — failure-injection sweep

**Files:** none modified — pure acceptance test

- [ ] **Step 1: Confirm a clean baseline**

```bash
cd /c/dev/kopia && make release-and-deploy 2>&1 | tail -5
cat cicd/.last-deploy | python -c "import sys, json; d=json.load(sys.stdin); print(d['verdict']); [print(p, d['phases'][p]['status']) for p in d['phases']]"
```

Expected: `verdict: success`, all phases `ok`.

- [ ] **Step 2: Inject Phase 1 failure (token)**

```bash
"C:/Program Files/Microsoft SDKs/Azure/CLI2/wbin/az.cmd" account clear
make diagnose 2>&1 | tail -5
```

Expected: Phase 1 fails Check 3 (token acquisition); exit 1; `cicd/.last-deploy` records the failure with `recommendedAction` mentioning `az login`.

Restore: `az login --tenant 5833e0ba-788b-4086-9b3a-66d7c5824ddb`.

- [ ] **Step 3: Inject Phase 3 failure (locked dest)**

```powershell
# In a separate window:
& 'C:\Users\david\go\bin\kopia.exe' server start --address=127.0.0.1:51515 --insecure --no-ui
```

In the main shell:

```bash
make deploy-artifacts 2>&1 | tail -5
```

Expected: phase 3 reports `[FAIL] ... locked by PID N` if the running kopia.exe is one of the deploy destinations. (If the destination doesn't match a running PID, this test exercises the "skip if path doesn't match" path instead — still informative.)

Stop the server.

- [ ] **Step 4: Inject Phase 4 failure (XML drift)**

Edit one of `scripts/scheduled-tasks/*.xml` and bump the `<URI>` field by appending `_TEST`. Run `make deploy-tasks`. Expected: that task reports `[ok] updated`. Revert the edit. Re-run; expected: `[ok] current`.

- [ ] **Step 5: Inject Phase 6 failure (kopia already running)**

Start `kopia server start` again. Run `make smoke-test`. Expected: phase 6 fails immediately with `[FAIL] kopia already running (PID N)`.

Stop the server.

- [ ] **Step 6: Final clean run + sign-off**

```bash
make release-and-deploy
```

Expected: green end-to-end. Capture `cicd/.last-deploy` for the record:

```bash
cat cicd/.last-deploy
```

- [ ] **Step 7: Close any related beads + push**

```bash
unset GITHUB_TOKEN
git push fork master
bd memories add --kind reference 'cicd-pipeline-shipped' "Six-phase local CI/CD pipeline (diagnose, release, deploy-artifacts, deploy-tasks, deploy-config, smoke-test) at C:\dev\kopia\cicd\. Run via 'make release-and-deploy'. Design at docs/superpowers/specs/2026-05-05-cicd-pipeline-design.md. README at cicd/README.md."
```

(If the `bd memories add` syntax differs in your beads version, persist the equivalent insight via `bd remember` or whatever the correct syntax is.)

---

## Self-Review Checklist

After all tasks complete, confirm against the spec (`docs/superpowers/specs/2026-05-05-cicd-pipeline-design.md`):

| Spec section | Implemented in |
|---|---|
| Architecture: 6 phases | Tasks 2-7 |
| Components: `cicd/` directory + `lib/pipeline-state.ps1` | Task 1 |
| Components: `scripts/scheduled-tasks/*.xml` | Task 5 |
| Components: Modified Makefile / sign-all / .gitignore | Tasks 1, 2, 3, 8 |
| Phase script contract: exit codes 0/1/2 | Each phase script (Tasks 2, 4-7) |
| State file shape | Task 1 + populated by Tasks 2, 4, 5, 6, 7 |
| Failure taxonomy | Validated by Task 11 failure-injection sweep |
| Bypass: SKIP_DIAGNOSE=1 | Task 2 step 3 |
| Bypass: --no-verify on push | Existing — unchanged |
| Testing: `make test-pipeline` | Task 8 |
| Testing: idempotency check | Task 8 step 3 |
| Testing: failure-injection | Task 11 |
| Open question 1 (toast integration) | Out of scope; flagged for follow-up bead during implementation |
| Open question 2 (XML seed procedure) | Task 5 step 2 |
| Open question 3 (dlib threshold N=0) | Task 2 step 1 — warns on any newer NuGet version |
| Open question 4 (server lifecycle conflict) | Task 7 step 1 — refuse-to-run guard |
