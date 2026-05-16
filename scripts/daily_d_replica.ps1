# daily_d_replica.ps1 -- Daily mirror of D: to the 8 TB external (E:).
#
# Single-tool design: VSS shadow of D:, then one backup-mirror.exe invocation
# per top-level subtree on D:. Mode is always cbt (chunk-CBT, 4 MiB chunks).
# WindowsImageBackup uses --manifest-key basename so wbadmin's nightly
# dated-folder rotation doesn't defeat the incremental; other subtrees use
# the default relpath keying.
#
# History: replaced robocopy /MIR (kopia-5ua), then cwRsync (kopia-0q9),
# then cwRsync as of kopia-bmy.3 (2026-05-13). The earlier rsync-era code
# is recoverable via git log; rsync rationale comments were removed to
# keep the live script focused.
#
# Scheduled at 02:00 by \Backup\DailyDReplica (epic kopia-bmy).

[CmdletBinding()]
param(
    [string]$SourceDrive     = 'D:',
    [string]$TargetRoot      = 'E:\',
    [string]$LogFile         = 'C:\dev\kopia\logs\daily_d_replica.log',
    [string]$DailyKopiaLog   = 'C:\dev\kopia\logs\daily_kopia.log',
    [string]$FlagFile        = 'C:\dev\kopia\logs\BACKUP_REPLICA_FAIL.flag',
    [string]$HeartbeatLog    = 'C:\dev\kopia\logs\heartbeat.log',
    [string]$AppId           = 'KopiaBackup.HealthCheck',
    [string]$LaunchProto     = 'kopiamonitor:open',
    [string]$BackupMirrorExe = 'C:\dev\backup-monitor\target\release\backup-mirror.exe',
    [string]$ManifestRoot    = 'C:\BackupMirror\manifests',
    [string]$BackupMirrorLogRoot = 'C:\BackupMirror\logs',
    [int]$HeartbeatStaleSec  = 300,
    [int64]$HeadroomBytes    = 50GB,
    [int]$ProgressIntervalSec = 60,
    [switch]$InitialSeed,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---- Log rotation (match daily_kopia_backup.cmd pattern) ----
if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 1MB)) {
    $old = "$LogFile.old"
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    Move-Item -LiteralPath $LogFile -Destination $old -Force
}

function Write-Log {
    param([Parameter(Mandatory)] [string]$Message, [string]$Tag = 'replica')
    $line = '{0} -- [{1}] {2}' -f (Get-Date -Format 'ddd MM/dd/yyyy HH:mm:ss.ff'), $Tag, $Message
    Add-Content -LiteralPath $LogFile -Value $line
    Write-Host $line
}

# Probe WinRT toast availability ONCE at startup (kopia-ytq). Background /
# non-interactive PS hosts (manual recovery runs, service contexts) can't load
# the WindowsRuntime UI assemblies; previously every Show-Toast call hit the
# same failure and logged the same noisy 'toast emission failed' line. Probe
# once, cache the result, downgrade subsequent skips to a single explanatory
# line.
$script:ToastsEnabled = $true
try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,        ContentType=WindowsRuntime]
} catch {
    $script:ToastsEnabled = $false
}

function Show-Toast {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Body
    )
    if ($InitialSeed) { return }   # interactive seed run: no toast
    if (-not $script:ToastsEnabled) {
        if (-not $script:ToastSkipLogged) {
            Write-Log "toasts disabled (WinRT type-loading failed -- non-interactive session); silently skipping further Show-Toast calls" 'toast'
            $script:ToastSkipLogged = $true
        }
        return
    }
    try {
        $enc    = { param($s) [System.Security.SecurityElement]::Escape($s) }
        $titleX = & $enc $Title
        $bodyX  = & $enc $Body
        $launch = & $enc $LaunchProto
        $xml = @"
<toast launch="$launch" activationType="protocol">
  <visual>
    <binding template="ToastGeneric">
      <text>$titleX</text>
      <text>$bodyX</text>
    </binding>
  </visual>
  <actions>
    <action content="Open Backup Monitor" activationType="protocol" arguments="$launch" />
  </actions>
</toast>
"@
        $doc = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $doc.LoadXml($xml)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
    } catch {
        Write-Log "toast emission failed: $_" 'toast'
    }
}

function Touch-FailFlag {
    param([Parameter(Mandatory)] [string]$Reason)
    "$(Get-Date -Format s) | $Reason" | Set-Content -LiteralPath $FlagFile
}

function Clear-FailFlag {
    if (Test-Path -LiteralPath $FlagFile) { Remove-Item -LiteralPath $FlagFile -Force }
}

function Append-Summary {
    # Append one `replica summary ...` line to daily_kopia.log. That file is
    # shared with daily_kopia_backup.cmd, which holds it via cmd's `>>` (opens
    # with FILE_SHARE_READ only, no shared write). Two writers landing in the
    # same millisecond surface as a Win32 ERROR_SHARING_VIOLATION which
    # Add-Content turns into a terminating error under
    # $ErrorActionPreference='Stop' -- inside the finally block that kills the
    # rest of cleanup (skips the [done] log line, flag clear, and exit 0).
    # Observed 2026-05-16 03:19:16 when an unusually long replica overlapped
    # the kopia daily window. Retry with short backoff; if we still can't
    # write, swallow it -- a missing summary line is a much smaller harm than
    # a missing [done] / unmanaged flag state.
    param([Parameter(Mandatory)] [hashtable]$Fields)
    $parts = $Fields.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }
    $line  = '{0} -- replica summary {1}' -f (Get-Date -Format 'ddd MM/dd/yyyy HH:mm:ss.ff'), ($parts -join ' ')
    $attempts = 20
    $delayMs  = 250
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Add-Content -LiteralPath $DailyKopiaLog -Value $line -ErrorAction Stop
            return
        } catch {
            if ($i -eq $attempts) {
                Write-Log ("WARNING: Append-Summary gave up after {0} attempts ({1}ms): {2}" -f $attempts, ($attempts * $delayMs), $_.Exception.Message) 'done'
                return
            }
            Start-Sleep -Milliseconds $delayMs
        }
    }
}

# Cleanup via a child powershell.exe that runs a temp .ps1 file. The file
# pattern avoids the embedded-double-quote escape hell of -Command when the
# cleanup logic references WMI filter strings like `"ID='{guid}'"`. Used in
# the finally block so a hung VSS shadow release / mount removal can't pin us:
# - 2026-05-10 initial seed: synchronous cleanup hung 8h.
# - 2026-05-10 follow-up: Start-Job + Wait-Job hit PS 5.1's
#   BlockedJobsDeadlockWithWaitJob even with -Timeout.
# - 2026-05-10 follow-up 2: Start-Process -Command with embedded WMI-filter
#   quotes failed silently (child exit 1, empty output).
# Spawn a child via -File, WaitForExit with a hard millisecond timeout,
# Kill() the child on timeout. Any leftover orphan gets caught by next-run
# preflight.
function Invoke-CleanupChild {
    param(
        [Parameter(Mandatory)] [string]$ScriptBody,
        [int]$TimeoutSec = 30
    )
    $tmp = Join-Path $env:TEMP ("kopia-replica-cleanup-{0}.ps1" -f [guid]::NewGuid())
    Set-Content -LiteralPath $tmp -Value $ScriptBody -Encoding ASCII
    $p = Start-Process powershell.exe `
        -ArgumentList '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$tmp `
        -PassThru -WindowStyle Hidden
    $finished = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        try { $p.Kill() } catch {}
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return @{ Completed = $false; ExitCode = -1 }
    }
    $ec = $p.ExitCode
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return @{ Completed = $true; ExitCode = $ec }
}

