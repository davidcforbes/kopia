# daily_d_replica.ps1 — Daily mirror of D: to the 8 TB external (E:).
#
# Single-phase design: VSS shadow of D:, then robocopy /MIR to E:. Kopia's
# blob format (write-once content blobs, atomic-rename indexes) means a
# file-level mirror taken from a VSS snapshot yields a valid replica repo
# openable with the same password. See plan
# C:\Users\david\.claude\plans\partitioned-jumping-sunrise.md and beads
# kopia-30c (the original Phase A using `kopia repository sync-to` was
# dropped — sync-to is direct-mode only per cli/command_repository_sync.go).
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
    $line = '{0} — [{1}] {2}' -f (Get-Date -Format 'ddd MM/dd/yyyy HH:mm:ss.ff'), $Tag, $Message
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
    $line  = '{0} — replica summary {1}' -f (Get-Date -Format 'ddd MM/dd/yyyy HH:mm:ss.ff'), ($parts -join ' ')
    Add-Content -LiteralPath $DailyKopiaLog -Value $line
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
    source        = $src
    target        = $dst.TrimEnd('\')
    mode          = $mode
    bytes         = 0
    files         = 0
    errors        = 1   # default fail; cleared on PASS path
    duration_s    = 0
    robocopy_rc   = -1
    shadow_id     = '-'
}

