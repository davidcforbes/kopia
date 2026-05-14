# daily_d_replica.ps1 -- Daily mirror of D: to the 8 TB external (E:).
#
# Single-phase design: VSS shadow of D:, then robocopy /MIR to E:. Kopia's
# blob format (write-once content blobs, atomic-rename indexes) means a
# file-level mirror taken from a VSS snapshot yields a valid replica repo
# openable with the same password. See plan
# C:\Users\david\.claude\plans\partitioned-jumping-sunrise.md and beads
# kopia-30c (the original Phase A using `kopia repository sync-to` was
# dropped -- sync-to is direct-mode only per cli/command_repository_sync.go).
#
# Scheduled daily at 05:00 by \Backup\DailyDReplica.

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
    [int]$HeartbeatStaleSec  = 300,
    [int64]$HeadroomBytes    = 50GB,
    [int]$RobocopyThreads    = 8,
    [int]$ProgressIntervalSec = 60,
    [int]$StallThresholdSec   = 600,
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

function Show-Toast {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Body
    )
    if ($InitialSeed) { return }   # interactive seed run: no toast
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument,                  Windows.Data.Xml.Dom,        ContentType=WindowsRuntime]
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
    param([Parameter(Mandatory)] [hashtable]$Fields)
    $parts = $Fields.GetEnumerator() | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }
    $line  = '{0} -- replica summary {1}' -f (Get-Date -Format 'ddd MM/dd/yyyy HH:mm:ss.ff'), ($parts -join ' ')
    Add-Content -LiteralPath $DailyKopiaLog -Value $line
}