Write-Log "============================================"
$mode = if ($InitialSeed) { 'INITIAL-SEED' } elseif ($DryRun) { 'DRY-RUN' } else { 'NORMAL' }
Write-Log "Daily D: -> E: replica start (mode=$mode)" 'start'

$src = $SourceDrive.TrimEnd('\',':') + ':'   # normalise to 'D:'
$dst = $TargetRoot

$startTime = Get-Date
$shadow      = $null
$shadowMount = $null
$summary     = @{
    source          = $src
    target          = $dst.TrimEnd('\')
    mode            = $mode
    bytes           = 0           # sum of bytes_written across all backup-mirror invocations
    files           = 0           # sum of files_total across all backup-mirror invocations
    errors          = 1           # default fail; cleared on PASS path
    duration_s      = 0
    robocopy_rc     = -1          # worst exit code across all backup-mirror invocations (legacy field name preserved for backup-dump compat)
    chunks_changed  = 0           # sum of chunks_changed across all invocations
    chunks_total    = 0           # sum of chunks_total across all invocations
    shadow_id       = '-'
    tool            = 'backup-mirror'
}

try {
    # ---- Preflight: clean up orphans from prior hung runs ----
    # Any kopia-replica-shadow-* junction in TEMP is from a prior run whose
    # finally block didn't complete. The orphan's name embeds the VSS shadow
    # GUID -- kopia-replica-shadow-{GUID-without-braces} -- so we delete both
    # the junction AND the underlying Win32_ShadowCopy (kopia-9wu). Without
    # the WMI delete, shadows accumulate on D: across hung/killed runs and
    # consume shadow-storage. Junctions are deleted first because junctions
    # alone hang in long Remove-Item cycles only if the underlying shadow is
    # still mounted; WMI delete on the shadow auto-unmounts.
    foreach ($om in (Get-ChildItem $env:TEMP -Filter 'kopia-replica-shadow-*' -ErrorAction SilentlyContinue)) {
        $path = $om.FullName
        $shadowIdFromName = $null
        if ($om.Name -match '^kopia-replica-shadow-([0-9A-Fa-f-]{36})$') {
            $shadowIdFromName = '{' + $matches[1] + '}'
        }
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Write-Log "removed orphan junction from prior run: $path" 'preflight'
        } catch {
            Write-Log "WARNING: could not remove orphan junction ${path}: $_" 'preflight'
        }
        if ($shadowIdFromName) {
            try {
                $sc = Get-CimInstance Win32_ShadowCopy -Filter "ID='$shadowIdFromName'" -ErrorAction SilentlyContinue
                if ($sc) {
                    Remove-CimInstance -InputObject $sc -ErrorAction Stop
                    Write-Log "removed orphan VSS shadow $shadowIdFromName" 'preflight'
                }
            } catch {
                Write-Log "WARNING: could not remove orphan VSS shadow ${shadowIdFromName}: $_" 'preflight'
            }
        }
    }

    # ---- Preflight: target volume ----
    Write-Log "preflight: target volume" 'preflight'
    $targetLetter = $dst.Substring(0,1)
    $targetVol = Get-Volume -DriveLetter $targetLetter -ErrorAction SilentlyContinue
    if (-not $targetVol) { throw "target volume $targetLetter`: not mounted" }
    if (-not (Test-Path -LiteralPath $dst)) { throw "target root not accessible: $dst" }

    # ---- Preflight: free space ----
    # Two regimes: initial seed (target effectively empty) needs space for the
    # whole source plus headroom; incremental (target already has most of
    # source) only needs space for the delta plus headroom. Detect via target
    # usage -- once target has >100 GB it's clearly been seeded.
    $srcVol = Get-Volume -DriveLetter $src.Substring(0,1)
    $srcUsed = $srcVol.Size - $srcVol.SizeRemaining
    $tgtUsed = $targetVol.Size - $targetVol.SizeRemaining
    $initialSeedRegime = ($tgtUsed -lt 100GB)
    if ($initialSeedRegime) {
        $needed = $srcUsed + $HeadroomBytes
        $regime = 'initial-seed'
    } else {
        # Incremental: worst case is the delta robocopy will add. Use the
        # actual source/target gap plus headroom. Floor at 50 GB so we always
        # require breathing room even if target is "ahead" of source.
        $delta  = [Math]::Max([int64]0, [int64]($srcUsed - $tgtUsed))
        $needed = $delta + $HeadroomBytes
        $regime = 'incremental'
    }
    if ($targetVol.SizeRemaining -lt $needed) {
        throw ("target free {0:N1} GB < required {1:N1} GB (regime={2}, source used={3:N1}GB, target used={4:N1}GB, headroom={5:N0}GB)" -f `
            ($targetVol.SizeRemaining/1GB), ($needed/1GB), $regime, ($srcUsed/1GB), ($tgtUsed/1GB), ($HeadroomBytes/1GB))
    }
    Write-Log ("target free={0:N1}GB, source used={1:N1}GB, target used={2:N1}GB, regime={3}, needed={4:N1}GB OK" -f `
        ($targetVol.SizeRemaining/1GB), ($srcUsed/1GB), ($tgtUsed/1GB), $regime, ($needed/1GB)) 'preflight'

    # ---- Preflight: kopia server heartbeat (skip during -InitialSeed) ----
    if (-not $InitialSeed -and (Test-Path -LiteralPath $HeartbeatLog)) {
        $hbAge = [int]((Get-Date) - (Get-Item -LiteralPath $HeartbeatLog).LastWriteTime).TotalSeconds
        if ($hbAge -gt $HeartbeatStaleSec) {
            throw "kopia server heartbeat stale: $hbAge s > $HeartbeatStaleSec s"
        }
        Write-Log "heartbeat fresh (${hbAge}s)" 'preflight'
    }

    # ---- Phase 1: Create VSS shadow of source ----
    # Robocopy cannot read directly from \\?\GLOBALROOT\Device\... paths
    # (ERROR 123: filename syntax incorrect -- confirmed empirically). The
    # standard workaround is to create a directory symlink to the shadow
    # path and have robocopy read through that. Symlink lives under
    # $env:TEMP and is torn down in the finally block alongside the shadow.
    Write-Log "creating VSS shadow of $src\" 'vss'
    if ($DryRun) {
        Write-Log "DRY-RUN: skipping VSS create; would call Win32_ShadowCopy.Create('$src\\','ClientAccessible')" 'vss'
        $shadowPath = "$src\"
    } else {
        $vssClass = [WMICLASS]'root\cimv2:Win32_ShadowCopy'
        $vssResult = $vssClass.Create("$src\", 'ClientAccessible')
        if ($vssResult.ReturnValue -ne 0) {
            throw "VSS create failed: ReturnValue=$($vssResult.ReturnValue)"
        }
        $shadow = Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID='$($vssResult.ShadowID)'"
        if (-not $shadow) { throw "VSS shadow created but lookup failed (ID=$($vssResult.ShadowID))" }
        $summary.shadow_id = $shadow.ID
        Write-Log "shadow created: ID=$($shadow.ID) device=$($shadow.DeviceObject)" 'vss'

        $shadowMount = Join-Path $env:TEMP ("kopia-replica-shadow-" + ($shadow.ID -replace '[{}]',''))
        if (Test-Path -LiteralPath $shadowMount) { Remove-Item -LiteralPath $shadowMount -Force }
        $mkOut = & cmd /c "mklink /D `"$shadowMount`" `"$($shadow.DeviceObject)\`"" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "mklink to shadow failed (exit=$LASTEXITCODE): $mkOut" }
        $shadowPath = $shadowMount + '\'
        Write-Log "shadow mounted: $shadowMount -> $($shadow.DeviceObject)" 'vss'
    }

    # ---- Phase 2: backup-mirror chunk-CBT (replaces cwRsync, kopia-bmy.3) ----
    # Single tooling for the whole D: -> E: mirror. One backup-mirror invocation
    # per top-level subtree on D:\ (via shadow). Mode is always cbt; the
    # manifest-key differs:
    #   - WindowsImageBackup: --manifest-key basename. wbadmin renames the
    #     dated folder ("Backup 2026-05-14 050000") nightly but the VHDX
    #     basename (the Windows source-disk GUID) is stable, so basename
    #     keying lets night-2 onward do true block-level incrementals.
    #   - All other subtrees: --manifest-key relpath (default). Paths are
    #     stable so relpath keying gives correct identity.
    #
    # System / transient dirs are excluded by name. Top-level loose files
    # (e.g. the Win11 ISO at D:\ root) are mirrored via backup-mirror's
    # single-file cbt mode (kopia-2ls); pagefile/swapfile/hiberfil and
    # similar Windows transients are excluded explicitly.
    #
    # Each invocation writes its own progress JSONL and a summary line on
    # stdout. We aggregate the per-tree CBT stats into the replica summary.
    $bmExe = $BackupMirrorExe
    if (-not (Test-Path -LiteralPath $bmExe)) {
        throw "backup-mirror.exe not found at $bmExe -- run cargo build --release in C:\dev\backup-monitor"
    }
    $bmSig = Get-AuthenticodeSignature -LiteralPath $bmExe
    if ($bmSig.Status -ne 'Valid') {
        throw "backup-mirror.exe signature is not Valid (Status=$($bmSig.Status)) -- run signing\sign-all.ps1"
    }
    Write-Log "backup-mirror.exe: $bmExe (sig=$($bmSig.Status))" 'mirror'

    # Per-run log root: per-tree progress JSONL + summary log.
    $runStamp     = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $runLogDir    = Join-Path $BackupMirrorLogRoot ("run-" + $runStamp)
    if (-not (Test-Path -LiteralPath $runLogDir)) {
        New-Item -ItemType Directory -Path $runLogDir -Force | Out-Null
    }
    Write-Log "per-run log dir: $runLogDir" 'mirror'

    # Enumerate top-level entries on the source shadow. Skip system dirs and
    # rsync-historical excludes. Single files at root are skipped (see
    # note above; the only such file is the Win11 ISO).
    #
    # Sysmon: rsync excluded *.sdb-wal/*.sdb-shm because those are open-file
    # transient state with ACLs that deny even via VSS shadow. backup-mirror
    # has no --exclude flag, so hitting one of those files would abort the
    # Sysmon subtree mid-run. Skip the whole subtree until backup-mirror
    # gains per-file-skip semantics. Sysmon is local telemetry, regenerable.
    # Excludes apply to both directories and top-level files: Recycle Bin and
    # Volume Information are NTFS system; BackupMonitorIndex is a known
    # local-state dir; Sysmon is open-file transient that backup-mirror
    # can't safely mirror without per-file-skip semantics. File excludes
    # catch pagefile/swapfile/hiberfil if D: is ever configured as a paging
    # target.
    $EXCLUDE_TOP = @(
        '$RECYCLE.BIN', 'System Volume Information', 'BackupMonitorIndex', 'Sysmon',
        'pagefile.sys', 'swapfile.sys', 'hiberfil.sys', 'DumpStack.log.tmp'
    )
    $topEntries  = Get-ChildItem -LiteralPath $shadowPath -Force -ErrorAction Stop |
                   Where-Object { $EXCLUDE_TOP -notcontains $_.Name }
    if (-not $topEntries) { throw "no top-level entries found on shadow ($shadowPath)" }
    Write-Log ("subtrees to mirror: " + (($topEntries | ForEach-Object Name) -join ', ')) 'mirror'

    $worstRc        = 0
    $aggBytes       = [int64]0
    $aggFiles       = [int64]0
    $aggChunksChg   = [int64]0
    $aggChunksTot   = [int64]0
    $perTreeReports = @()

    # ---- Phase 2a: pre-mirror dst alignment (kopia-8fc) ----
    # Run ALL dst-cleanup before ANY tree-mirror writes. Reason: a heavy-write
    # tree (e.g. KopiaRepo) processed earlier in the foreach could exhaust
    # E:\ free space before a later tree (WindowsImageBackup) has a chance to
    # free its own rotation-orphaned TBs. Doing every cleanup first means the
    # write phase always starts from the maximum-free-space state.
    #
    # Today only WindowsImageBackup needs alignment (basename manifest-key
    # plus wbadmin's nightly dated-folder rotation). Other trees use relpath
    # and their src→dst paths are stable, so they have no alignment step.
    # The loop is intentionally structured so additional alignment-needing
    # trees can be added later without re-introducing the sequencing risk.
    foreach ($entry in $topEntries) {
        if ($entry.Name -ne 'WindowsImageBackup') { continue }
        if ($DryRun) { continue }
        $srcPath = $entry.FullName.TrimEnd('\')
        $dstPath = (Join-Path $dst $entry.Name).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $dstPath)) { continue }

        # WindowsImageBackup uses --manifest-key basename so the per-VHDX CBT
        # manifest is keyed by the source-disk GUID (stable across wbadmin's
        # nightly dated-folder rotation). But backup-mirror still computes
        # each file's dst path as dst_root.join(rel-from-src) — so when
        # wbadmin's parent folder rotates (Backup 2026-05-14 → Backup
        # 2026-05-15) the dst at the new name is empty even though the
        # manifest matches, and the post-kopia-8j4 preflight torn-recovers
        # the full 2.7 TB. Pre-align the dst dated folder to match src so
        # the basename manifest's hashes land on a populated dst.
        $machineDirs = @(Get-ChildItem -LiteralPath $srcPath -Directory -ErrorAction SilentlyContinue)
        foreach ($mach in $machineDirs) {
            $dstMachinePath = Join-Path $dstPath $mach.Name
            if (-not (Test-Path -LiteralPath $dstMachinePath)) { continue }

            $srcDated = @(Get-ChildItem -LiteralPath $mach.FullName -Directory -Filter 'Backup *' -ErrorAction SilentlyContinue)
            if ($srcDated.Count -ne 1) { continue }  # wbadmin invariant; bail safely if violated
            $srcDatedName = $srcDated[0].Name

            $dstDated = @(Get-ChildItem -LiteralPath $dstMachinePath -Directory -Filter 'Backup *' -ErrorAction SilentlyContinue)
            if ($dstDated.Count -eq 0) { continue }  # first run for this machine, nothing to align

            $matching = $dstDated | Where-Object { $_.Name -eq $srcDatedName } | Select-Object -First 1
            $stale    = $dstDated | Where-Object { $_.Name -ne $srcDatedName }

            if ($matching) {
                foreach ($s in $stale) {
                    Write-Log ("[{0}] removing stale dst dated folder under {1}: '{2}'" -f $entry.Name, $mach.Name, $s.Name) 'mirror'
                    Remove-Item -LiteralPath $s.FullName -Recurse -Force -ErrorAction Stop
                }
                # Positive confirmation on the steady-state no-op path
                # (kopia-10r). Without it a future regression that silently
                # bypassed alignment would only surface after a wbadmin
                # rotation forced a multi-TB re-mirror.
                if ($stale.Count -eq 0) {
                    Write-Log ("[{0}] alignment check under {1}: dst '{2}' already matches src" -f $entry.Name, $mach.Name, $srcDatedName) 'mirror'
                }
                continue
            }

            # No matching dst folder. Rename the newest stale one to align
            # with src and delete the rest. Newest by LastWriteTime = most
            # recently mirrored = the candidate carrying valid chunks.
            $sorted = $stale | Sort-Object LastWriteTime -Descending
            $keep   = $sorted | Select-Object -First 1
            foreach ($s in ($sorted | Select-Object -Skip 1)) {
                Write-Log ("[{0}] removing stale dst dated folder under {1}: '{2}'" -f $entry.Name, $mach.Name, $s.Name) 'mirror'
                Remove-Item -LiteralPath $s.FullName -Recurse -Force -ErrorAction Stop
            }
            if ($keep) {
                Write-Log ("[{0}] aligning dst dated folder under {1}: '{2}' -> '{3}'" -f $entry.Name, $mach.Name, $keep.Name, $srcDatedName) 'mirror'
                Rename-Item -LiteralPath $keep.FullName -NewName $srcDatedName -ErrorAction Stop
            }
        }
    }

    # ---- Phase 2b: per-tree mirror invocations ----
    foreach ($entry in $topEntries) {
        $treeName    = $entry.Name
        $srcPath     = $entry.FullName.TrimEnd('\')
        $dstPath     = (Join-Path $dst $treeName).TrimEnd('\')
        $mfdPath     = Join-Path $ManifestRoot $treeName
        $progressLog = Join-Path $runLogDir ("{0}.progress.jsonl" -f $treeName)
        $summaryOut  = Join-Path $runLogDir ("{0}.summary.log"   -f $treeName)
        $manifestKey = if ($treeName -eq 'WindowsImageBackup') { 'basename' } else { 'relpath' }

        if (-not (Test-Path -LiteralPath $mfdPath)) {
            New-Item -ItemType Directory -Path $mfdPath -Force | Out-Null
        }

        $argList = @(
            'mirror',
            '--mode',  'cbt',
            '--src',   $srcPath,
            '--dst',   $dstPath,
            '--manifest-dir', $mfdPath,
            '--manifest-key', $manifestKey,
            '--progress-interval-sec', "$ProgressIntervalSec"
        )
        if ($DryRun) { $argList += '--dry-run' }

        # USN V4 byte-range tracking for WindowsImageBackup (kopia-61n).
        # Only enabled for the wbadmin VHDX subtree where ~99% of the
        # multi-TB file is unchanged on a typical nightly. Idempotently
        # creates + enables the journal on D:\ on first run. Other
        # subtrees stay on the existing chunk-CBT-only path; KopiaRepo
        # is the target of kopia-1tr (separate bead).
        $usnStateDir = $null
        if ($treeName -eq 'WindowsImageBackup') {
            $usnStateDir = Join-Path 'C:\BackupMirror\state' $treeName
            if (-not (Test-Path -LiteralPath $usnStateDir)) {
                New-Item -ItemType Directory -Path $usnStateDir -Force | Out-Null
            }
            $argList += '--usn-journal-state', $usnStateDir
            $argList += '--usn-volume',        'D:\'
        }

        $usnTag = if ($usnStateDir) { ' usn=on' } else { '' }
        Write-Log ("[{0}] launching: mode=cbt manifest-key={1} dst={2}{3}" -f $treeName, $manifestKey, $dstPath, $usnTag) 'mirror'
        $treeStart = Get-Date
        $proc = Start-Process -FilePath $bmExe -ArgumentList $argList `
                              -RedirectStandardOutput $summaryOut `
                              -RedirectStandardError  $progressLog `
                              -WindowStyle Hidden -PassThru -Wait
        $rc = $proc.ExitCode
        $treeDur = [int]((Get-Date) - $treeStart).TotalSeconds
        if ($rc -gt $worstRc) { $worstRc = $rc }

        # Parse the final stdout summary line:
        #   "backup-mirror summary mode=cbt files_total=X files_first_run=Y
        #    files_torn_recovered=Z chunks_total=A chunks_changed=B
        #    chunks_zero=C bytes_read=D bytes_written=E duration_s=F errors=G"
        $bytes = 0; $files = 0; $chunksTot = 0; $chunksChg = 0
        if (Test-Path -LiteralPath $summaryOut) {
            $sumLine = Get-Content -LiteralPath $summaryOut -Tail 5 |
                       Where-Object { $_ -match '^backup-mirror summary ' } |
                       Select-Object -Last 1
            if ($sumLine) {
                foreach ($tok in ($sumLine -split '\s+')) {
                    $kv = $tok -split '=', 2
                    if ($kv.Count -eq 2) {
                        switch ($kv[0]) {
                            'files_total'    { $files     = [int64]$kv[1] }
                            'chunks_total'   { $chunksTot = [int64]$kv[1] }
                            'chunks_changed' { $chunksChg = [int64]$kv[1] }
                            'bytes_written'  { $bytes     = [int64]$kv[1] }
                        }
                    }
                }
            }
        }
        Write-Log ("[{0}] rc={1} duration={2}s bytes_written={3} files={4} chunks_changed={5}/{6}" -f `
            $treeName, $rc, $treeDur, $bytes, $files, $chunksChg, $chunksTot) 'mirror'

        $perTreeReports += [pscustomobject]@{
            tree         = $treeName
            rc           = $rc
            duration_s   = $treeDur
            files        = $files
            bytes        = $bytes
            chunks_total = $chunksTot
            chunks_changed = $chunksChg
            manifest_key = $manifestKey
        }

        $aggBytes     += $bytes
        $aggFiles     += $files
        $aggChunksTot += $chunksTot
        $aggChunksChg += $chunksChg
    }

    $summary.bytes          = $aggBytes
    $summary.files          = $aggFiles
    $summary.chunks_total   = $aggChunksTot
    $summary.chunks_changed = $aggChunksChg
    $summary.robocopy_rc    = $worstRc

    if ($worstRc -ne 0) {
        $failedTrees = ($perTreeReports | Where-Object { $_.rc -ne 0 } | ForEach-Object { "$($_.tree)=$($_.rc)" }) -join ', '
        throw "backup-mirror failed on: $failedTrees (worst rc=$worstRc; per-tree logs in $runLogDir)"
    }
    Write-Log ("all subtrees PASS: trees={0} total_bytes_written={1} total_files={2} chunks_changed/total={3}/{4}" -f `
        $perTreeReports.Count, $aggBytes, $aggFiles, $aggChunksChg, $aggChunksTot) 'mirror'

    $summary.errors = 0
    Write-Log "PASS" 'result'
}
catch {
    Write-Log "ERROR: $_" 'result'
    Touch-FailFlag -Reason ($_.Exception.Message)
    Show-Toast -Title 'D: Replica: FAIL' -Body ($_.Exception.Message)
    $summary.errors = 1
}
finally {
    # Cleanup VSS shadow + mount in a child powershell.exe (via temp .ps1 file
    # to dodge -Command quoting hell). Hard 30s timeout -- any orphan that
    # survives gets caught by next-run preflight.
    if ($shadowMount -or $shadow) {
        $body = @()
        if ($shadowMount) {
            $body += "if (Test-Path -LiteralPath '$shadowMount') { Remove-Item -LiteralPath '$shadowMount' -Recurse -Force -ErrorAction SilentlyContinue }"
        }
        if ($shadow) {
            $sid = $shadow.ID
            $body += "`$s = Get-CimInstance Win32_ShadowCopy -Filter ""ID='$sid'"" -ErrorAction SilentlyContinue"
            $body += "if (`$s) { Remove-CimInstance -InputObject `$s -ErrorAction SilentlyContinue }"
        }
        $scriptBody = $body -join "`r`n"
        try {
            $r = Invoke-CleanupChild -ScriptBody $scriptBody -TimeoutSec 30
            if ($r.Completed) {
                Write-Log ("vss cleanup child exited rc={0}" -f $r.ExitCode) 'vss'
            } else {
                Write-Log "WARNING: vss cleanup child TIMEOUT after 30s -- killed, next preflight will sweep" 'vss'
            }
        } catch {
            Write-Log "WARNING: cleanup child spawn failed: $_" 'vss'
        }
    }

    $summary.duration_s = [int]((Get-Date) - $startTime).TotalSeconds
    Append-Summary -Fields $summary
    Write-Log ("done: errors={0} bytes={1} files={2} duration={3}s rc={4}" -f `
        $summary.errors, $summary.bytes, $summary.files, $summary.duration_s, $summary.robocopy_rc) 'done'

    # DryRun and InitialSeed do not modify production state (flag/toast).
    if ($summary.errors -eq 0 -and -not $DryRun) {
        Clear-FailFlag
        if (-not $InitialSeed) {
            Show-Toast -Title 'D: Replica: PASS' -Body ("{0} files, {1:N1} GB, {2:N0}s" -f `
                $summary.files, ($summary.bytes/1GB), $summary.duration_s)
        }
    }

    Write-Log "============================================"
    exit $summary.errors
}



