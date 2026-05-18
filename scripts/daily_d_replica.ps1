# daily_d_replica.ps1 -- Daily mirror of D: to the 8 TB external (E:).
#
# Single-tool design: VSS shadow of D:, then one rustback-mirror.exe invocation
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
    [string]$AppId           = 'RustBack.HealthCheck',
    [string]$LaunchProto     = 'rustback:open',
    [string]$BackupMirrorExe = 'C:\dev\rustback\target\release\rustback-mirror.exe',
    [string]$ManifestRoot    = 'C:\RustBackMirror\manifests',
    [string]$BackupMirrorLogRoot = 'C:\RustBackMirror\logs',
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
    <action content="Open RustBack" activationType="protocol" arguments="$launch" />
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
    bytes           = 0           # sum of bytes_written across all rustback-mirror invocations
    files           = 0           # sum of files_total across all rustback-mirror invocations
    errors          = 1           # default fail; cleared on PASS path
    duration_s      = 0
    robocopy_rc     = -1          # worst exit code across all rustback-mirror invocations (legacy field name preserved for rustback-dump compat)
    chunks_changed  = 0           # sum of chunks_changed across all invocations
    chunks_total    = 0           # sum of chunks_total across all invocations
    shadow_id       = '-'
    tool            = 'rustback-mirror'
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

    # ---- Phase 2: rustback-mirror chunk-CBT (replaces cwRsync, kopia-bmy.3) ----
    # Single tooling for the whole D: -> E: mirror. One rustback-mirror invocation
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
    # (e.g. the Win11 ISO at D:\ root) are mirrored via rustback-mirror's
    # single-file cbt mode (kopia-2ls); pagefile/swapfile/hiberfil and
    # similar Windows transients are excluded explicitly.
    #
    # Each invocation writes its own progress JSONL and a summary line on
    # stdout. We aggregate the per-tree CBT stats into the replica summary.
    $bmExe = $BackupMirrorExe
    if (-not (Test-Path -LiteralPath $bmExe)) {
        throw "rustback-mirror.exe not found at $bmExe -- run cargo build --release in C:\dev\rustback"
    }
    $bmSig = Get-AuthenticodeSignature -LiteralPath $bmExe
    if ($bmSig.Status -ne 'Valid') {
        throw "rustback-mirror.exe signature is not Valid (Status=$($bmSig.Status)) -- run signing\sign-all.ps1"
    }
    Write-Log "rustback-mirror.exe: $bmExe (sig=$($bmSig.Status))" 'mirror'

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
    # transient state with ACLs that deny even via VSS shadow. rustback-mirror
    # has no --exclude flag, so hitting one of those files would abort the
    # Sysmon subtree mid-run. Skip the whole subtree until rustback-mirror
    # gains per-file-skip semantics. Sysmon is local telemetry, regenerable.
    # Excludes apply to both directories and top-level files: Recycle Bin and
    # Volume Information are NTFS system; RustBackIndex is a known
    # local-state dir; Sysmon is open-file transient that rustback-mirror
    # can't safely mirror without per-file-skip semantics. File excludes
    # catch pagefile/swapfile/hiberfil if D: is ever configured as a paging
    # target.
    $EXCLUDE_TOP = @(
        '$RECYCLE.BIN', 'System Volume Information', 'RustBackIndex', 'Sysmon',
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
        # nightly dated-folder rotation). But rustback-mirror still computes
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

        # USN journal tracking. Two subtrees benefit, with different
        # semantics:
        #   WindowsImageBackup (kopia-61n): byte-range mode. NTFS USN V4
        #     records describe which byte ranges of the multi-TB VHDX
        #     were modified since the prior cursor. Default mode (no
        #     --usn-assume-clean-on-unknown). Files unknown to the
        #     journal force a full hash pass.
        #   KopiaRepo (kopia-1tr): file-level mode. Kopia pack blobs are
        #     write-once -- once recorded in a manifest they never
        #     change. Most files have NO modification record in any
        #     given cursor window. --usn-assume-clean-on-unknown lets
        #     mirror_file treat such files as fully clean (Some(empty))
        #     instead of full-rehashing them. Trust-gate (kopia-8j4) is
        #     still mandatory; size/marker checks always run first.
        # Other subtrees (Accounting, Backup, KopiaServer) stay on the
        # chunk-CBT-only path; they're small enough that chunk hashing
        # alone is fast.
        $usnStateDir = $null
        $usnFileLevel = $false
        if ($treeName -eq 'WindowsImageBackup' -or $treeName -eq 'KopiaRepo') {
            $usnStateDir = Join-Path 'C:\BackupMirror\state' $treeName
            if (-not (Test-Path -LiteralPath $usnStateDir)) {
                New-Item -ItemType Directory -Path $usnStateDir -Force | Out-Null
            }
            $argList += '--usn-journal-state', $usnStateDir
            $argList += '--usn-volume',        'D:\'
            if ($treeName -eq 'KopiaRepo') {
                $argList += '--usn-assume-clean-on-unknown'
                $usnFileLevel = $true
            }
        }

        $usnTag = if ($usnFileLevel) {
            ' usn=file-level'
        } elseif ($usnStateDir) {
            ' usn=byte-range'
        } else {
            ''
        }
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
        #   "rustback-mirror summary mode=cbt files_total=X files_first_run=Y
        #    files_torn_recovered=Z chunks_total=A chunks_changed=B
        #    chunks_zero=C bytes_read=D bytes_written=E duration_s=F errors=G"
        $bytes = 0; $files = 0; $chunksTot = 0; $chunksChg = 0
        if (Test-Path -LiteralPath $summaryOut) {
            $sumLine = Get-Content -LiteralPath $summaryOut -Tail 5 |
                       Where-Object { $_ -match '^rustback-mirror summary ' } |
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
        throw "rustback-mirror failed on: $failedTrees (worst rc=$worstRc; per-tree logs in $runLogDir)"
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
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBsiJJB5Kzj/cSx
# qHIgoNHUK6hyHTFtAS12CeNDjpJ5qqCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAEbpT23
# Yw7F5+AAAAAAARulMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNTE3MTc1MjA1WhcNMjYwNTIw
# MTc1MjA1WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAlWLeiE2g4vYKf+T9Rp9B
# +58RoVqJHGeZ/7YLJYS5f1eALYG5bR5YYvCBrue7CooeKcf78Lz6dXJcObh/x7jv
# K3xufvU/45+GNwBtjxPG5AVlCT7+ouvsXtY6WTlvb5EryX94tkQiH59h+ZWWjYX3
# fQYKPsJp4lo4vaPXmIMaBZh5nDrurqqy9UYUGt2tKJFffJlGcqIdkt/pOSjLpSyS
# Cke+RbRfU48nf7RQgMgltJHvHx2dST62RTt7w4r4kOhowfSox4yh4dN2hcjYyWwP
# W5f37WkfCRkhmK8kNgmTmJ9Fquo4iar2wyfo3HpXSNzTta2n2ffoB6zJ7nT+NZtC
# hytwFad0nKHJfRuEjDutYVf2ErpTtPThrWcpgO/D8QZxoITwX6mlp87DcsOtImbD
# 5kogmXxP4qF8ohchtcYwmCgG8i8uwFrchs5cg1+Zx5VSqj6juHtuf9qYeFATLh6t
# XNyxMoVE7IYFkxHtyEAIQIL9vf+JoqozE6QJkj4mionJAgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBTg01v1MUAC949+dyfm8AWyeDVr/TAfBgNVHSMEGDAWgBRrJUHe+2t8/RiA
# Ci1/j3ZdqnM9uDBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBBT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwNC5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEAs9BgZmwQlDkChDOY+s/yxaCPkubtjEtC4NE5aT5vtTsV0XrZyYKMOoCuIr7h
# futGVQX5flH69EpXgWcD34lxlcU6vjri02bDIJ5WXkvJKZqKAMXh7YGS7P0RFLrF
# dVU30QzkA70DJKz0ZkII9rvJqMDq4yOkTYm+iNVQ0CVTFN41YX2BYVQa7mD7yUsO
# MLK7TeOsqhttFCa7Fn1+SgPC3FtHF91UaL9G/Un3fVVYc3mWfSvuJZdszRce1BDD
# yBmu/KNf9Grby60zw2aP96OIXOF/FBmxywTLs0f/A5DG69H+NzwpJjbXzT22pfz4
# OZemjbyPJQDqF3i/XaLvenjXIVjYjid+iTGrYAwdB398J3JLompMm+NvCpwxyox1
# e735Jm+SvmM1I97ANa9r/dPlLHz7GqFO3TSm11P8x4gszlT1bjuMpHMvEj2++EiU
# bicLpWeUQuyA2IWZRjDdqNxwJtHRV569ADOR9ZNjolpjdVVv1dtSaGRWgF3Fs+vL
# gfOade+JRe/jMkqlmxy2H/jyVMRWS6i6e+JFbQ7NdlAY9nIV4mzXlek2ghvhgR33
# yKz5jvO6VUVHUl9d0RO/FGVTDgzPv4zYkvurPx2SgejvWNXKL0RvKwTADy8bqpti
# im/VESVLwgYy6uFi77JYhaxoD+r4rOxXoVAcvZwHvlha/8MwggbFMIIEraADAgEC
# AhMzAAEbpT23Yw7F5+AAAAAAARulMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNTE3MTc1MjA1
# WhcNMjYwNTIwMTc1MjA1WjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAlWLeiE2g
# 4vYKf+T9Rp9B+58RoVqJHGeZ/7YLJYS5f1eALYG5bR5YYvCBrue7CooeKcf78Lz6
# dXJcObh/x7jvK3xufvU/45+GNwBtjxPG5AVlCT7+ouvsXtY6WTlvb5EryX94tkQi
# H59h+ZWWjYX3fQYKPsJp4lo4vaPXmIMaBZh5nDrurqqy9UYUGt2tKJFffJlGcqId
# kt/pOSjLpSySCke+RbRfU48nf7RQgMgltJHvHx2dST62RTt7w4r4kOhowfSox4yh
# 4dN2hcjYyWwPW5f37WkfCRkhmK8kNgmTmJ9Fquo4iar2wyfo3HpXSNzTta2n2ffo
# B6zJ7nT+NZtChytwFad0nKHJfRuEjDutYVf2ErpTtPThrWcpgO/D8QZxoITwX6ml
# p87DcsOtImbD5kogmXxP4qF8ohchtcYwmCgG8i8uwFrchs5cg1+Zx5VSqj6juHtu
# f9qYeFATLh6tXNyxMoVE7IYFkxHtyEAIQIL9vf+JoqozE6QJkj4mionJAgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBTg01v1MUAC949+dyfm8AWyeDVr/TAfBgNVHSMEGDAWgBRr
# JUHe+2t8/RiACi1/j3ZdqnM9uDBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwNC5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEAs9BgZmwQlDkChDOY+s/yxaCPkubtjEtC4NE5aT5vtTsV0XrZ
# yYKMOoCuIr7hfutGVQX5flH69EpXgWcD34lxlcU6vjri02bDIJ5WXkvJKZqKAMXh
# 7YGS7P0RFLrFdVU30QzkA70DJKz0ZkII9rvJqMDq4yOkTYm+iNVQ0CVTFN41YX2B
# YVQa7mD7yUsOMLK7TeOsqhttFCa7Fn1+SgPC3FtHF91UaL9G/Un3fVVYc3mWfSvu
# JZdszRce1BDDyBmu/KNf9Grby60zw2aP96OIXOF/FBmxywTLs0f/A5DG69H+Nzwp
# JjbXzT22pfz4OZemjbyPJQDqF3i/XaLvenjXIVjYjid+iTGrYAwdB398J3JLompM
# m+NvCpwxyox1e735Jm+SvmM1I97ANa9r/dPlLHz7GqFO3TSm11P8x4gszlT1bjuM
# pHMvEj2++EiUbicLpWeUQuyA2IWZRjDdqNxwJtHRV569ADOR9ZNjolpjdVVv1dtS
# aGRWgF3Fs+vLgfOade+JRe/jMkqlmxy2H/jyVMRWS6i6e+JFbQ7NdlAY9nIV4mzX
# lek2ghvhgR33yKz5jvO6VUVHUl9d0RO/FGVTDgzPv4zYkvurPx2SgejvWNXKL0Rv
# KwTADy8bqptiim/VESVLwgYy6uFi77JYhaxoD+r4rOxXoVAcvZwHvlha/8Mwggco
# MIIFEKADAgECAhMzAAAAFjGSjZICZXuaAAAAAAAWMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjYwMzI2MTgxMTI5WhcNMzEwMzI2MTgxMTI5WjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDA0MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAylX6yNvoCTDP9G0OTlSjXbzgEsy21FDL17n/lZe2BrqH
# z2mR1aN4DBxeYp0/hjEqSHHyGfarV1NVBuvK8vLzW0LTi+DZt9In16aiNfgcogFi
# ztWE9Fp8xu1zzrqE3nlrDWb+RZo8QrEXgWb8s8swsl2W7tREHycVkx+Hm1MLQIlv
# a6jH/Xg4/8GIYhHzbXiVd2RXomw9s7Qh6/SYRXXfe125wh4EKEyKnNNl+cZUSrVB
# gWvvjrRwQY4if7sAZ805KruBY6WY0Hiba5nWvrq9Qk9o35ViAf8qZ+7u1fbb1vcC
# WyWLfx9hLSdBjjVsSWe0xLvI1j4p3Tjt5czz+1Lc0v5lQ1feB7nFmpbZrK2us0hv
# AaBCfOyDPEEm+735vzuNRYWJFL/PViI+REtjuJMcojEn3veQjIrwrmK0T9oSr8e3
# oDzK1oAwwZMTC4KymTvYUTVDJvL5N8OW/UqIBzsiVYcchZvGhV3yMYKgxeEtIOG4
# W4Z85Y5kpQi5bpjGXFxRg46RdrTaALt1RhRmLR7U0jVSr2aYAd2+Mp2qA5Gz3/lo
# OOdt47eFZ3mrAYGYQtbK2SNjQpwgQX4Iy6tOKahCgFhKIcltitvSkpJB77eVWhNW
# nN2LfqMojszEue7V8EAySxry4PzlxTtFTb3Mw53XyH12BMQf2m9j7jEsHeVSATsC
# AwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUayVB3vtrfP0YgAotf492XapzPbgwVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcw
# AoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIx
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEABtVQXlR01UQZY5XGQ9yIjMcD8jI0MizW
# hJ1buZjg5toUQSXx/BrASwE5qxwHPBeO45pOQp6VD4iILgm8OmfylY+A7KIqttvD
# UizC3sBXxjK4u7sDRiyEguXHKfL1HQAwxCLEtnRPkCPTsJA6b917lA+3foQIHC1X
# DDpdQLHxGbbGXp4Rr0mFK5vxbi6tAahBi/RlzOXPh6PavKPlZ/0vhlkDdsvoJETt
# ebNJCNOZ1Kav3Tg+K4va4FbOrYqRHdGGahoA/gmTYmmVqw0zkGzT53HdhfajrFGt
# tJomK7qE+T8CQGiPkEIkxNmSXjCTpDqc4U1IKlTGcGYnRFGSgqrnWnkANPFsJ5ED
# Hysh82lPI+PFC3FOIVMLzLL+30rqznvRgHUUAj7xfFnEiuaAx3vFVSTOLb+iigpv
# dR6i8fSWpgYESOkdkn2N57tuhBs57tKwoP++vc/MVpuD1XAtmWi+lZSlahadTbDf
# GKjMn+bfm2xlW9PZ6BSnCRv1MMhpcUZkAZX3gVEMef8rZc2c7BJ4ayRfX0wH43vI
# 9znV+ZRJ3j0xUC0Zb82RQalF5yHkCr93x0IwvZtn6P2dNQyCP6qd3fC4RlVFtAQh
# tOH0cByTR/Iqqghv6qHzL/pMptgMQQ5x8zYEYy+tCThYgYIrq7y4WEDYQfeSlqIx
# QOrIUJ4IJDEwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
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
# IDA0AhMzAAEbpT23Yw7F5+AAAAAAARulMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIMbfUbGPsKqZPfHnR7X261kWrE/pzSe2/asleswpZtl9MA0GCSqGSIb3
# DQEBAQUABIIBgERSRjTzVERq5DVLO0iMn9gL8ta09h5lDbVF1k3rQAfyUKRklTTo
# fb+L5X/tZmoXX2bLWO3OezPYWZ0Uq4hO+7/2bLHaJz+TDp1EafrRrrwsjQMNqBTS
# sydaPHgmOYE06uLSmSESe7GiLkkuMQmExm5Kup99HPwhGVUUtz1WTU3NlRUrAWBf
# DjKt/7+LghuqJkNC0f9uapE8Azv0bLH8ExSse/rud5GxP8t/LEKzau86iCn3vqGI
# f74ieYhVZGhuhyAPBmCiRz5DRVMxFPkKT5Z3hDQn/7OQ8LRPNvcMUOcBfEni8MPj
# uRiUY1oDyTz94sbfkxk7DqfSSbQ6Cks+Xa3KrkE+9EYHx0ISGSUBnjmEoyiQlZPA
# Ln5LEcVfBwoZm9C3PmC7Lvn9UnS2B/j4olbCAGymrnGhqtHer0yj2WlqsQDr69YB
# QbJ4YZSs9Oj7hv9wwKAoy4Fh53uf2iB2pKm23jaDp6n7upkp5wn/E6Z4p6p96crU
# NjhfCJvFK96HIKGCGBAwghgMBgorBgEEAYI3AwMBMYIX/DCCF/gGCSqGSIb3DQEH
# AqCCF+kwghflAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFhBgsqhkiG9w0BCRABBKCC
# AVAEggFMMIIBSAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBiHF3w
# gColUuAYe+sN7+Y2RYB27ugtfQA9YrrcyPpHtAIGaeddpkX5GBIyMDI2MDUxODE1
# MDIyNS4wOFowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlv
# bnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNTAwLTA1RTAtRDk0NzE1MDMG
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
# fiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFZ+j51YCI7pYAAAAAAAVjAN
# BgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTFaFw0yNjEwMjIyMDQ2NTFa
# MIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046QTUwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJs
# aWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAtKWfm/ul027/d8Rlb8Mn/g0QUvvLqY2Vsy3tI8U2tFSs
# pTZomZOD3BHT8LkR+RrhMJgb1VjAKFNysaK9cLSXifPGSIBrPCgs9P4y24lrJEmr
# V6Q5z4BmqMhIPrZhEvZnWpCS4HO7jYSei/nxmC7/1Er+l5Lg3PmSxb8d2IVcARxS
# w1B4mxB6XI0nkel9wa1dYb2wfGpofraFmxZOxT9eNht4LH0RBSVueba6ZNpjS/0g
# tfm7qiIiyP6p6PRzTTbMnVqsHnV/d/rW0zHx+Q+QNZ5wUqKmTZJB9hU853+2pX5r
# DfK32uNY9/WBOAmzbqgpEdQkbiMavUMyUDShmycIvgHdQnS207sTj8M+kJL3tOda
# hPuPqMwsaCCgdfwwQx0O9TKe7FSvbAEYs1AnldCl/KHGZCOVvUNqjyL10JLe0/+G
# D9/ynqXGWFpXOjaunvZ/cKROhjN4M5e6xx0b2miqcPii4/ii2ZheKallJET7CKlp
# FShs3wyg6F/fojQxQvPnbWD4Nyx6lhjWjwmoLcx6w1FSCtavLCly33BLRSlTU4qK
# Uxaa8d7YN7Eqpn9XO0SY0umOvKFXrWH7rxl+9iaicitdnTTksAnRjvekdKT3lg7l
# RMfmfZU8vXNiN0UYJzT9EjqjRm0uN/h0oXxPhNfPYqeFbyPXGGxzaYUz6zx3qTcC
# AwEAAaOCAcswggHHMB0GA1UdDgQWBBS+tjPyu6tZ/h5GsyLvyz1H+FNIWjAfBgNV
# HSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6Bdhlto
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQ
# dWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsG
# AQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3Rh
# bXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAww
# CgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGC
# N0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEM
# BQADggIBAA4DqAXEsO26j/La7Fgn/Qifit8xuZekqZ57+Ye+sH/hRTbEEjGYrZgs
# qwR/lUUfKCFpbZF8msaZPQJOR4YYUEU8XyjLrn8Y1jCSmoxh9l7tWiSoc/JFBw35
# 6JAmzGGxeBA2EWSxRuTr1AuZe6nYaN8/wtFkiHcs8gMadxXBs6DxVhyu5YnhLPQk
# fumKm3lFftwE7pieV7f1lskmlgsC6AeSGCzGPZUgCvcH5Tv/Qe9z7bIImSD3Suzh
# OIwaP+eKQTYf67TifyJKkWQSdGfTA6Kcu41k8LB6oPK+MLk1jbxxK5wPqLSL62xj
# K04SBXHEJSEnsFt0zxWkxP/lgej1DxqUnmrYEdkxvzKSHIAqFWSZul/5hI+vJxvF
# PhsNQBEk4cSulDkJQpcdVi/gmf/mHFOYhDBjsa15s4L+2sBil3XV/T8RiR66Q8xY
# vTLRWxd2dVsrOoCwnsU4WIeiC0JinCv1WLHEh7Qyzr9RSr4kKJLWdpNYLhgjkojT
# mEkAjFO774t3xB7enbvIF0GOsV19xnCUzq9EGKyt0gMuaphKlNjJ+aTpjWMZDGo+
# GOKsnp93Hmftml0Syp3F9+M3y+y6WJGUZoIZJq227jDjjEndtpUrh9BdPdVIfVJD
# /Au81Rzh05UHAivorQ3Os8PELHIgiOd9TWzbdgmGzcILt/ddVQERMYIHQzCCBz8C
# AQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjANBglghkgBZQMEAgEFAKCCBJww
# EQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAc
# BgkqhkiG9w0BCQUxDxcNMjYwNTE4MTUwMjI1WjAvBgkqhkiG9w0BCQQxIgQggORt
# 6J6TG/LNBB0RmCswO8Y5ZMmnxLutBGxLmvJZEOkwgbkGCyqGSIb3DQEJEAIvMYGp
# MIGmMIGjMIGgBCC2DDMlTaTj8JV3iTg5Xnpe4CSH60143Z+X9o5NBgMMqDB8MGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjCCA14GCyqGSIb3DQEJEAISMYIDTTCC
# A0mhggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTUwMC0wNUUwLUQ5
# NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcg
# QXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD/c/cpFSqQWYBeXggyRJ2ZbvYEEaBn
# MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO21dGgwIhgPMjAyNjA1MTgxMTIwMDha
# GA8yMDI2MDUxOTExMjAwOFowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA7bV0aAIB
# ADAHAgEAAgIoQjAHAgEAAgISdzAKAgUA7bbF6AIBADA2BgorBgEEAYRZCgQCMSgw
# JjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3
# DQEBCwUAA4IBAQA8tGu3L2LQ6UT0VDRKWHYeWepOTSZJyYXvD73nXeuHIsWmvMlX
# oP3oNA9c8ehRw+uYdci5rYTbXziIlGqEN6kcoOb+2v92pm4TPgRlvZkjTlVlnSlQ
# /CiJV7Q17vU3+BDgUk5GDRpvznZbJxAm6fnU9trRTPOMlpB0fhlkVCckC68GPXMl
# /70DwBd6x91do1hoY/48/YWLt/fws/aAplxdonPe+ePRwzIi5wrS9MTnioyQ040C
# nQEVXZJuWeo6Y42blZxJq7y59OXzhoRzY3++smaO1vh8Bi799L5QQuh30FpdIQLB
# B9A73VE+2OO3QVylmuakCZiUlz/Y56VhNkmQMA0GCSqGSIb3DQEBAQUABIICABCs
# YIjg1IyaYaq9CfRgf/Lr1o1zCpkHRS4mdT70HMXEpULWj85onVEm3J+25JuLAOpV
# Uyxay18UeUpbxlkzyrVB0yGl7Z3iPVnQN3hw3MvPf3brSDtL+Hox+Ap+SstAWE4s
# 2SKEiqsHHaUA3GaR5ifXMzkZftely8Ujk7ueOdjBQkGauPCmNw1kD5YFlh52pEij
# nWN4YM4i+un+7euT+3mNRTgDxbVFblsW9coZTLfgUQxElgeTiIT/1j+1fcmDNCCV
# wayWvGiyUgG+22/UurwcbmLIuGn6k5Lhetb+N7gYHWqNyEbovErC/wSdIOYSnB+k
# SflhHsak5Nk3Pz92u3G8r85T6Is9MzQZj2oqbZe2ubylDdv6oH4lB4+TDe60NOST
# OBalPOLs2X5DFZDYImB8Uz05Ifor3rxr2o8LbTSnYaTJtgl7pGDDNRellD5LvIcz
# 8MUUmgHLwfqLAT/4TsLQg6dhGKSKF5qM7A2RoEccGg93f3hvD0gAB2B/kGj7BpQo
# kxfw5i/zZosZM2TZF2KBcba13MbdDhwS5WYl75XXj64GoeJqZ9yy9iiL0jatzLcM
# h7Ec/+2Fak27AIg9EBcPjSYhIkffkdbEU/hOJRnhgZe+P0z2rwmfhokgv+u04/t8
# VLUmiElhgKrmsVdUGEJQyRUalGdgM1IftVDueT9t
# SIG # End signature block
