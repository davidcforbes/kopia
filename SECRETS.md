# Secrets in this fork

This repo carries one secret on disk: `scripts/.kopia-pw.dat`, a
DPAPI-LocalMachine-encrypted blob holding the kopia repository
password used by the nightly backup task. Nothing else under
`scripts/` or elsewhere in the tree is sensitive.

## How protection works

Three orthogonal layers, in order of "first to fire":

1. **`scripts/.gitignore`** — the inner gate, committed and shared.
   Ignores `.kopia-pw.dat` and `BACKUP_*.flag`. Anyone cloning this
   fork is protected by default.
2. **`.git/info/exclude`** — per-host defensive safety net. Carries
   broad secret patterns: `*.pw`, `*.pw.dat`, `*.pem`, `*.key`,
   `*.token`, `*-credentials.{json,yaml}`, `secrets.{json,yaml}`,
   `.env`, `.env.*`. Catches paths the inner gitignore would miss.
   Never committed; lives only in this clone's metadata.
3. **DPAPI LocalMachine encryption + restrictive ACLs** on the file
   itself. Even a leak (accidental commit, backup of `.git/`, etc.)
   would be useless: only this exact machine can decrypt the blob.

The branch separation that used to hide `scripts/` (the
`personal/automation` branch, retired 2026-04-29) was doing zero
secrets work — the protection has always come from these three
layers.

## Recreating `.kopia-pw.dat` on a fresh machine

```powershell
$pw = Read-Host -AsSecureString "Kopia repo password"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw)
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
$bytes = [Text.Encoding]::UTF8.GetBytes($plain)
$enc = [Security.Cryptography.ProtectedData]::Protect(
    $bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
[IO.File]::WriteAllBytes('C:\dev\kopia\scripts\.kopia-pw.dat', $enc)
```

Then lock it down:

```powershell
icacls C:\dev\kopia\scripts\.kopia-pw.dat `
    /inheritance:r `
    /grant:r SYSTEM:F Administrators:F
```

Verify the daily wrapper can read it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File C:\dev\kopia\scripts\get_kopia_password.ps1
```

That script uses `ProtectedData.Unprotect` with LocalMachine scope and
writes the plaintext to stdout. Anything other than the password text
on stdout means the file is unreadable from this user/machine context.

## What we deliberately don't do

- **Windows Credential Manager.** Same DPAPI underneath, but
  user-scoped credentials don't reliably reach S4U-logon scheduled
  tasks. The nightly task runs as `david` via S4U and needs
  LocalMachine-scope decryption.
- **Azure Key Vault / 1Password CLI.** Adds interactive auth or a
  network round-trip for what is one machine-bound password. Worth
  it for org-scale secrets, overkill for this.
- **Branch separation.** Provides no protection (file is gitignored
  on every branch). Costs visibility (drift between branch and disk
  goes unnoticed). Retired 2026-04-29.

## When to revisit

- A second machine joins this backup setup. Then DPAPI LocalMachine
  is no longer sufficient — switch to a portable secret manager.
- The fork ever needs to be sharable. Then sanitize the secret file
  out of `.git/` history and decide whether `scripts/` should be
  excluded by a tracked `.gitignore` line.
- A compliance audit requires audit logs of secret access. Then move
  to a secret manager that records reads.
