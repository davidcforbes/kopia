# get_parent_pid.ps1 — print our caller's PID. The wrapper invokes this from
# cmd via `for /f` to capture its own (cmd batch) PID so the heartbeat
# watchdog can identify the wrapper's kopia.exe children by ParentProcessId.
#
# Why a script and not an inline `-Command` snippet? The original wrapper
# used a nested-quoted PS one-liner inside `for /f ('...')`. That worked from
# interactive cmd but produced empty output under S4U-elevated scheduled-task
# context (kopia-i1p). The cmd-side quote-escape interactions are fragile and
# differ subtly between session types. Calling a signed -File script removes
# all the cmd-side quoting from the equation.
#
# Output: a single integer PID on stdout, nothing else. Empty stdout (no
# integer) signals failure to the caller's `if not defined`.

[CmdletBinding()] param()

$ErrorActionPreference = 'SilentlyContinue'

# Get-WmiObject is the legacy WMI API. It works under S4U-elevated contexts
# on this host where Get-CimInstance has been seen to fail with
# "type initializer for ApplicationMethods threw an exception".
$me = Get-WmiObject Win32_Process -Filter "ProcessId=$PID"
if ($me -and $me.ParentProcessId) {
    Write-Output $me.ParentProcessId
}
