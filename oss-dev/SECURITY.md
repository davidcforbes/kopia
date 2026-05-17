# Security policy

Vulnerability disclosure process for the Backup Server project. This
is a pre-release (`oss-dev`) document — the reporting address and GPG
key are **placeholders** until the project's public name and
infrastructure are finalized.

---

## Reporting a vulnerability

Report security issues **privately** — do not open a public issue or
pull request for a suspected vulnerability.

- **Email**: `security@PROJECT-NAME.example` *(placeholder — finalize
  before public release)*
- **GPG**: encrypt sensitive reports to key fingerprint
  `0000 0000 0000 0000 0000 0000 0000 0000 0000 0000` *(placeholder —
  a real key will be published with the first public release)*

Include: affected component and version/commit, a description of the
issue, and reproduction steps or a proof of concept where possible.

## Triage timeline

| Stage | Target |
|---|---|
| Acknowledge receipt | within **24 hours** |
| Initial assessment + severity | within **7 days** |
| Fix released, or coordinated-disclosure date agreed | within **30 days** |

If a fix will take longer than 30 days, we will say so in the
initial assessment and agree a disclosure date with the reporter.
Credit is given to reporters who follow this process, unless they ask
to remain anonymous.

## Scope

**In scope** — report these:

- `backup-server` — the control-plane orchestrator: REST API, DAG
  runner, worker subprocess supervision, config parsing, state store.
- `backup-server-tray`, and the `--server-url` REST client modes of
  `backup-dump` / `backup-monitor`.
- The future native Rust workers (`kopia-file`, `kopia-block`) once
  they ship.
- The repository format and any encryption/secret-handling code in
  this project (including DPAPI env resolution).

**Out of scope** — these belong to their upstreams, not this project:

- The behavior of third-party `kopia.exe` (report to the kopia
  project) or Windows `wbadmin` (report to Microsoft).
- The PowerShell wrapper scripts' interaction with those third-party
  tools, except where this project's code invokes them.
- Vulnerabilities requiring an attacker who already has Administrator
  or physical access to the host — the loopback-only API and DPAPI
  LocalMachine scoping assume a trusted local machine.
- Denial of service against the loopback REST API from a local
  process (the API is loopback-only by design; a hostile local
  process is already outside the trust boundary).

## Security model summary

- The REST API binds **loopback only** and rejects routable
  addresses at startup. There is no network-facing attack surface in
  the current design.
- Job secrets are DPAPI-encrypted (`@dpapi:` references) and
  decrypted only in-process at worker-spawn time; plaintext never
  touches disk, logs, or the event stream.
- Binaries are Authenticode-signed; the nightly preflight refuses to
  run an unsigned binary.

See [`SETUP.md`](SETUP.md) §6 and [`../SECRETS.md`](../SECRETS.md) for
the operational details behind these guarantees.
