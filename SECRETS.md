# Secrets in this fork

This repo carries two secrets on disk, both DPAPI-LocalMachine-
encrypted blobs under `scripts/`:

- **`scripts/.kopia-pw.dat`** — kopia *repository* password (decrypts
  the blobs in `D:\KopiaRepo`). Read by `get_kopia_password.ps1`.
- **`scripts/.kopia-server-pw.dat`** — kopia *server* HTTP basic-auth
  password (authenticates the wrapper and KopiaUI as REST clients of
  the long-running upstream `kopia server` process). Read by
  `get_kopia_server_password.ps1`.

Both follow the same protection model and recreate procedure. Nothing
else under `scripts/` or elsewhere in the tree is sensitive.

## How protection works

Three orthogonal layers, in order of "first to fire":

1. **`scripts/.gitignore`** — the inner gate, committed and shared.
   Ignores `.kopia-pw.dat`, `.kopia-server-pw.dat`, and
   `BACKUP_*.flag`. Anyone cloning this fork is protected by default.
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

## Recreating `.kopia-server-pw.dat` on a fresh machine

The kopia server password is generated locally (random hex, 256 bits
of entropy) — there's no human-memorable form to recover. Any client
of the upstream server reads this file via
`get_kopia_server_password.ps1`, so generation and consumption are
fully internal to this machine.

```powershell
Add-Type -AssemblyName System.Security
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$plain = -join ($bytes | ForEach-Object { '{0:x2}' -f $_ })
$plainBytes = [Text.Encoding]::UTF8.GetBytes($plain)
$enc = [Security.Cryptography.ProtectedData]::Protect(
    $plainBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
[IO.File]::WriteAllBytes('C:\dev\kopia\scripts\.kopia-server-pw.dat', $enc)
icacls C:\dev\kopia\scripts\.kopia-server-pw.dat `
    /inheritance:r /grant:r SYSTEM:F Administrators:F
```

After regenerating, **all clients must be reconfigured** (the
`\Backup\KopiaServer` task picks it up automatically on next start;
KopiaUI must be reconnected via "Connect to Repository Server" with
the new password).

The `\Backup\KopiaServer` launcher (`scripts/start_kopia_server.ps1`)
reads BOTH vault files: `.kopia-pw.dat` → `KOPIA_PASSWORD` (for
opening the repo on disk) and `.kopia-server-pw.dat` →
`KOPIA_SERVER_PASSWORD` (HTTP basic auth for clients). Going via env
vars rather than the OS keyring sidesteps Windows Credential Manager
unreliability under S4U / elevated split-token contexts.

## TLS cert+key for the upstream kopia server

The `\Backup\KopiaServer` task starts `kopia.exe server` with a stable
self-signed TLS cert so all clients (wrapper, KopiaUI) can pin a
fixed SHA-256 fingerprint across server restarts.

| Artifact | Path | Role |
|---|---|---|
| Cert PEM | `D:\KopiaServer\server.crt` | Pinned via `--server-cert-fingerprint=<sha>` |
| Key PEM  | `D:\KopiaServer\server.key` | Used by `kopia server start --tls-key-file=...` |
| Fingerprint | `D:\KopiaServer\fingerprint.sha256` | One-line hex; convenience copy for clients |
| Server-side config | `D:\KopiaServer\repository.config` | Filesystem-mode config kopia server uses to open `D:\KopiaRepo` directly. **Distinct** from the API-mode client config at `%APPDATA%\kopia\repository.config` — the latter would create a self-reference loop if the server tried to use it. Recreate with: copy from `%APPDATA%\kopia\repository.config.preserver-cutover.bak` (filesystem mode), then patch `caching.cacheDirectory` to an absolute path (e.g., `C:\Users\david\AppData\Local\kopia\7315bf3290de0739`) — the original relative path resolves wrong from `D:\KopiaServer\`. |

ACL on the directory and all three files: `SYSTEM:F`, `Administrators:F`, `david:R`.

### Regenerating the TLS pair

The cert is generated by kopia itself (matches the format and
extensions KopiaUI's bundled server has always produced — RSA-4096,
10-year validity, SAN `IP Address=127.0.0.1`, EKU Server Auth):

```powershell
# Stop the server task before regen so the new files aren't held open
Stop-ScheduledTask -TaskPath '\Backup\' -TaskName 'KopiaServer'
Remove-Item D:\KopiaServer\server.crt, D:\KopiaServer\server.key

# Run kopia server briefly so it generates and writes the cert+key
$pw = & C:\dev\kopia\scripts\get_kopia_server_password.ps1
$env:KOPIA_SERVER_PASSWORD = $pw
& C:\Users\david\go\bin\kopia.exe server start `
    --async-repo-connect --tls-generate-cert `
    --tls-cert-file=D:\KopiaServer\server.crt `
    --tls-key-file=D:\KopiaServer\server.key `
    --address=127.0.0.1:51515 --server-username=kopia `
    --config-file=$env:APPDATA\kopia\repository.config &
# Wait until the files appear, then kill the server. Re-apply ACL:
icacls D:\KopiaServer\server.crt /inheritance:r /grant:r SYSTEM:F Administrators:F david:R
icacls D:\KopiaServer\server.key /inheritance:r /grant:r SYSTEM:F Administrators:F david:R

# Recompute fingerprint and persist
$pem = Get-Content D:\KopiaServer\server.crt -Raw
$der = [Convert]::FromBase64String(($pem -replace '-----[^-]+-----','' -replace '\s',''))
$fp = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($der) | ForEach-Object { '{0:x2}' -f $_ })
$fp | Out-File D:\KopiaServer\fingerprint.sha256 -Encoding ASCII -NoNewline

Start-ScheduledTask -TaskPath '\Backup\' -TaskName 'KopiaServer'
```

**Regen rotates the fingerprint** — KopiaUI must be reconnected
("Connect to Repository Server" with the new fingerprint), and the
backup wrapper picks up the new fingerprint automatically because it
reads `D:\KopiaServer\fingerprint.sha256` at run time.

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