function Get-PriorWbadminFolder {
    param(
        [Parameter(Mandatory)] [string]$WbadminRoot,
        [Parameter(Mandatory)] [string]$TodayName
    )
    if (-not (Test-Path -LiteralPath $WbadminRoot)) { return $null }
    Get-ChildItem -LiteralPath $WbadminRoot -Directory -Filter 'Backup *' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $TodayName } |
        Sort-Object Name -Descending |
        Select-Object -First 1
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
$progressJob = $null
$summary     = @{
    source          = $src
    target          = $dst.TrimEnd('\')
    mode            = $mode
    bytes           = 0
    files           = 0
    errors          = 1   # default fail; cleared on PASS path
    duration_s      = 0
    robocopy_rc     = -1  # aggregate worst exit code of both rsync calls (kopia-5ua compat)
    rsync_kopia_rc  = -1  # Tree A (KopiaRepo) exit code
    rsync_wbadmin_rc = -1 # Tree B (WindowsImageBackup) exit code
    link_dest_used  = ''  # path to prior wbadmin folder, empty if none found
    shadow_id       = '-'
    tool            = 'rsync'
}

try {
    # ---- Preflight: clean up orphans from prior hung runs ----
    # Any kopia-replica-shadow-* junction in TEMP is from a prior run whose
    # finally block didn't complete. Direct Remove-Item -- these are stale,
    # the underlying VSS shadows are usually long gone, so no hang risk.
    foreach ($om in (Get-ChildItem $env:TEMP -Filter 'kopia-replica-shadow-*' -ErrorAction SilentlyContinue)) {
        $path = $om.FullName
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Write-Log "removed orphan from prior run: $path" 'preflight'
        } catch {
            Write-Log "WARNING: could not remove orphan ${path}: $_" 'preflight'
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

    # ---- Phase 2: rsync delta-copy via cwRsync 6.4.8 (two-call split) ----
    # Replaces the original robocopy /MIR (kopia-5ua). Cygwin-runtime rsync.exe
    # reads the VSS shadow junction natively (no GLOBALROOT path hack), and
    # delivers block-level delta-copy semantics so a single block change in a
    # multi-TB wbadmin VHDX transfers ~MB instead of the whole file.
    #
    # Two-rsync split (kopia-0q9, Phase 1):
    #   Tree A: KopiaRepo + everything except WindowsImageBackup.
    #     Uses existing flags (--inplace --no-whole-file --delete-after).
    #     First-run baseline; incremental thereafter (dedup handles repeats).
    #   Tree B: WindowsImageBackup only, with --link-dest=<prior dated folder>.
    #     Wbadmin creates dated folders daily (Backup YYYY-MM-DD HHMMSS).
    #     Yesterday's folder is the per-file basis pointer; --inplace writes
    #     deltas in-place, --no-whole-file uses rolling-hash. Unchanged blocks
    #     become hardlinks (zero disk cost). Expected wall time <90min vs 5-6h
    #     baseline; transferred bytes <50GB vs ~1TB baseline.
    #
    # Flag rationale:
    #   --recursive --links --times      Match robocopy /COPY:DAT (data + times,
    #                                    not perms/owner/ACLs -- target ACLs are
    #                                    intentionally locked). Deliberately
    #                                    avoid -a because the cygwin runtime
    #                                    synthesizes POSIX perms from NTFS ACLs
    #                                    and -a would push them.
    #   --inplace                        Update file blocks in place; no temp+
    #                                    rename which would defeat delta match.
    #   --no-whole-file                  Force delta algorithm even on a local
    #                                    copy (rsync defaults to whole-file
    #                                    when both endpoints are local).
    #   --delete-after                   Mirror semantics (= robocopy /MIR).
    #                                    Swapped from --delete (--delete-during)
    #                                    so --link-dest basis files on E:
    #                                    survive long enough to match.
    #   --link-dest=<prior dated folder> (Tree B only) Concrete per-file basis.
    #                                    Unchanged blocks hardlink to prior
    #                                    dated folder; changed blocks delta-ed.
    #   --info=stats2,progress2          End-of-run stats + periodic progress.
    #   --log-file=...                   Dedicated log so the watcher can tail.
    #   --exclude ...                    Same set as robocopy /XD + /XF --
    #                                    Sysmon .sdb-wal/.sdb-shm are open-file
    #                                    transient state (ACL denies even via
    #                                    VSS shadow), rest are rebuildable.
    $rsyncBin = 'C:\cwrsync\bin\rsync.exe'
    if (-not (Test-Path -LiteralPath $rsyncBin)) {
        throw "rsync.exe not found at $rsyncBin -- run scripts/install_cwrsync.ps1"
    }
    $rsyncLog = "$LogFile.rsync"
    if (Test-Path -LiteralPath $rsyncLog) { Remove-Item -LiteralPath $rsyncLog -Force }

    # rsync.exe is a cygwin-runtime binary and expects POSIX paths. Convert
    # Windows -> cygdrive form:
    #   'C:\Users\david\AppData\Local\Temp\kopia-replica-shadow-{guid}'
    #     -> '/cygdrive/c/Users/david/AppData/Local/Temp/kopia-replica-shadow-{guid}'
    #   'E:\' -> '/cygdrive/e/'
    function ConvertTo-CygPath {
        param([string]$WinPath)
        $p = $WinPath -replace '\\', '/'
        if ($p -match '^([A-Za-z]):(.*)$') {
            $letter = $Matches[1].ToLower()
            $rest   = $Matches[2]
            if (-not $rest) { $rest = '/' }
            return "/cygdrive/$letter$rest"
        }
        return $p
    }
    $srcCyg = (ConvertTo-CygPath ($shadowPath.TrimEnd('\'))) + '/'
    $dstCyg = (ConvertTo-CygPath ($dst.TrimEnd('\')))         + '/'

    # Spawn a background watcher that emits [progress] lines and flags stalls.
    # Polls $ProgressIntervalSec; if neither write rate, E: usage, nor the
    # rsync log file grows for $StallThresholdSec, the line is tagged STALL.
    # Watcher does not kill rsync -- operator decides via Get-Content $LogFile.
    # Both rsync calls write to the same $rsyncLog, so the watcher spans both.
    if (-not $DryRun) {
        $progressJob = Start-Job -ArgumentList $LogFile,$rsyncLog,$dst.Substring(0,1),$ProgressIntervalSec,$StallThresholdSec -ScriptBlock {
            param($logFile,$rsyncLog,$targetLetter,$intervalSec,$stallSec)
            # Active-data signal is the LogicalDisk write rate for the target.
            # E:used and rsync log file size can be flat for minutes while
            # rsync delta-rebuilds a large file in-place. Treat any sustained
            # write > 1 MB/s as evidence of progress (matches the robocopy-era
            # heuristic from kopia-30c that fixed the 2026-05-10 false-STALL).
            $counterPath = "\LogicalDisk($($targetLetter):)\Disk Write Bytes/sec"
            $lastChange = Get-Date
            while ($true) {
                Start-Sleep -Seconds $intervalSec
                $vol = Get-Volume -DriveLetter $targetLetter -ErrorAction SilentlyContinue
                if (-not $vol) {
                    Add-Content -LiteralPath $logFile -Value ('{0} -- [progress] target volume not visible' -f (Get-Date -Format 'ddd MM/dd/yyyy HH:mm:ss.ff'))
                    continue
                }
                $used = $vol.Size - $vol.SizeRemaining
                $rsz  = if (Test-Path -LiteralPath $rsyncLog) { (Get-Item -LiteralPath $rsyncLog).Length } else { 0 }

                $writeMBps = 0.0
                try {
                    $s = Get-Counter -Counter $counterPath -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop
                    $writeMBps = ($s.CounterSamples | Measure-Object CookedValue -Average).Average / 1MB
                } catch {}

                $now = Get-Date
                if ($writeMBps -gt 1.0) { $lastChange = $now }
                $idleSec = [int]($now - $lastChange).TotalSeconds
                $tag = if ($idleSec -gt $stallSec) { ' STALL' } else { '' }
                $line = '{0} -- [progress] {1}:used={2:N2}GB write={3:N1}MB/s rsync_log={4}KB idle={5}s{6}' -f `
                    $now.ToString('ddd MM/dd/yyyy HH:mm:ss.ff'), $targetLetter, ($used/1GB), $writeMBps, [math]::Round($rsz/1KB,1), $idleSec, $tag
                Add-Content -LiteralPath $logFile -Value $line
            }
        }
        Write-Log "progress watcher started (job id=$($progressJob.Id), interval=${ProgressIntervalSec}s, stall=${StallThresholdSec}s)" 'mirror'
    }

    # Tree A: Everything except WindowsImageBackup
    $rsyncArgsA = @(
        '--recursive'
        '--links'
        '--times'
        '--inplace'
        '--no-whole-file'
        '--delete-after'
        '--info=name,progress2,stats2'
        "--log-file=$rsyncLog"
        '--exclude=$RECYCLE.BIN/'
        '--exclude=System Volume Information/'
        '--exclude=BackupMonitorIndex/'
        '--exclude=*.sdb-wal'
        '--exclude=*.sdb-shm'
        '--exclude=WindowsImageBackup/'
    )
    if ($DryRun) { $rsyncArgsA += '--dry-run' }
    $rsyncArgsA += $srcCyg
    $rsyncArgsA += $dstCyg
    Write-Log "rsync tree-A (kopia): $(($rsyncArgsA | Measure-Object).Count) args" 'mirror'
    & $rsyncBin @rsyncArgsA | Out-Null
    $rcA = $LASTEXITCODE
    $summary.rsync_kopia_rc = $rcA

    # Tree B: WindowsImageBackup with --link-dest pointing at yesterday's dated folder
    $srcWbadminRoot = Join-Path $shadowPath 'WindowsImageBackup\ChrisLaptop2'
    $todayFolder    = Get-ChildItem -LiteralPath $srcWbadminRoot -Directory -Filter 'Backup *' -ErrorAction SilentlyContinue |
                      Sort-Object Name -Descending | Select-Object -First 1
    $linkDest       = ''
    if ($todayFolder) {
        $priorFolder = Get-PriorWbadminFolder `
            -WbadminRoot 'E:\WindowsImageBackup\ChrisLaptop2' `
            -TodayName   $todayFolder.Name
        if ($priorFolder) { $linkDest = (ConvertTo-CygPath $priorFolder.FullName) }
    }
    $summary.link_dest_used = $linkDest

    $rsyncArgsB = @(
        '--recursive'
        '--links'
        '--times'
        '--inplace'
        '--no-whole-file'
        '--delete-after'
        '--info=name,progress2,stats2'
        "--log-file=$rsyncLog"
    )
    if ($linkDest) { $rsyncArgsB += "--link-dest=$linkDest" }
    if ($DryRun)   { $rsyncArgsB += '--dry-run' }
    $rsyncArgsB += (ConvertTo-CygPath (Join-Path $shadowPath 'WindowsImageBackup')) + '/'
    $rsyncArgsB += (ConvertTo-CygPath 'E:\WindowsImageBackup') + '/'
    Write-Log "rsync tree-B (wbadmin): $(($rsyncArgsB | Measure-Object).Count) args, link-dest=$linkDest" 'mirror'
    & $rsyncBin @rsyncArgsB | Out-Null
    $rcB = $LASTEXITCODE
    $summary.rsync_wbadmin_rc = $rcB

    # rsync exit codes: 0 = success; 23 = "partial transfer due to errors";
    # 24 = "some files vanished before transfer". Treat 0/23/24 as PASS (like
    # robocopy 1-7), any other non-zero as failure.
    $rsyncFail = $false
    foreach ($rc in @($rcA, $rcB)) {
        if ($rc -ne 0 -and $rc -ne 23 -and $rc -ne 24) { $rsyncFail = $true; break }
    }
    if ($rsyncFail) {
        throw "rsync failed: tree-A rc=$rcA, tree-B rc=$rcB (see $rsyncLog)"
    }
    $summary.robocopy_rc = [Math]::Max($rcA, $rcB)
    Write-Log "rsync tree-A rc=$rcA tree-B rc=$rcB max=$($summary.robocopy_rc) (0/23/24 = pass)" 'mirror'

    # Parse rsync stats2 output for bytes/files totals (best-effort).
    # rsync stats2 lines we care about:
    #   "Number of files: 30,915 (reg: 26,241, dir: 4,674)"
    #   "Total file size: 602,399,618,017 bytes"
    if (Test-Path -LiteralPath $rsyncLog) {
        $rsyncTail = Get-Content -LiteralPath $rsyncLog -Tail 25
        $filesLine = $rsyncTail | Where-Object { $_ -match 'Number of files:' } | Select-Object -First 1
        if ($filesLine -match 'reg:\s*([\d,]+)') {
            $summary.files = [int64](($Matches[1] -replace ',',''))
        }
        $bytesLine = $rsyncTail | Where-Object { $_ -match 'Total file size:' } | Select-Object -First 1
        if ($bytesLine -match 'Total file size:\s*([\d,]+)') {
            $summary.bytes = [int64](($Matches[1] -replace ',',''))
        }
    }

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
    # Stop the progress watcher first so it doesn't keep emitting after the
    # mirror is done.
    if ($progressJob) {
        try {
            Stop-Job -Job $progressJob -ErrorAction Stop | Out-Null
            Remove-Job -Job $progressJob -Force -ErrorAction Stop | Out-Null
            Write-Log "progress watcher stopped" 'vss'
        } catch {
            Write-Log "WARNING: progress watcher cleanup failed: $_" 'vss'
        }
    }

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

# SIG # Begin signature block
# MII9bQYJKoZIhvcNAQcCoII9XjCCPVoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCuzHn+sdHArdAm
# cqkxljjsHKZ6m7oaZU3gls2UYRYSXqCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggbFMIIEraADAgECAhMzAAD5lfAL
# +yA2/46OAAAAAPmVMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwHhcNMjYwNTEzMTc1NzIwWhcNMjYwNTE2
# MTc1NzIwWjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZb3JrMRQwEgYD
# VQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0IE1hbmFnZW1l
# bnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2VtZW50LCBJbmMu
# MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAi98JwlC98Y0AtqXxNX2n
# ecyTKIY/oel5f58idJvku0DgUkYslyQ7zyeURKP6632ePmiSoC00j1jmURiD2Tma
# LkudfTiHaBrhGW3K8fhX6kxj1hCHDZ26IGmnUBeHjmFl4orAuocfBkTSO2JfngTO
# gQHsQBphyuDlRpURZ33RxtuiCK5AA9FKRVdynmMNBdpvNB1fCqYs9e4SGQ6l3p2Y
# 2J9empJ9riNykbc+FINGKoLlA4CfJ0KiVDZptYqWhaNvAf0DSKg1nqy1nkpjZ08s
# hF1Tqa2i7BTvCo0nO0r+X+0H3c4jiGaW7ZOJqHlF+rqzeb8qvmAyBA0wEcemKxAH
# LaXmqFvu216ppK5BKjlDeM+w8ERwKvdJNqSmTmsnjmsJU8d2tiOpf2O71dzo/Rep
# Nnq8cDct3nd2xbaYi8YLumxSoegHrZhGjLWA83VuxXAavpVKxQTzMFtsY1GKT0L6
# IZaGqV03oowWpkpbJib2d0lPNJKxDRrfVUr6FSjfqnv/AgMBAAGjggHVMIIB0TAM
# BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAzBgorBgEEAYI3
# YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGhn5ARMB0GA1Ud
# DgQWBBQ2Bxo++FXH8hPOME4h2m+qIOF3HzAfBgNVHSMEGDAWgBSkQwx/dlqlhec+
# jSgPDBeiRWlwxjBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1Ml
# MjBBT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKG
# WGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwMy5jcnQwVAYDVR0g
# BE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOC
# AgEAMCjLSLS3ojqK5IDK04L5xhwUkDnon4e5lkEwtvSx8EDzjgfjKlsvxalI+hGV
# th03FHiKUncK6WspFmnNnhP0Z1aaCF6EkdGy3OybYbg8RRq/QTwgirSeF6nAmpXZ
# 39rmkNlvRuLWUUEt1PW/jXe1hku9YCszJuA+IM7dPuRoJcy7VQXJvFvMLk/o50vi
# qpglry+YEl+VHg169iNtbeYw2bgVDzPxWasjPg7m9iy1qLQJtkKpfOMxs8AgU5Nf
# 9ihWcEmwEKU6nrBNOaou6x8srt0CQoSSfkiW1L8JccNkaqoqBeNaKTCeaPZBWGIk
# 3nmBH9xZS5Cch9qrufovfFbvwvcbmRLkCbEYVqf9QkwGt97uNwg9lFXDGFcE5bqR
# GG/uQVzn7BBBM1skzxp0C/qdJt5DQ9ltIdYCbxuVzIhgRBiXiYhcPxINkmrkr5eq
# DhVCBXw/C1PjiFeo78eo1Yb1MsYlWDpkyaeCK64CgYmWYMMDBxpTSQATC1RDGTkl
# ne3IYPisaWnCIaXwYe2sdphZ3BWSfyEIHVOODBQ1Wocuanp9QHZqu3YoWclPsOMD
# NmYCj23nSftR+EG6YVaqMJMvJ4tIiQP9r2gkldD69mKZerw4Q3IghwzV/4FsC8hB
# YCfTeMicWiQFPSscFwg/OKT6LscWGuQKZu/1Fllhtcgy5SUwggbFMIIEraADAgEC
# AhMzAAD5lfAL+yA2/46OAAAAAPmVMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwHhcNMjYwNTEzMTc1NzIw
# WhcNMjYwNTE2MTc1NzIwWjCBhjELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE5ldyBZ
# b3JrMRQwEgYDVQQHEwtTb3VuZCBCZWFjaDEmMCQGA1UEChMdRm9yYmVzIEFzc2V0
# IE1hbmFnZW1lbnQsIEluYy4xJjAkBgNVBAMTHUZvcmJlcyBBc3NldCBNYW5hZ2Vt
# ZW50LCBJbmMuMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAi98JwlC9
# 8Y0AtqXxNX2necyTKIY/oel5f58idJvku0DgUkYslyQ7zyeURKP6632ePmiSoC00
# j1jmURiD2TmaLkudfTiHaBrhGW3K8fhX6kxj1hCHDZ26IGmnUBeHjmFl4orAuocf
# BkTSO2JfngTOgQHsQBphyuDlRpURZ33RxtuiCK5AA9FKRVdynmMNBdpvNB1fCqYs
# 9e4SGQ6l3p2Y2J9empJ9riNykbc+FINGKoLlA4CfJ0KiVDZptYqWhaNvAf0DSKg1
# nqy1nkpjZ08shF1Tqa2i7BTvCo0nO0r+X+0H3c4jiGaW7ZOJqHlF+rqzeb8qvmAy
# BA0wEcemKxAHLaXmqFvu216ppK5BKjlDeM+w8ERwKvdJNqSmTmsnjmsJU8d2tiOp
# f2O71dzo/RepNnq8cDct3nd2xbaYi8YLumxSoegHrZhGjLWA83VuxXAavpVKxQTz
# MFtsY1GKT0L6IZaGqV03oowWpkpbJib2d0lPNJKxDRrfVUr6FSjfqnv/AgMBAAGj
# ggHVMIIB0TAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDA8BgNVHSUENTAz
# BgorBgEEAYI3YQEABggrBgEFBQcDAwYbKwYBBAGCN2HvuNEUgqvS9CmCyY+uJIGh
# n5ARMB0GA1UdDgQWBBQ2Bxo++FXH8hPOME4h2m+qIOF3HzAfBgNVHSMEGDAWgBSk
# Qwx/dlqlhec+jSgPDBeiRWlwxjBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDAzLmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwMy5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEAMCjLSLS3ojqK5IDK04L5xhwUkDnon4e5lkEwtvSx8EDzjgfj
# KlsvxalI+hGVth03FHiKUncK6WspFmnNnhP0Z1aaCF6EkdGy3OybYbg8RRq/QTwg
# irSeF6nAmpXZ39rmkNlvRuLWUUEt1PW/jXe1hku9YCszJuA+IM7dPuRoJcy7VQXJ
# vFvMLk/o50viqpglry+YEl+VHg169iNtbeYw2bgVDzPxWasjPg7m9iy1qLQJtkKp
# fOMxs8AgU5Nf9ihWcEmwEKU6nrBNOaou6x8srt0CQoSSfkiW1L8JccNkaqoqBeNa
# KTCeaPZBWGIk3nmBH9xZS5Cch9qrufovfFbvwvcbmRLkCbEYVqf9QkwGt97uNwg9
# lFXDGFcE5bqRGG/uQVzn7BBBM1skzxp0C/qdJt5DQ9ltIdYCbxuVzIhgRBiXiYhc
# PxINkmrkr5eqDhVCBXw/C1PjiFeo78eo1Yb1MsYlWDpkyaeCK64CgYmWYMMDBxpT
# SQATC1RDGTklne3IYPisaWnCIaXwYe2sdphZ3BWSfyEIHVOODBQ1Wocuanp9QHZq
# u3YoWclPsOMDNmYCj23nSftR+EG6YVaqMJMvJ4tIiQP9r2gkldD69mKZerw4Q3Ig
# hwzV/4FsC8hBYCfTeMicWiQFPSscFwg/OKT6LscWGuQKZu/1Fllhtcgy5SUwggco
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
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakzCC
# Go8CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENB
# IDAzAhMzAAD5lfAL+yA2/46OAAAAAPmVMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIOCuZHztf0KG1D4JVoY9s+AIX0VngjkvmE/2cMBbtUstMA0GCSqGSIb3
# DQEBAQUABIIBgHc301rNQNe/hNbeaxjHHbG8RGo88msFLONlWJKZpWxU2nRRbkz2
# zD+PMrzIFO6T5ZHJkbVhmammUGnR3SK6u93iFxv7EKmrLIleilGvZunGJ3S8RAHQ
# zRMI8eQPAQd4cRRDD0bmIiMwN5NuN/9uDUx3SoB5VE3PT2y4DcaNmn5f2lk0Jtw/
# Fc1KdcRhsiA1V5W6G3CyIODaQhAhwsfTu+peZTMJ3pzPZnXzgu9lgV6ECKY40qGB
# fsZhbFQnrlkSYSBWdj+7Igm4k5PQSmq7/4zut9TBy1r/mPgpAQTA+YzaG7yhOM8P
# tdoINJPN4SNGNsW3x47mUwEnrZ8I/RY2CMa2Xd4TLU4xCfppVPMw0Ng8ynT3Y0+7
# vr07VfDn0owbNHOxAjNCFnghqGH1ajGBjO6FPyoWsDNpMSjiXgznzCFPSQD6A/l+
# Qw1cynnCHphc/fLKWeTQnvNBQC4h6uMaOpNDqJKmmScij4yQxiG5Q5GDrVfx0bfT
# yZeWyuhnH1QThKGCGBMwghgPBgorBgEEAYI3AwMBMYIX/zCCF/sGCSqGSIb3DQEH
# AqCCF+wwghfoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFhBgsqhkiG9w0BCRABBKCC
# AVAEggFMMIIBSAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCXmQis
# O5zC4fx+cZkKWzwOsjj5bgmj12XS0MUYvGYB5wIGaedYfrzcGBIyMDI2MDUxNDAy
# MTc0Ni4zN1owBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
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
# 7EDOGD8GmLE9LiqtQsuQCM7v7I2xR+sPZT2Ax/85HjIkM+3MzTK1MYIHRjCCB0IC
# AQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMAITMwAAAFck05XgounJMQAAAAAAVzANBglghkgBZQMEAgEFAKCCBJ8w
# EQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAc
# BgkqhkiG9w0BCQUxDxcNMjYwNTE0MDIxNzQ2WjAvBgkqhkiG9w0BCQQxIgQgpOAR
# Y32tJzRkVlHcdEdU8JJfvZJ5+TgAxqUxu6zxH/4wgbkGCyqGSIb3DQEJEAIvMYGp
# MIGmMIGjMIGgBCD1PJ9ktQVuTGWIbKLO4f1VUOlUU29ARCEpDZmFTHjbUjB8MGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFck05XgounJMQAAAAAAVzCCA2EGCyqGSIb3DQEJEAISMYIDUDCC
# A0yhggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5
# NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcg
# QXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD9LzE5nEJRAUE2Ss3xaKKPXHnLw6Bn
# MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2vgIowIhgPMjAyNjA1MTMyMjU4MTha
# GA8yMDI2MDUxNDIyNTgxOFowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7a+AigIB
# ADAKAgEAAgIg6wIB/zAHAgEAAgISdDAKAgUA7bDSCgIBADA2BgorBgEEAYRZCgQC
# MSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqG
# SIb3DQEBCwUAA4IBAQBEmHymAELchIxQI4Dms3UpUbgPd0dD9+Rcm3fc1vKkaEIJ
# tVhbqvK7iarLvC5vY9KvS3klE8OJDpP6M6w/apm+YOdDz97eY0Jc0EnOsKEW7e6U
# 6/2I3ertK1rIQuZ5Cg0+S+kweI7feID4s+3iqmMcOMhGXrPdyrVfzaK5SHi2ChIG
# EdL6mDk4GGmwshJDfp+0GHQWMIu65hVLEYW/6sTnbgSwP8PkdaTqEf5HKEjJoqtS
# E8aEJ4msoICtSUMe0G0lrEbovnOFPIl7CHc04IkIfNFLxpaZjKsire6SHWJGP7DI
# XwA+dNbqpdWyxLz+f0OcMlOxY+aArgY1xuxpgu5xMA0GCSqGSIb3DQEBAQUABIIC
# AE8fz6/VIIOoBp71xAWO06jKBHcnlDZk/3CHecEDI852EkYEqgrpvaUgIATxbW+w
# nHb9lHsIamdBDmF8/3tlz/zJz+FQQepsj9SEjrP34ychWD9bXvvDywNYB66GCefz
# m6sErQXMVebceoyr4wMXK2AjGKu2ScAvOFR/MCVvsZpob610IS5UEQVCG+PbIPcI
# 4P6seNGxlfP18T/gzbSssWF5bPxnEODqcz7Z7DMjqnCgEEsF9l0/Rn5JQwhVcuvC
# vedEDKSs9BTbYvvm7YHnE5ZFnwF1bP+fsYYbqJguGsWsaIO1qusJy1Wj7ZYqdjWz
# +XizoMgTzT3upG/a98+agXCK4BxBaqDjQCs528jNnvoqFIE6YO80jrEWH9EsCfy8
# tkW4iifQE1uOZEIK22ROLqjEg5cA/8ITp5P7yfCL539XrG9HxqT/ErZ6Qlz0pbN6
# KhqsifnP5mr2CJ/UmQQZJad+PrWL2W98n+MxcDtfcTPPdLA1EiB07J9QK7n+pHtu
# F1vx0GiLtA7dwYZPmB+6Kt9ByvB/IukPhy1RbXky+ST7MjHydO57uniSsAWYSI6s
# LvHBaG2AM1rgGRmTVaYaL4e5KX2d++mQDvHyER14tKSjQS8SFkzd8cRu6AgX+BKB
# GLFmDO3VZB0SEH6KphZFYOikd3ZcETuXrBWwZMQlbZnR
# SIG # End signature block
