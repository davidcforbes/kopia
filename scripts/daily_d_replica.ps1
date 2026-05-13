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
        '--info=stats2,progress2'
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
        '--info=stats2,progress2'
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
}
# SIG # Begin signature block
# MII9awYJKoZIhvcNAQcCoII9XDCCPVgCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCxH8TwZKioCaCT
# GitukQS5RheQ+12+YKG4RECASOMg+KCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakTCC
# Go0CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENB
# IDAzAhMzAAD5lfAL+yA2/46OAAAAAPmVMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIBbiblUCFyYMiYQWcIbYac9fx5lXLAgTnXEzBIpPJ3piMA0GCSqGSIb3
# DQEBAQUABIIBgHxkggKIJjFv+8mlhycmEyW4LO1g3b3BIcXzoki/gyKXQD6/JdmO
# deHLhNV14bmBIUcuckcOcl4RQIqy7+pWBDOY5eIK7+wRvv3y/XARNBlMSIQHkZwf
# MriGOi7uYppMzIfrFnyzvRV3LhHBQIWEcFquOHMnkOQNAD+YX/qTU8GDygavjHAu
# xzurph1amyz/Wp1SMHh/KIJmm3o2y+zyY0/7tNOX5dnIJd3qMfhpnV/pkJSqm3Ba
# adb4HdqsRY3LS3ErTRSZHliaKClCWPlFeg2JyY3Jm0HVI6vWc+Loq6/7uHf0zG5a
# VsnL4P5kliUA+3sNXJE2xnNvgrCLnKvHhPjrW68pbykmCxYr+ZpWA37c/SXfUe05
# jpKNMTqi9eN+0GQJpxWbQ58uIPFxv8rxu8TDA6kLoVH6QmXvDiZ6gKOA0BGwawXN
# r8iGcQx9+MSC7GaE9QcavxrpQIQzEh0iAkCmRJLOu3iBNcb9gxwWUyqMx+/kXMa2
# IM1uZxzMJlfG3qGCGBEwghgNBgorBgEEAYI3AwMBMYIX/TCCF/kGCSqGSIb3DQEH
# AqCCF+owghfmAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFiBgsqhkiG9w0BCRABBKCC
# AVEEggFNMIIBSQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCAvuxkc
# oUndjp6WzfTlFYfo/4b08cuRo0SP7d4X5kz3CQIGaeiBIJuAGBMyMDI2MDUxMzE4
# NDAyOS41OTFaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRp
# b25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAz
# BgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9y
# aXR5oIIPITCCB4IwggVqoAMCAQICEzMAAAAF5c8P/2YuyYcAAAAAAAUwDQYJKoZI
# hvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlmaWNhdGlv
# biBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIwMTExOTIwMzIz
# MVoXDTM1MTExOTIwNDIzMVowYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0Eg
# VGltZXN0YW1waW5nIENBIDIwMjAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQCefOdSY/3gxZ8FfWO1BiKjHB7X55cz0RMFvWVGR3eRwV1wb3+yq0OXDEqh
# UhxqoNv6iYWKjkMcLhEFxvJAeNcLAyT+XdM5i2CgGPGcb95WJLiw7HzLiBKrxmDj
# 1EQB/mG5eEiRBEp7dDGzxKCnTYocDOcRr9KxqHydajmEkzXHOeRGwU+7qt8Md5l4
# bVZrXAhK+WSk5CihNQsWbzT1nRliVDwunuLkX1hyIWXIArCfrKM3+RHh+Sq5RZ8a
# Yyik2r8HxT+l2hmRllBvE2Wok6IEaAJanHr24qoqFM9WLeBUSudz+qL51HwDYyID
# PSQ3SeHtKog0ZubDk4hELQSxnfVYXdTGncaBnB60QrEuazvcob9n4yR65pUNBCF5
# qeA4QwYnilBkfnmeAjRN3LVuLr0g0FXkqfYdUmj1fFFhH8k8YBozrEaXnsSL3kdT
# D01X+4LfIWOuFzTzuoslBrBILfHNj8RfOxPgjuwNvE6YzauXi4orp4Sm6tF245Da
# FOSYbWFK5ZgG6cUY2/bUq3g3bQAqZt65KcaewEJ3ZyNEobv35Nf6xN6FrA6jF944
# 7+NHvCjeWLCQZ3M8lgeCcnnhTFtyQX3XgCoc6IRXvFOcPVrr3D9RPHCMS6Ckg8wg
# gTrtIVnY8yjbvGOUsAdZbeXUIQAWMs0d3cRDv09SvwVRd61evQIDAQABo4ICGzCC
# AhcwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRr
# aSg6NS9IY0DPe9ivSek+2T3bITBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEF
# BQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9z
# aXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoA
# UwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZ
# mAQHJ89QEE9oqKIwgYQGA1UdHwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZp
# Y2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5j
# cmwwgZQGCCsGAQUFBwEBBIGHMIGEMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUy
# MFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
# MDIwMjAuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBfiHbHfm21WhV150x4aPpO4dhE
# mSUVpbixNDmv6TvuIHv1xIs174bNGO/ilWMm+Jx5boAXrJxagRhHQtiFprSjMktT
# liL4sKZyt2i+SXncM23gRezzsoOiBhv14YSd1Klnlkzvgs29XNjT+c8hIfPRe9rv
# VCMPiH7zPZcw5nNjthDQ+zD563I1nUJ6y59TbXWsuyUsqw7wXZoGzZwijWT5oc6G
# vD3HDokJY401uhnj3ubBhbkR83RbfMvmzdp3he2bvIUztSOuFzRqrLfEvsPkVHYn
# vH1wtYyrt5vShiKheGpXa2AWpsod4OJyT4/y0dggWi8g/tgbhmQlZqDUf3UqUQsZ
# aLdIu/XSjgoZqDjamzCPJtOLi2hBwL+KsCh0Nbwc21f5xvPSwym0Ukr4o5sCcMUc
# Sy6TEP7uMV8RX0eH/4JLEpGyae6Ki8JYg5v4fsNGif1OXHJ2IWG+7zyjTDfkmQ1s
# nFOTgyEX8qBpefQbF0fx6URrYiarjmBprwP6ZObwtZXJ23jK3Fg/9uqM3j0P01nz
# VygTppBabzxPAh/hHhhls6kwo3QLJ6No803jUsZcd4JQxiYHHc+Q/wAMcPUnYKv/
# q2O444LO1+n6j01z5mggCSlRwD9faBIySAcA9S8h22hIAcRQqIGEjolCK9F6nK9Z
# yX4lhthsGHumaABdWzCCB5cwggV/oAMCAQICEzMAAABV2d1pJij5+OIAAAAAAFUw
# DQYJKoZIhvcNAQEMBQAwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGlt
# ZXN0YW1waW5nIENBIDIwMjAwHhcNMjUxMDIzMjA0NjQ5WhcNMjYxMDIyMjA0NjQ5
# WjCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UE
# CxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVs
# ZCBUU1MgRVNOOjdEMDAtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBAL25H5IeWUiz9DAlFmn2sPymaFWbvYkMfK+ScIWb3a1I
# vOlIwghUDjY0Gp6yMRhfYURiGS0GedIB6ywvuH6VBCX3+bdOFcAclgtv21jrpOjZ
# mk4fSaT2Q3BszUfeUJa8o3xI7ZfoMY9dszTxHQAz6ZVX87fHGEVhQcfxW33IdPJO
# j/ae419qtYxT21MVmCfsTshgtWioQxmOW/vMC9/b+qgtBxSMf798vm3qfmhF6KCv
# FaHlivrM32hY16PGE3L0PFC+LM7vRxU7mTb+r76CeybvqOWk4+dbKYftPhV1t/E5
# S/6wwXeYmu/Y7JC7Tnh2w45G5Y4pcM3oHMb/YuPRdOWa0v+RC2QgmNVWqjuxDiyl
# WscXQDuaMtb29AcdGUVV9ZsRY2M2sthAtOdZOshiR5ufMtaHtiCkWv0jNfgUxrHu
# rxzYuUNneWZ6EfQDgFAw8CSCKkSOK2c9jEop4ddVq10xvbqxdrqMneVXvvIcXrPQ
# AXj9j2ECpV2EwMb3Wnmpw00P78JpzPsk3Fs61ZvOGd/F1RcOBu6f2TWdp7HL7+rq
# 7tgHr13MldbfIWu4lpoYYE1gTQa1Yrg5XN4j7zs9klT2z3qocmPzV8DWQgIHNh+a
# Ts7bujMEMQyI7Xt1zPxZCgcR6H0tmmzU/9BxvsWbRalCQ2sYGyWupTdc4e7KY7kP
# AgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQUVgRfEG3cCAPwyL+pyRbKwdesZbYwHwYD
# VR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBhoF+gXYZb
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIw
# UHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNybDB5Bggr
# BgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0
# YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEGDCsGAQQB
# gjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqGSIb3DQEB
# DAUAA4ICAQBSHuGSVHvalCnFnlsqXIQefH1xP2SFr9g+Vz+f5P7QeywjfQb5jUlS
# md1XnJUDPe/MHxL7r3TEElL+mNtG6CDPAytStSFPXD9tTBtBMYh8Wqo64pH9qm36
# 1yIqeBH979mzWCkMQsTd0nM6dUl9B+7qiti+ToXwxIl39eYqLuYYfhD2mqqePXMz
# UKSQzkf73yYIVHP6nLJQz4aAmaWcfG9jg78sBkDV8KpW7JgktuLhphJEN1B+SVHj
# enPdcmrFXIUu/K4jK5ukfWaQIjuaXzSjBlNjC5tQN6adPfA3GxUwHPeR4ekL5If/
# 9vBf13tmzBW+gy+0sNGTveb9IL9GU8iX8UvywsX62nhCCPRUhTigDBKdczRUrNrn
# tBhowbfchBDFML8avRMRc9Gmc2JvIryX336SFQ51//q1UU2HMSJEMhWLJSIWJVhf
# UowsOa+PampIzETYfFvTu2mqKJUlWZXkGYxrdCvCczJcqeoadpW1ul6kcdnDh228
# SQ8ZhDc6IRlM4iNd5SNoNgX+aom3wuGyjUaSaPZWxPB1G2NKiYhPLt0lPHg0Gskj
# 1zhISY8UQkMMDr3o2JgRuT+wnJEDQUp55ddvhSkSoD6I9DL/s+TjIY/c9jLaW5xy
# wJHqdKHUApRMsghv7kebSua1upmR+TquelFktDSOjVdSRkuya4uoxTGCB0Mwggc/
# AgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjACEzMAAABV2d1pJij5+OIAAAAAAFUwDQYJYIZIAWUDBAIBBQCgggSc
# MBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MDUxMzE4NDAyOVowLwYJKoZIhvcNAQkEMSIEIHnA
# XBEz2hxdEbuldxWEZn44ZNb8PrkhecVGlDZKlmkqMIG5BgsqhkiG9w0BCRACLzGB
# qTCBpjCBozCBoAQg2Lk8l2SGYru/ff7+D2qrJnkswcYdK6pGKu7GGGr4/s0wfDBl
# pGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENB
# IDIwMjACEzMAAABV2d1pJij5+OIAAAAAAFUwggNeBgsqhkiG9w0BCRACEjGCA00w
# ggNJoYIDRTCCA0EwggIpAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjdEMDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUAHTtUAYJlv7bgWVeRBo4X7FeHDeqg
# ZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDtrq7wMCIYDzIwMjYwNTEzMDgwNDAw
# WhgPMjAyNjA1MTQwODA0MDBaMHQwOgYKKwYBBAGEWQoEATEsMCowCgIFAO2urvAC
# AQAwBwIBAAICOEswBwIBAAICErQwCgIFAO2wAHACAQAwNgYKKwYBBAGEWQoEAjEo
# MCYwDAYKKwYBBAGEWQoDAqAKMAgCAQACAwehIKEKMAgCAQACAwGGoDANBgkqhkiG
# 9w0BAQsFAAOCAQEAF3WHOdMpJHKw0QxN+QX60rybKk/T4B0EhWwXipl5x9QZ6BK8
# hPEWlCM/TuljLi7M8ySVAqQdsq4FqzShaL00XT1jMsVwbcQZ39lD8n+zRyYxgpUg
# 2OAkY6w/WI3KmHwDieG504Kr9gyLS/iyGj2AcISyqahorcmQBKLbZYR8xhEn8wN/
# mowMCaeArW2+tBJJqBj1LFO++Hq1oeJVrtKsh5fTmu2BN+7OrhDiYDKX0AIERsUe
# WfYBvEDTR1E9EIz7/hoQCTJzAUzwDsnvaKqIGTe0g0lf2QPvoJkAaanHwn1i0GJQ
# 5sJPaBKmGj7Xlzy1uTxu8kZvsxXI94l9l8XIezANBgkqhkiG9w0BAQEFAASCAgCf
# LnHEWIPAE+cNVdHmLP/TPcaUe8rSpUSeuex6lcWjK59fQiYw8xLn15VqKxZcWz5j
# o+9aOry6pf/FppIH/QBFY4vW0F0O+MY6eAwav+p4WcNXqrpvA+UslQuXmLlcU9YR
# 24a7mgPmDVDw63UBxlYuhiVCUkdTDiVKCzjCQjf3gyO+yRWTXTO7vN78QQu1ICJA
# e7CA1HxI6XJTJex+mSICeT6kGgDK/Zk5Isq6boYoMVtEQsh35+IYPvQHYP/zvUO9
# P26PtKDgzV6IMCtHX7Qkj0XwyUoEwiTfqXgqMx0yw6eaZKTVZ3h1fJxLwIhwxdss
# 6d6g+doNhw8GidVGazq7ilx+459N2LkeAzWpcxrIJm6KwVPd+1RGNZqBvlfCtR6F
# VHvMbnfDiYbkzONkMkcJP+j42yuV+R31bkOZwFURcjzcYOCcTGrl8h6iAZWQH/+C
# lyoHuv3VDhz4nOgqEAsUfiWzrRg2OdN0KIGTaguzlCP2AEHBopgbPOGp9kRwRueU
# P9vs1V4ymccUXhf71BXU0tnldO4c8cK9lqBqQGKzSC9KXydh0IiPebWuhGWE/LER
# dc+W+cboHWs3/aZIF/pxSt8XyHrdk7EoErbMkn3EDvW7u+KFuHSwzShiDqju/sjj
# 3MGybzTZICIGGnq9VjqsGguus4zAQH0bo6a5w7yMFg==
# SIG # End signature block
