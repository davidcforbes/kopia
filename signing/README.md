# Azure Trusted Signing — Local Pipeline

Signs `kopia.exe` and the local backup helper `.ps1` scripts under [`../scripts/`](../scripts/) using Azure Trusted Signing via the [DLIB](https://learn.microsoft.com/azure/trusted-signing/) integration with `signtool`.

Daily backups (`\Backup\DailyKopiaSnapshotV2`) verify these signatures at preflight; nothing runs unsigned.

## Files

| File                       | Tracked? | Purpose                                                                |
|----------------------------|:--------:|------------------------------------------------------------------------|
| `metadata.json`            | ✅       | Endpoint + account + certificate profile name (no secrets)             |
| `metadata.json.example`    | ✅       | Template                                                               |
| `profile-body.json`        | ✅       | Body for the ARM PUT that creates a certificate profile                |
| `dlib/dlib.csproj`         | ✅       | NuGet manifest pulling `Microsoft.Trusted.Signing.Client` + `Microsoft.Windows.SDK.BuildTools` |
| `dlib/{obj,bin}/`          | ❌       | NuGet restore artifacts                                                |
| `sign-all.ps1`             | ✅       | Locates signtool + DLIB in NuGet cache, signs every target, verifies   |
| `prepush-check.ps1`        | ✅       | Gate logic invoked by `.git/hooks/pre-push` and `make prepush-check`   |
| `.last-sign`               | ❌       | Stamp file written after successful `make release`                     |

## Trust profile

| Field                | Value                                                          |
|----------------------|----------------------------------------------------------------|
| Account              | `famcodesign` (resource group `codesign`, sub `0dee2894-...`)  |
| Certificate profile  | `activity-journal` (shared with `C:\dev\activity-journal`)     |
| Endpoint             | `https://eus.codesigning.azure.net`                            |
| Identity validation  | `0afb64d8-7d3f-469a-a413-b62dc8538932`                         |
| Signed Subject CN    | `Forbes Asset Management, Inc.`                                |
| Issuer               | `Microsoft ID Verified CS EOC CA 04`                           |

> **Note:** A dedicated `kopia` profile under the same account is not yet provisioned — see beads `kopia-bsv`. Sharing the `activity-journal` profile yields signatures with the same publisher CN, so trust is identical.

## Daily workflow

```bash
# Edit Go source or any signed .ps1
make release          # = install-noui + sign-all + verify-signatures + stamp .last-sign
git push              # pre-push hook runs `make prepush-check`
```

For a `.ps1`-only edit (no Go rebuild needed):

```bash
make sign-all
```

For a Bitdefender re-quarantine recovery (file restore + resign):

```bash
make sign-restore
```

## Pre-push gate

`.git/hooks/pre-push` runs `make prepush-check`, which (via `prepush-check.ps1`):

1. Confirms `signing/.last-sign` exists.
2. Walks tracked `.go` files; fails if any `mtime > stamp mtime`.
3. Re-runs `sign-all.ps1 -VerifyOnly` to confirm every signed target still has `Status=Valid`.

Bypass: `git push --no-verify`.

## Daily backup gate

[`../scripts/daily_kopia_backup.cmd`](../scripts/daily_kopia_backup.cmd) calls [`../scripts/verify_helpers_preflight.ps1`](../scripts/verify_helpers_preflight.ps1) at preflight (after a small bootstrap that confirms the verifier itself has `Status=Valid`). The verifier asserts, for `kopia.exe` + every signed `.ps1`:

1. Authenticode `Status=Valid`
2. `SignerCertificate.Subject -like '*Forbes Asset Management*'`
3. `TimeStamperCertificate` present (RFC3161 anchor — sig survives signer-cert expiry)
4. Signing timestamp ≤ 30 days old (catches sign pipeline drift)

Any failure aborts the backup with a `FATAL:` log line.

## Bootstrap on a fresh machine

```bash
cd C:\dev\kopia\signing\dlib
dotnet restore
cd ..
# az login (must use IPv4 if on Comcast — see beads kopia-2vk)
# Confirm the account/profile in metadata.json matches your Trusted Signing setup
make -f ../Makefile.local.mk release
```
