# Claude instructions for the kopia fork

This repo participates in a multi-component Windows backup stack.
**Always read [`ARCHITECTURE.md`](ARCHITECTURE.md) before non-trivial
work.** It catalogs every binary, log surface, scheduled task, and
authoritative source you need to answer questions correctly or design
features without rebuilding what already exists.

The companion `AGENTS.md` covers beads issue-tracking conventions and
shell-hygiene rules; both apply.

## Two hard rules (each prevents a real failure that already happened)

### Rule 1 — Verification before "errors / clean / passed / failed" claims

Before answering any question about backup state, **run
`backup-dump.exe` first**:

```bash
/c/dev/backup-monitor/target/release/backup-dump.exe
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
being locked. `backup-dump.exe` already knew this.

This rule binds to the `superpowers:verification-before-completion`
skill — invoke it when in doubt.

### Rule 2 — Prior-art audit before designing tooling in this orbit

Before designing any new tool or script that touches backups, toasts,
log parsing, run scoring, health checks, or anything that smells
adjacent: read `ARCHITECTURE.md`, then **explicitly cite which existing
component covers each requirement**. Only propose new code for the
explicit gaps that remain.

Why this rule exists: 2026-04-29 session shipped ~170 lines of
`post_summary_toast.ps1` plus `check_wbadmin_health.ps1` plus a
"simplified" `check_backup_health.ps1`, while `backup-monitor.exe`
(three Rust binaries, a feature-rich dashboard, a `kopiamonitor:` URL
protocol) was sitting at `C:\dev\backup-monitor\` already doing nearly
all of it. The pointer was inside `register_backup_monitor_toast.ps1`
and was read but not followed.

This rule binds to the `superpowers:brainstorming` skill — invoke it
before any non-trivial design work.

## The v1 / v2 script hazard

`scripts/` is gitignored on master (`.git/info/exclude` line
`/scripts/`). On-disk evolution does not show in `git status` and can
quietly diverge from the `personal/automation` branch.

**Before deploying scripts from `personal/automation` to
`C:\dev\kopia\scripts\`**, check for drift:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File C:\dev\kopia\scripts\check_branch_drift.ps1
```

If the on-disk version is newer (it usually is), sync on-disk → branch
and commit before deploying. Do not let `cp -rv` overwrite v2 with v1
again.

## Standard workflow reminders (from AGENTS.md)

- Use `bd` for ALL task tracking — not `TodoWrite`/`TaskCreate`.
- Use `cp -f`, `mv -f`, `rm -f` to avoid interactive-prompt hangs.
- Work is not complete until tests pass, code is committed, and
  `git push` succeeds (where applicable for the branch).
