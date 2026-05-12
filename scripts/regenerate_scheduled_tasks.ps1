# regenerate_scheduled_tasks.ps1 -- rewrite scripts/scheduled-tasks/*.xml
# with the current host's SID + username + hostname + repo path.
#
# Use case: bootstrapping the kopia backup stack on a fresh Windows host.
# The committed XMLs are per-host snapshots (kopia-deq) -- they hardcode
# the original developer's SID, username, hostname, and repo path. On a
# different host, those values are wrong. This script rewrites them in
# place. Idempotent -- running it on the original host is a no-op.
#
# After running, commit the updated XMLs OR run 'make deploy-tasks' to
# register them under \Backup\.
#
# Usage (defaults to current process's user + standard repo path):
#   pwsh -NoProfile -ExecutionPolicy Bypass -File this-script.ps1
#
# Override repo path (e.g. if you cloned to D:\src\kopia):
#   pwsh ... this-script.ps1 -RepoPath 'D:\src\kopia'
#
# Override the user identity (rare -- only if running ON BEHALF OF another
# user; typically you want the defaults from the current process):
#   pwsh ... this-script.ps1 -NewSid 'S-1-5-21-...' -NewUsername 'alice' -NewHostname 'NEWHOST'

[CmdletBinding()]
param(
    [string]$RepoPath    = 'C:\dev\kopia',
    [string]$NewSid      = $null,
    [string]$NewUsername = $env:USERNAME,
    [string]$NewHostname = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'

$xmlDir = Join-Path $RepoPath 'scripts\scheduled-tasks'
if (-not (Test-Path $xmlDir)) { throw "scripts\scheduled-tasks not found at $xmlDir -- wrong -RepoPath?" }

# Default NewSid: current process's user SID
if (-not $NewSid) {
    $NewSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
}

Write-Host "[regenerate-tasks] target values:"
Write-Host "  SID:      $NewSid"
Write-Host "  Username: $NewUsername"
Write-Host "  Hostname: $NewHostname"
Write-Host "  RepoPath: $RepoPath"
Write-Host ""

# Detect old values from the first XML (single source of truth)
$xmls = Get-ChildItem $xmlDir -Filter '*.xml' | Sort-Object Name
if ($xmls.Count -eq 0) { throw "No XMLs found in $xmlDir" }

$first = Get-Content $xmls[0].FullName -Raw

# Old SID: in <UserId>S-1-5-21-...-NNNN</UserId>
if ($first -notmatch '<UserId>(S-1-5-21-[0-9-]+)</UserId>') {
    throw "Could not detect old SID in $($xmls[0].Name)"
}
$oldSid = $matches[1]

# Old <Author> can be either bare username ("david") or qualified ("HOST\david")
# Capture both forms so we substitute correctly.
$oldQualifiedAuthor = $null
$oldBareAuthor = $null
foreach ($x in $xmls) {
    $c = Get-Content $x.FullName -Raw
    if ($c -match '<Author>([A-Za-z0-9_-]+)\\([A-Za-z0-9_-]+)</Author>') {
        if (-not $oldQualifiedAuthor) { $oldQualifiedAuthor = "$($matches[1])\$($matches[2])" }
    }
    if ($c -match '<Author>([A-Za-z0-9_-]+)</Author>') {
        if (-not $oldBareAuthor) { $oldBareAuthor = $matches[1] }
    }
}

# Old repo path: detect by extracting the directory from <Command> values that
# end in .cmd or .ps1 (kopia-stack scripts), OR <Arguments> -File paths.
$oldRepoPath = $null
foreach ($x in $xmls) {
    $c = Get-Content $x.FullName -Raw
    # Look for any C:\dev\kopia\... pattern (the typical install). Generalize
    # by grabbing the prefix up to \scripts or \cicd subdir.
    if ($c -match '([A-Z]:\\(?:[^\\]+\\)*?(?:dev|src)\\kopia)\\(scripts|cicd)\\') {
        $oldRepoPath = $matches[1]
        break
    }
}
if (-not $oldRepoPath) { $oldRepoPath = 'C:\dev\kopia' }  # safe fallback

Write-Host "[regenerate-tasks] detected old values:"
Write-Host "  SID:               $oldSid"
Write-Host "  QualifiedAuthor:   $($oldQualifiedAuthor ?? '(none)')"
Write-Host "  BareAuthor:        $($oldBareAuthor ?? '(none)')"
Write-Host "  RepoPath:          $oldRepoPath"
Write-Host ""

# Idempotency check
$newQualifiedAuthor = "$NewHostname\$NewUsername"
if (
    ($oldSid -eq $NewSid) -and
    ($oldRepoPath -eq $RepoPath) -and
    ((-not $oldQualifiedAuthor) -or ($oldQualifiedAuthor -eq $newQualifiedAuthor)) -and
    ((-not $oldBareAuthor) -or ($oldBareAuthor -eq $NewUsername))
) {
    Write-Host "[regenerate-tasks] all values already current -- no-op" -ForegroundColor Green
    exit 0
}

$changed = @()
foreach ($x in $xmls) {
    $original = Get-Content $x.FullName -Raw
    $modified = $original

    if ($oldSid -ne $NewSid) {
        $modified = $modified.Replace("<UserId>$oldSid</UserId>", "<UserId>$NewSid</UserId>")
    }
    if ($oldQualifiedAuthor -and $oldQualifiedAuthor -ne $newQualifiedAuthor) {
        $modified = $modified.Replace("<Author>$oldQualifiedAuthor</Author>", "<Author>$newQualifiedAuthor</Author>")
    }
    if ($oldBareAuthor -and $oldBareAuthor -ne $NewUsername) {
        $modified = $modified.Replace("<Author>$oldBareAuthor</Author>", "<Author>$NewUsername</Author>")
    }
    if ($oldRepoPath -ne $RepoPath) {
        # Replace each absolute reference. Order matters: longer prefixes first
        # to avoid accidentally substituting partial paths.
        $modified = $modified.Replace($oldRepoPath, $RepoPath)
    }

    if ($modified -ne $original) {
        # Preserve the existing encoding pattern (UTF-8 bytes despite the
        # encoding="UTF-16" declaration -- schtasks /create /xml requires it).
        Set-Content -Path $x.FullName -Value $modified -Encoding UTF8 -NoNewline
        $changed += $x.Name
    }
}

if ($changed.Count -eq 0) {
    Write-Host "[regenerate-tasks] no changes needed (per-field check matched)" -ForegroundColor Green
} else {
    Write-Host "[regenerate-tasks] rewrote $($changed.Count) file(s):" -ForegroundColor Yellow
    $changed | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Review with: git diff scripts/scheduled-tasks/"
    Write-Host "  2. Apply to Task Scheduler: make deploy-tasks   (elevation may be needed for HighestAvailable tasks)"
    Write-Host "  3. Commit if these XMLs become the new canonical state for this host"
}