# SIG # Begin signature block
# MII9agYJKoZIhvcNAQcCoII9WzCCPVcCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAsvnxfs6EFF0F7
# /7qlDw62ohylQVTq4aL1gqqeM320SaCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAEWi3g6
# g8Ba7npPAAAAARaLMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwHhcNMjYwNTE2MTc1MTUwWhcNMjYwNTE5
# MTc1MTUwWjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAikJVvZlEx3n7x1bD5dZi
# EOr/Fk4zy09mH4hbP3AQtlpfDHJwLsRGMQXNV5lqd/02jafy0D6Ua5NIS+IePLSu
# Qp6knY2jbyzGa4avZ3LCiLRk82+THpZJ5xcb/lcCKMEZQQkMxQfAXxfSE1WflYiC
# yovpz4tduQaKdid+woBlvdVyskkjnpKdHijnrbXkmQ2odIQM7GxbYgViCq8z1XYx
# U7WiUHUkjqMifFHMbnJIoSGPxjUVRcnCIGGhZHt3fYGoBCBGGw8h+Jta0vrYFLzz
# VPWfsHIQzAKmyT1u/FzBba14G1A1qp3Fh2n/ovMBntuQx1K0Pk6pdg3l43j+wPIN
# +KTaH8uWm4is2o1MLAYGm0eLK94qcjahFSeKrq0czNJjXlvU4lOAhm7Bommd31Ni
# vNT6EbOBfWh2pQOXNKKVAe4wfVcR3VbSQxDaGW9JZ4p9kkC90Z7Bla/3neIwPm76
# cXwopzjMpnstHs2mpFvfaHoZ/wXJNlzxgt8PlnWfch3rAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBS3SBdEnJiYpRhpxaP8hwPVPPlHiDAfBgNVHSMEGDAWgBSkQwx/dlqlhec+
# jSgPDBeiRWlwxjBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBBT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwMy5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEAn1sB7M9NE6XiaAxFkmb0ZLl2cETch2I9y2lM/rkuUSTaly8bs7Izg8bSElSk
# xIdD+q6pq2ryFBF8vuleaj+QgMN/xeZn8gJhxs3WoFf4WAqvTGkPuszgOzir3ZAB
# 3i1xp32306NWFO2dlcM2VA+joi4e9yKxgWy6/2P6ibIdyvZmEydDP/37TYkIWYrP
# YmWpw50maE1IijzhnsTzYeuA57+ca9tE0AqyitFVE0wSzz8lVXmvRS5qo2GjHOO0
# M4MRKGgdcE7sH03VA4UI6dvquK5RfpE/lproqX6sEcrktJ9E6WKASptFPeZe+NMR
# HyTwsU/DOJms3j72mJtkZKTFPXtWHjhaDbYcD2DmCeyMbl0LZ5tAXkf9u3L2MlIN
# 5aep6PFEnVEfKYcQIoxbMoWPyUw59lhUYk1S1EuKoBUNXLjb0k0m69nWnHE+ieli
# TIJzBtY5Lb2aaBOYFr+mqYcqOxyumxFmaW0V5Fkl9lKdUqjJ/9UyWLUqxVNieL/2
# lT7tzG05dNl8sICKtCde4wiwx4nWRuPBEB70RwA1+vX4/da1BfN6cUc3mMA4hik7
# VhZOB570fhelDZjUvRLr3giggUp4HgdkUkiWtp87NFWQookf0Q3mRw58rB3i8oVO
# DX7kRMtoxSpcmV+tsDNkQVWZbFKSA8uPZCoRhaQO0LcIah0wggbFMIIEraADAgEC
# AhMzAAEWi3g6g8Ba7npPAAAAARaLMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwHhcNMjYwNTE2MTc1MTUw
# WhcNMjYwNTE5MTc1MTUwWjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAikJVvZlE
# x3n7x1bD5dZiEOr/Fk4zy09mH4hbP3AQtlpfDHJwLsRGMQXNV5lqd/02jafy0D6U
# a5NIS+IePLSuQp6knY2jbyzGa4avZ3LCiLRk82+THpZJ5xcb/lcCKMEZQQkMxQfA
# XxfSE1WflYiCyovpz4tduQaKdid+woBlvdVyskkjnpKdHijnrbXkmQ2odIQM7Gxb
# YgViCq8z1XYxU7WiUHUkjqMifFHMbnJIoSGPxjUVRcnCIGGhZHt3fYGoBCBGGw8h
# +Jta0vrYFLzzVPWfsHIQzAKmyT1u/FzBba14G1A1qp3Fh2n/ovMBntuQx1K0Pk6p
# dg3l43j+wPIN+KTaH8uWm4is2o1MLAYGm0eLK94qcjahFSeKrq0czNJjXlvU4lOA
# hm7Bommd31NivNT6EbOBfWh2pQOXNKKVAe4wfVcR3VbSQxDaGW9JZ4p9kkC90Z7B
# la/3neIwPm76cXwopzjMpnstHs2mpFvfaHoZ/wXJNlzxgt8PlnWfch3rAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBS3SBdEnJiYpRhpxaP8hwPVPPlHiDAfBgNVHSMEGDAWgBSk
# Qwx/dlqlhec+jSgPDBeiRWlwxjBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwMy5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEAn1sB7M9NE6XiaAxFkmb0ZLl2cETch2I9y2lM/rkuUSTaly8b
# s7Izg8bSElSkxIdD+q6pq2ryFBF8vuleaj+QgMN/xeZn8gJhxs3WoFf4WAqvTGkP
# uszgOzir3ZAB3i1xp32306NWFO2dlcM2VA+joi4e9yKxgWy6/2P6ibIdyvZmEydD
# P/37TYkIWYrPYmWpw50maE1IijzhnsTzYeuA57+ca9tE0AqyitFVE0wSzz8lVXmv
# RS5qo2GjHOO0M4MRKGgdcE7sH03VA4UI6dvquK5RfpE/lproqX6sEcrktJ9E6WKA
# SptFPeZe+NMRHyTwsU/DOJms3j72mJtkZKTFPXtWHjhaDbYcD2DmCeyMbl0LZ5tA
# Xkf9u3L2MlIN5aep6PFEnVEfKYcQIoxbMoWPyUw59lhUYk1S1EuKoBUNXLjb0k0m
# 69nWnHE+ieliTIJzBtY5Lb2aaBOYFr+mqYcqOxyumxFmaW0V5Fkl9lKdUqjJ/9Uy
# WLUqxVNieL/2lT7tzG05dNl8sICKtCde4wiwx4nWRuPBEB70RwA1+vX4/da1BfN6
# cUc3mMA4hik7VhZOB570fhelDZjUvRLr3giggUp4HgdkUkiWtp87NFWQookf0Q3m
# Rw58rB3i8oVODX7kRMtoxSpcmV+tsDNkQVWZbFKSA8uPZCoRhaQO0LcIah0wggco
# MIIFEKADAgECAhMzAAAAGA3rkVWpigCYAAAAAAAYMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjYwMzI2MTgxMTMyWhcNMzEwMzI2MTgxMTMyWjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDAzMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAyIDaYDRWoon9lVnlj+SOj5xV8Sf5Qd+3yUeeRgr0exi2
# QTJAYo24ilcIKQSN8TOZ3+POM5x/6p3Cfjgqust44J0FvkfGXe1Puy45a5nLJGpc
# 0kNIITMRKZwVvPxx7NlfGSc0JOhz/kg7G77C+y3ZR/3jtpeJpJ4QwcK9Gf0Peuk7
# xLYeW/JAsY9b6oleGDbYSxkamUfbtnyv8gTFrvN6ejuLqNhHYPvoBHsOSC+7555y
# hapkof0fbzyct1hdWHGXsAFMfLF2TVJ8d2YVYOfZdi6YrT4sMxOhTKiLKmhL1Xtz
# M7hXdmv7lg2R+lWw8lIkSu/JiINQ0GAPcwxMsgRXDSPp8VUs4Jby+ruz0bjaoHFd
# 7H+hC8cPPcrEDP2eEdYURVl0acjliigCrXwR05NFJzYj3MZizDGLPI3lIzonX1T4
# 0yK8v1FcJ8MXZZCvOXGXwRDGGfwwTTsHaJj+OfWNZ/IsypG4bGvqeJcPnEFcQEwR
# cfYIEe/R4a8k+xw5qTy75CbwWeMFuAlt9lE9kjMg3tvJyDlN5voXx5VXinCwUHMp
# uVaEQ4yHAlSO7qoBltjzTBNHH3ovMwsAsuhwrLLCVhUu3oP2GxYZwEyXMlnzK5Db
# gGzHzDfDaYPHK0uo1VaMMg9Bhuc3YIvrkFXEiv+t/JgNcRGCt6ZyKEIDtPbrgwcC
# AwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUpEMMf3ZapYXnPo0oDwwXokVpcMYwVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcw
# AoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIx
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEAcccgVvl+poXUYksA/TzDFnBlAJ8ef0FM
# Jzb2XRRhF/uA0QyK/VgoeAvO8B7cPpYNQ97sytdA7LT19CxSwRQAt71jGF+CJl8K
# C4aEdMZTfJlHaKyd24J6QiVriNed9WdawsD7lK0pAcXziBg5N6dhAm9x6P8R4uT0
# UkfzlK1rkB8F4mlzE7l7tyES3s8FZGaRZjcGEQ+e0fTcdhf8jO7czmNB4dIRgmmB
# Ct/P+ha0tEl2nV1sg1An5+VzhgAkY1Apx8fiUFBtH+Ehw/om5aQCNIJfmR51ZnV1
# 8R02Xk2tAmAiIRcSj9vdtrNIOsy5nolddy1lJrbf1Be061l6TItv9FDZ4mg6B+65
# zxkVecVV/Ll8uLGYouGrMM6jzO2O/ps3K2p6mfBI2ZOYIy4UNwNrGWqa5TrvAmkZ
# sn3CIlR+81X4AL5vNTFlxc4gH+5su0Dr58hBTxnXavDEnz7X0csP1Kt7h+iqaGiT
# SHz2B+n3HmUoud0WrdQPYKxMat0To4YUqU3HIbgSLQDDVT8aCjW1Jvokf1915C/v
# VkIIp48h3voVy3JWPLwBlxQ9aeND6jCKQGLJhCQRSlvXX+P/9TeaEA6/xWPSASZf
# 6Ekve/Yua7U+zWc/Sr2K2gj0QRrNEAsvrFr4EGtHKDO9ECVS3lcJksVDv9KHdMPU
# K8u20i68RqAwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
# SIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJpZmljYXRp
# b24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMTA0MDEyMDA1
# MjBaFw0zNjA0MDEyMDE1MjBaMGMxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xNDAyBgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmll
# ZCBDb2RlIFNpZ25pbmcgUENBIDIwMjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQCy8MCvGYgo4t1UekxJbGkIVQm0Uv96SvjB6yUo92cXdylN65Xy96q2
# YpWCiTas7QPTkGnK9QMKDXB2ygS27EAIQZyAd+M8X+dmw6SDtzSZXyGkxP8a8Hi6
# EO9Zcwh5A+wOALNQbNO+iLvpgOnEM7GGB/wm5dYnMEOguua1OFfTUITVMIK8faxk
# P/4fPdEPCXYyy8NJ1fmskNhW5HduNqPZB/NkWbB9xxMqowAeWvPgHtpzyD3PLGVO
# mRO4ka0WcsEZqyg6efk3JiV/TEX39uNVGjgbODZhzspHvKFNU2K5MYfmHh4H1qOb
# U4JKEjKGsqqA6RziybPqhvE74fEp4n1tiY9/ootdU0vPxRp4BGjQFq28nzawuvaC
# qUUF2PWxh+o5/TRCb/cHhcYU8Mr8fTiS15kRmwFFzdVPZ3+JV3s5MulIf3II5FXe
# ghlAH9CvicPhhP+VaSFW3Da/azROdEm5sv+EUwhBrzqtxoYyE2wmuHKws00x4GGI
# x7NTWznOm6x/niqVi7a/mxnnMvQq8EMse0vwX2CfqM7Le/smbRtsEeOtbnJBbtLf
# oAsC3TdAOnBbUkbUfG78VRclsE7YDDBUbgWt75lDk53yi7C3n0WkHFU4EZ83i83a
# bd9nHWCqfnYa9qIHPqjOiuAgSOf4+FRcguEBXlD9mAInS7b6V0UaNwIDAQABo4IC
# NTCCAjEwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQW
# BBTZQSmwDw9jbO9p1/XNKZ6kSGow5jBUBgNVHSAETTBLMEkGBFUdIAAwQTA/Bggr
# BgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1Jl
# cG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB
# /wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZmAQHJ89QEE9oqKIwgYQGA1Ud
# HwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENl
# cnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcmwwgcMGCCsGAQUFBwEBBIG2
# MIGzMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJv
# b3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjAuY3J0MC0GCCsGAQUF
# BzABhiFodHRwOi8vb25lb2NzcC5taWNyb3NvZnQuY29tL29jc3AwDQYJKoZIhvcN
# AQEMBQADggIBAH8lKp7+1Kvq3WYK21cjTLpebJDjW4ZbOX3HD5ZiG84vjsFXT0OB
# +eb+1TiJ55ns0BHluC6itMI2vnwc5wDW1ywdCq3TAmx0KWy7xulAP179qX6VSBNQ
# kRXzReFyjvF2BGt6FvKFR/imR4CEESMAG8hSkPYso+GjlngM8JPn/ROUrTaeU/BR
# u/1RFESFVgK2wMz7fU4VTd8NXwGZBe/mFPZG6tWwkdmA/jLbp0kNUX7elxu2+HtH
# o0QO5gdiKF+YTYd1BGrmNG8sTURvn09jAhIUJfYNotn7OlThtfQjXqe0qrimgY4V
# poq2MgDW9ESUi1o4pzC1zTgIGtdJ/IvY6nqa80jFOTg5qzAiRNdsUvzVkoYP7bi4
# wLCj+ks2GftUct+fGUxXMdBUv5sdr0qFPLPB0b8vq516slCfRwaktAxK1S40MCvF
# bbAXXpAZnU20FaAoDwqq/jwzwd8Wo2J83r7O3onQbDO9TyDStgaBNlHzMMQgl95n
# HBYMelLEHkUnVVVTUsgC0Huj09duNfMaJ9ogxhPNThgq3i8w3DAGZ61AMeF0C1M+
# mU5eucj1Ijod5O2MMPeJQ3/vKBtqGZg4eTtUHt/BPjN74SsJsyHqAdXVS5c+ItyK
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakDCC
# GowCAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENB
# IDAzAhMzAAEWi3g6g8Ba7npPAAAAARaLMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIHoON2Q22CdQVPNfhtI64ewt/Y4pbcILsuOeT+tBtTErMA0GCSqGSIb3
# DQEBAQUABIIBgE4h/Gc4wfiQhYbizzfONWZ7ukYeXqlEy0rDhGI2bjzqj53TycG0
# 9iXVayq+V8SfMhHv+5+5UB9w6AyeGFgokjvhYGc34kmGG3E2BbzQGrS4avWjmP5D
# DpjXRL9z1BTQMVvIisfPV4BxKBKvPEbv5fhMb6aetOECb6mASOplddZ2IvPe1pYP
# 4Vq75dwFppaT7sQxpmZI3jG6Nzmgy3r1YOaVUFAliL1497AryyzMjyLsUwKebfZ/
# cn3wda9DtU3+PpECMA8VjSUf3kX8I1LJ8/nRnjtdJ/avavmrjg6GgPn4r8LOnz3x
# AJvyybJlSuBSx24HsUKKqrRleztSUqisskDU71JNXI3Hz6meADK45qpY+6kozWIx
# dqbhQHEPJ692xq/s7eled4fE+4OA6/ztkVyqMtThsEH5BPrqu/60NpK+gB3dTY6G
# 9WzMY9tx2wijDBL64ZwmWNziLQkd95H2ZNNlJ1JuQDNyF2Q/KA6C9AVbJ7S7PhBp
# ASmdHVNAX9q6kKGCGBAwghgMBgorBgEEAYI3AwMBMYIX/DCCF/gGCSqGSIb3DQEH
# AqCCF+kwghflAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFhBgsqhkiG9w0BCRABBKCC
# AVAEggFMMIIBSAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCD72M/3
# svjxGcrr2u1A9HjQeV62zAxuDK3jaeHYRboEFQIGaedYhdwhGBIyMDI2MDUxNjE5
# MjE1Ni4wNVowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlv
# bnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAtRDk0NzE1MDMG
# A1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3Jp
# dHmggg8hMIIHgjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAABTANBgkqhkiG
# 9w0BAQwFADB3MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMUgwRgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVyaWZpY2F0aW9u
# IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAxMTE5MjAzMjMx
# WhcNMzUxMTE5MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBU
# aW1lc3RhbXBpbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBAJ5851Jj/eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBvf7KrQ5cMSqFS
# HGqg2/qJhYqOQxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDsfMuIEqvGYOPU
# RAH+Ybl4SJEESnt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbBT7uq3wx3mXht
# VmtcCEr5ZKTkKKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5EeH5KrlFnxpj
# KKTavwfFP6XaGZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6ovnUfANjIgM9
# JDdJ4e0qiDRm5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fjJHrmlQ0EIXmp
# 4DhDBieKUGR+eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOsRpeexIveR1MP
# TVf7gt8hY64XNPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiunhKbq0XbjkNoU
# 5JhtYUrlmAbpxRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE3oWsDqMX3jjv
# 40e8KN5YsJBnczyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8cIxLoKSDzCCB
# Ou0hWdjzKNu8Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMBAAGjggIbMIIC
# FzAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFGtp
# KDo1L0hjQM972K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUF
# BwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3Np
# dG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBT
# AHUAYgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmY
# BAcnz1AQT2ioojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3Nv
# ZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmlj
# YXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNy
# bDCBlAYIKwYBBQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIw
# VmVyaWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIw
# MjAyMC5jcnQwDQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXnTHho+k7h2ESZ
# JRWluLE0Oa/pO+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC2IWmtKMyS1OW
# IviwpnK3aL5JedwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5zyEh89F72u9U
# Iw+IfvM9lzDmc2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbNnCKNZPmhzoa8
# PccOiQljjTW6GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqst8S+w+RUdie8
# fXC1jKu3m9KGIqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVmoNR/dSpRCxlo
# t0i79dKOChmoONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRSSvijmwJwxRxL
# LpMQ/u4xXxFfR4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7vPKNMN+SZDWyc
# U5ODIRfyoGl59BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/26ozePQ/TWfNX
# KBOmkFpvPE8CH+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/AAxw9Sdgq/+r
# Y7jjgs7X6fqPTXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSOiUIr0Xqcr1nJ
# fiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFck05XgounJMQAAAAAAVzAN
# BgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTNaFw0yNjEwMjIyMDQ2NTNa
# MIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046NzgwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJs
# aWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAsWylCpMIfbizJLY1kPXO2cmX2HRWvRbAmeKSZ5ex7/jC
# ymdV7Eap+Ic2iqRtWDkKKe5gL6JV80wtn5C2qHJLPxUYFKNG3UkHkAI21MoCN+YW
# nhT8K/YuPib6+6970jdbeFKIiZMWwd5hnpX9J3jeteuEdXbp/DfFBK15JuD3JOzW
# uF2suQCPgqYjQPk/gpq+3KCKtXJRbXSCSJ9YtITU2IHwmfdE7l2PfZ154w041po+
# fDeTj0gJOzcV/Jv56Q0M+w19jAKo/I5PEzrLV1IPQnmP4or1X4RbJXk8ONXyOOfX
# OxK2VLpNxgklK1yAezbFP2uzqihaXkW1h9GQLGENKESnezwgdRaLNNaYtm8AT/pZ
# HYJ35mZVqkZdMIckpQHJk/F1fSLyDKeKtH4TC4cc3ESKUMgItq07ZZm74JCsfhmr
# Q1ijVNDi1Sln+QBamgC7WviZbkQnceQRq9DY+6hANwOrasAZUiVr2kPuj1jHDOXz
# UG4O9QTK70P/oXSqZAN1oTv3UfF8JTGmAxg+l1ZPOz50MY96HBDw/3bI/wBGNvLk
# 6fLVnrxGN5B5unF/lYvjjWbIUdyBPVQnPOKXu08SRHbY19M1HoWX6PNZv+vzSeqV
# eWWHKdKjC3GjVjbbGpi+JLbiyaKRSwEqo49tJLvu69cQ7dWsbksai4TURnVj2mMC
# AwEAAaOCAcswggHHMB0GA1UdDgQWBBSOg8leLTUOAglIZ+bjXpiD7RKSpzAfBgNV
# HSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6Bdhlto
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQ
# dWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsG
# AQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3Rh
# bXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAww
# CgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGC
# N0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEM
# BQADggIBAHJ1wHY86Zk5SUBDPY25d/u9YJVaaNa71uxjX4cyO/XJ4uPENCSOwkRT
# nNogPLxTD0Fg3z4TFf/2T/0IFSxdtWVtTjhzrn+WLInzeRawUhTCFVrPBJKEWVsh
# m+Ig7/nB7JbJN88+ltImBbL5kT1StBLfG6UksAcDbNSQww90CUXhGueBxlnSvjkA
# X1ohiN16y1bB2s0rvQx8Csepl2CuBefTfDrMGzW/tzNx5YaK2D8OWweqTWZcGlJO
# 4YjZNI83cTrQghfHl/8AXOHj8cWL3wEFltQQs2xeRYAb3Kdnl7oIWKKXWaBYJY5P
# 3QPsiC+DTMp7ejdYKTrb396f3gr+wL/Ms5/Z3vIWZPJJv18qNw40fUNveRnwzMQn
# x8dM2bGuXXQZ5y7P8aXT4HJMo349qZtn4XQwiUE/DDp++MUL0kgjvd/Deo7Xr371
# PFPPYb4TboZhjV1x9+wCHDoOpNCBt+VuXU78ytJdKzQ1Jv2cEP1F9H9/wSLsMDUv
# WME7u9mGElOPDZPMVr8AuBEuLdbTSEdaLwsZBplzxLBcgxhZ/Cs30yBhuE3QhqT1
# YDZ2pa56RexPA2SasPcToT6gJgJ6E06BmZ2zQTNvWOjs5XQqHbYuXcoeDcwe2UaC
# 7EDOGD8GmLE9LiqtQsuQCM7v7I2xR+sPZT2Ax/85HjIkM+3MzTK1MYIHQzCCBz8C
# AQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMAITMwAAAFck05XgounJMQAAAAAAVzANBglghkgBZQMEAgEFAKCCBJww
# EQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAc
# BgkqhkiG9w0BCQUxDxcNMjYwNTE2MTkyMTU2WjAvBgkqhkiG9w0BCQQxIgQg1nmI
# k/3qQSxqxUTu9jzlZETlyf1vdT51n3kNuZhnq7cwgbkGCyqGSIb3DQEJEAIvMYGp
# MIGmMIGjMIGgBCD1PJ9ktQVuTGWIbKLO4f1VUOlUU29ARCEpDZmFTHjbUjB8MGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFck05XgounJMQAAAAAAVzCCA14GCyqGSIb3DQEJEAISMYIDTTCC
# A0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5
# NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcg
# QXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD9LzE5nEJRAUE2Ss3xaKKPXHnLw6Bn
# MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2yzEkwIhgPMjAyNjA1MTYxMDU4MTda
# GA8yMDI2MDUxNzEwNTgxN1owdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA7bLMSQIB
# ADAHAgEAAgI2WzAHAgEAAgIS/DAKAgUA7bQdyQIBADA2BgorBgEEAYRZCgQCMSgw
# JjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3
# DQEBCwUAA4IBAQAXlcEEjwpn5MwfZ5NQAYVyyDzWQTzoUJEUn9J5l9H8AmJeFs5p
# f2huSst9fpxsrnZXaZpXtYkGpspo4ouM3uIU9yPzjn7WXS2k5m/weueGE4D6hDLP
# 3cydF1gtcgroqxSgZJ53qHbiCvNNqFi6ULDkAN/hcfVNj3IrFuSkMuUg3As6FTWL
# Ih4yIIBvp2J/bBIYeqKAIPWrvdUalORR6b6yWQGgrK6NNs1Qnr+GCNFI8fgQzoYN
# vG4wZGixx6kjbhTxhcs+qW74TWWmr+SJXjguaVsai30rAkZt3i5b0rs/p/fvUj/N
# mE6dN5n+rSdTPyFmQZshSbtBwFAHSIA1ZfsAMA0GCSqGSIb3DQEBAQUABIICADRy
# 0XfNtSL2A4Zsi1rXW9TA3cAcfOgdXU2+amHls5bQA6T6kha+fjrGBVxGOR+zfz8S
# DlBYrSyULFfzr1N9lB9FLl0V5moZocOwmr3jZSDlucM58lgwGldPx76eaVEjocoJ
# dmNrwVxMCdH7FPzYMxoOrdYs3kh3/RXSF1A7AHAnfCHQFT7Pz4BZNpgn0CurhgIE
# SN5YpkmK5TyDeSOPRkYyLQoIs0B45/kETNSmN9rhfUJ75x4UmGWPG+OopT+frsnw
# JLStMT/mIP8Iqi0U+IS4g6aGuzO1Tuhr+lGT19KCGifG9xpHSP+EHJrLG1sh0bSc
# EjcTgq4YZdwiPFI2iWDxj5qCvmq6A+L7UeBmD2Y7pt7vYo8/xSFFfiPDtCMMZTYC
# LjdwbB4uWsGWH3MEiIqLJ4I/dPnvsjsdQzeyOwZpK6inH0zSpAJ0pc8rqM0DVdGt
# ooHiLUUbfjfDdLVcHZJUbOz2jvMoPwxYRTUdA+uR6in/MeLkBe8wf3jmmOybl5be
# HL2ng8zzs2iV000WvsPGukp/aDcpOXYEFdPKBalr/ifpEpRgxQw50oYWFTumADRR
# u5rEEeiFMlPaMw4GceZZHtAgLAr2yOWwiWD311OinEdcYlzoGVVF7IJpeTd3DhSc
# FAyMuJlx/CV6jVF6DURGxghrVZBLXoKj574nbT9v
# SIG # End signature block