try {
    # ---- Preflight: clean up orphans from prior hung runs ----
    # Any kopia-replica-shadow-* junction in TEMP is from a prior run whose
    # finally block didn't complete. Direct Remove-Item — these are stale,
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
    # usage — once target has >100 GB it's clearly been seeded.
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
    # (ERROR 123: filename syntax incorrect — confirmed empirically). The
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

    # ---- Phase 2: Robocopy /MIR ----
    # /MIR  — mirror (purge dest of items not in source)
    # /MT:N — multithreaded copy
    # /COPY:DAT — Data, Attributes, Timestamps (skip ACLs/Owner/Auditing; target ACLs are intentionally locked)
    # /DCOPY:DAT — directory data/attributes/timestamps
    # /R:2 /W:5 — 2 retries, 5 s wait
    # /XJ — exclude junction points
    # /XD — exclude dirs: $RECYCLE.BIN, System Volume Information, BackupMonitorIndex (rebuildable)
    # /NFL /NDL — no per-file / per-dir listing in log
    # /NP — no progress
    # /TEE — also write to console for interactive seed runs
    # /LOG+ — append to log file
    $roboLog = "$LogFile.robo"
    $excludeDirs = @(
        '$RECYCLE.BIN',
        'System Volume Information',
        'BackupMonitorIndex'
    )
    # Sysmon archive SQLite Write-Ahead Log + shared-memory files are held
    # open by the Sysmon SYSTEM service with ACLs that deny read even through
    # a VSS shadow (ERROR 5 access denied). They're transient session state —
    # Sysmon recreates them. The main .sdb archive files copy fine. This
    # exclusion is what kept the 2026-05-10 initial seed from completing
    # cleanly (8 files failed → rc=9). Tiny files, totalling under 5 MB.
    $excludeFiles = @(
        '*.sdb-wal',
        '*.sdb-shm'
    )
    # NOTE: never use binary `+` inside @() literals — PowerShell's parser
    # has a real bug where `'a' + 'b'` inside an array can split into two
    # elements (or worse, mash all subsequent elements into one string,
    # truncating the array). Empirically reproduced in this session. Use
    # intermediate variables and double-quoted interpolation instead.
    $srcArg     = $shadowPath.TrimEnd('\') + '\'
    $mtArg      = "/MT:$RobocopyThreads"
    $logArg     = "/LOG+:$roboLog"
    $roboArgs = @(
        $srcArg
        $dst
        '/MIR'
        $mtArg
        '/R:2'
        '/W:5'
        '/COPY:DAT'
        '/DCOPY:DAT'
        '/XJ'
        '/NFL'
        '/NDL'
        '/NP'
        $logArg
    )
    # /TEE deliberately omitted: it requires an attached console, and the
    # scheduled task / background powershell.exe both run without one.
    # For live progress, tail the robocopy log: Get-Content $roboLog -Wait
    if ($DryRun) { $roboArgs += '/L' }   # list-only
    $roboArgs += '/XD'
    foreach ($d in $excludeDirs) { $roboArgs += $d }
    $roboArgs += '/XF'
    foreach ($f in $excludeFiles) { $roboArgs += $f }

    Write-Log ("robocopy {0} args; full vector: {1}" -f $roboArgs.Count, ($roboArgs -join '|')) 'mirror'

    # Spawn a background watcher that emits [progress] lines and flags stalls.
    # Watcher polls $ProgressIntervalSec; if neither E: usage nor robocopy log
    # grows for $StallThresholdSec, the line is tagged STALL. Watcher does not
    # kill robocopy — operator decides via Get-Content $LogFile -Wait.
    if (-not $DryRun) {
        $progressJob = Start-Job -ArgumentList $LogFile,$roboLog,$dst.Substring(0,1),$ProgressIntervalSec,$StallThresholdSec -ScriptBlock {
            param($logFile,$roboLog,$targetLetter,$intervalSec,$stallSec)
            # Active-data signal is the LogicalDisk write rate for the target.
            # E:used (preallocated file size) and robo_log size are both flat
            # while robocopy streams data into an already-opened large file
            # (e.g. the wbadmin VHDX, hundreds of GB), which produced false
            # STALL tags during the initial seed at ~4586 GB on 2026-05-10.
            # Treat any sustained write > 1 MB/s as evidence of progress.
            $counterPath = "\LogicalDisk($($targetLetter):)\Disk Write Bytes/sec"
            $lastChange = Get-Date
            while ($true) {
                Start-Sleep -Seconds $intervalSec
                $vol = Get-Volume -DriveLetter $targetLetter -ErrorAction SilentlyContinue
                if (-not $vol) {
                    Add-Content -LiteralPath $logFile -Value ('{0} — [progress] target volume not visible' -f (Get-Date -Format 'ddd MM/dd/yyyy HH:mm:ss.ff'))
                    continue
                }
                $used = $vol.Size - $vol.SizeRemaining
                $rsz  = if (Test-Path -LiteralPath $roboLog) { (Get-Item -LiteralPath $roboLog).Length } else { 0 }

                # Sample write rate over 2 seconds for a steadier signal.
                $writeMBps = 0.0
                try {
                    $s = Get-Counter -Counter $counterPath -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop
                    $writeMBps = ($s.CounterSamples | Measure-Object CookedValue -Average).Average / 1MB
                } catch {}

                $now = Get-Date
                if ($writeMBps -gt 1.0) { $lastChange = $now }
                $idleSec = [int]($now - $lastChange).TotalSeconds
                $tag = if ($idleSec -gt $stallSec) { ' STALL' } else { '' }
                $line = '{0} — [progress] {1}:used={2:N2}GB write={3:N1}MB/s robo_log={4}KB idle={5}s{6}' -f `
                    $now.ToString('ddd MM/dd/yyyy HH:mm:ss.ff'), $targetLetter, ($used/1GB), $writeMBps, [math]::Round($rsz/1KB,1), $idleSec, $tag
                Add-Content -LiteralPath $logFile -Value $line
            }
        }
        Write-Log "progress watcher started (job id=$($progressJob.Id), interval=${ProgressIntervalSec}s, stall=${StallThresholdSec}s)" 'mirror'
    }

    & robocopy.exe @roboArgs | Out-Null
    $roboRc = $LASTEXITCODE
    $summary.robocopy_rc = $roboRc

    # Robocopy rc: 0..7 = success, 8+ = failure
    if ($roboRc -ge 8) {
        throw "robocopy failed: rc=$roboRc (see $roboLog)"
    }
    Write-Log "robocopy rc=$roboRc (0..7 = success)" 'mirror'

    # Parse robocopy log for byte/file totals (best-effort)
    if (Test-Path -LiteralPath $roboLog) {
        $roboTail = Get-Content -LiteralPath $roboLog -Tail 30
        # Lines look like: "    Bytes :   1.234 g   ..."  and "    Files :   123   ..."
        $bytesLine = $roboTail | Where-Object { $_ -match '^\s*Bytes\s*:' } | Select-Object -First 1
        $filesLine = $roboTail | Where-Object { $_ -match '^\s*Files\s*:' } | Select-Object -First 1
        if ($bytesLine -match 'Bytes\s*:\s*([\d\.]+)\s*([kmgt]?)') {
            $n = [double]$Matches[1]
            switch ($Matches[2].ToLower()) {
                'k' { $n *= 1KB }
                'm' { $n *= 1MB }
                'g' { $n *= 1GB }
                't' { $n *= 1TB }
            }
            $summary.bytes = [int64]$n
        }
        if ($filesLine -match 'Files\s*:\s*(\d+)') { $summary.files = [int64]$Matches[1] }
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
    # to dodge -Command quoting hell). Hard 30s timeout — any orphan that
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
