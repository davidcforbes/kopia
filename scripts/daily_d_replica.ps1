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
    # System / transient dirs are excluded by name. The single top-level
    # ISO (Win11_25H2_*.iso) is intentionally skipped (replaceable media,
    # would need a single-file-mode backup-mirror invocation).
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
    $EXCLUDE_TOP = @('$RECYCLE.BIN', 'System Volume Information', 'BackupMonitorIndex', 'Sysmon')
    $topEntries  = Get-ChildItem -LiteralPath $shadowPath -Force -ErrorAction Stop |
                   Where-Object { $_.PSIsContainer -and ($EXCLUDE_TOP -notcontains $_.Name) }
    $skippedFiles = Get-ChildItem -LiteralPath $shadowPath -File -Force -ErrorAction SilentlyContinue
    foreach ($f in $skippedFiles) {
        Write-Log "skipping top-level file (no single-file cbt mode): $($f.Name)" 'mirror'
    }
    if (-not $topEntries) { throw "no top-level subdirs found on shadow ($shadowPath)" }
    Write-Log ("subtrees to mirror: " + (($topEntries | ForEach-Object Name) -join ', ')) 'mirror'

    $worstRc        = 0
    $aggBytes       = [int64]0
    $aggFiles       = [int64]0
    $aggChunksChg   = [int64]0
    $aggChunksTot   = [int64]0
    $perTreeReports = @()

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

        Write-Log ("[{0}] launching: mode=cbt manifest-key={1} dst={2}" -f $treeName, $manifestKey, $dstPath) 'mirror'
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
# MII9bQYJKoZIhvcNAQcCoII9XjCCPVoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCpuVPNxoWVmfyf
# RoMOqV/foCO5pG5f98Z1lfQcntsy0aCCIjAwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# AQkEMSIEIFO7h2modWwj9FNXJUcCU1VQTN+366BID88Xusd4uLkXMA0GCSqGSIb3
# DQEBAQUABIIBgENdNQ1ldaWoSYc8lofgxwmIPNWsK2SanxMG4DB1Cer4zAQGhq2R
# P7BgOtbwEmDQjLiXyLTcZOV1T88yJkEMgFNfRps7S9d3sdYWdu7/koYv72RfRvsC
# gkPB4ymA6Fe7jCHN7sNfpa1PetAWejzxqx52bhP+3pn+wExctLYvXXaSONFWzeQE
# S5kcNzvQVYIoHZXR9L3Q6cH5bYUq1pvQF+LhCwQBo7TWlJagZnWRHH3g+OjxOmWN
# E4SG0vXzzevzE3bpbI3FxFidQiI3tGOSaLT52o4xRCSw+rwmFu970J1EW2ivukT1
# buy9JtCF0qWOq5QVWYUu6jgFnLHwfONt0kIspZgyZbFSRc4bJbzOqxzzmYcZ0i5z
# cqDxJ+6mUKMJGaFOecGM/3bmi9ioRpHKCWNsqRcnGLRvPtTebPlApKKn1atlBwfe
# lNdxr71esooM79WWs756rlPfurF/o8rnBMEQdR46pR0Ct2vQE+hxSRAAT+vq/AWr
# XCIHriaWct5kU6GCGBMwghgPBgorBgEEAYI3AwMBMYIX/zCCF/sGCSqGSIb3DQEH
# AqCCF+wwghfoAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFhBgsqhkiG9w0BCRABBKCC
# AVAEggFMMIIBSAIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBoQGS5
# DolDTsaCQLHdunqP+y6AOSXgQ/gJdCgeL206FQIGaeiBIh0uGBIyMDI2MDUxNDA1
# NDAwNC43NlowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlv
# bnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RDAwLTA1RTAtRDk0NzE1MDMG
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
# fiWG2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFXZ3WkmKPn44gAAAAAAVTAN
# BgkqhkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NDlaFw0yNjEwMjIyMDQ2NDla
# MIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQL
# ExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxk
# IFRTUyBFU046N0QwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJs
# aWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAvbkfkh5ZSLP0MCUWafaw/KZoVZu9iQx8r5JwhZvdrUi8
# 6UjCCFQONjQanrIxGF9hRGIZLQZ50gHrLC+4fpUEJff5t04VwByWC2/bWOuk6Nma
# Th9JpPZDcGzNR95QlryjfEjtl+gxj12zNPEdADPplVfzt8cYRWFBx/Fbfch08k6P
# 9p7jX2q1jFPbUxWYJ+xOyGC1aKhDGY5b+8wL39v6qC0HFIx/v3y+bep+aEXooK8V
# oeWK+szfaFjXo8YTcvQ8UL4szu9HFTuZNv6vvoJ7Ju+o5aTj51sph+0+FXW38TlL
# /rDBd5ia79jskLtOeHbDjkbljilwzegcxv9i49F05ZrS/5ELZCCY1VaqO7EOLKVa
# xxdAO5oy1vb0Bx0ZRVX1mxFjYzay2EC051k6yGJHm58y1oe2IKRa/SM1+BTGse6v
# HNi5Q2d5ZnoR9AOAUDDwJIIqRI4rZz2MSinh11WrXTG9urF2uoyd5Ve+8hxes9AB
# eP2PYQKlXYTAxvdaeanDTQ/vwmnM+yTcWzrVm84Z38XVFw4G7p/ZNZ2nscvv6uru
# 2AevXcyV1t8ha7iWmhhgTWBNBrViuDlc3iPvOz2SVPbPeqhyY/NXwNZCAgc2H5pO
# ztu6MwQxDIjte3XM/FkKBxHofS2abNT/0HG+xZtFqUJDaxgbJa6lN1zh7spjuQ8C
# AwEAAaOCAcswggHHMB0GA1UdDgQWBBRWBF8QbdwIA/DIv6nJFsrB16xltjAfBgNV
# HSMEGDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6Bdhlto
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQ
# dWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsG
# AQUFBwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3Rh
# bXBpbmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAww
# CgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGC
# N0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEM
# BQADggIBAFIe4ZJUe9qUKcWeWypchB58fXE/ZIWv2D5XP5/k/tB7LCN9BvmNSVKZ
# 3VeclQM978wfEvuvdMQSUv6Y20boIM8DK1K1IU9cP21MG0ExiHxaqjrikf2qbfrX
# Iip4Ef3v2bNYKQxCxN3Sczp1SX0H7uqK2L5OhfDEiXf15iou5hh+EPaaqp49czNQ
# pJDOR/vfJghUc/qcslDPhoCZpZx8b2ODvywGQNXwqlbsmCS24uGmEkQ3UH5JUeN6
# c91yasVchS78riMrm6R9ZpAiO5pfNKMGU2MLm1A3pp098DcbFTAc95Hh6Qvkh//2
# 8F/Xe2bMFb6DL7Sw0ZO95v0gv0ZTyJfxS/LCxfraeEII9FSFOKAMEp1zNFSs2ue0
# GGjBt9yEEMUwvxq9ExFz0aZzYm8ivJfffpIVDnX/+rVRTYcxIkQyFYslIhYlWF9S
# jCw5r49qakjMRNh8W9O7aaoolSVZleQZjGt0K8JzMlyp6hp2lbW6XqRx2cOHbbxJ
# DxmENzohGUziI13lI2g2Bf5qibfC4bKNRpJo9lbE8HUbY0qJiE8u3SU8eDQaySPX
# OEhJjxRCQwwOvejYmBG5P7CckQNBSnnl12+FKRKgPoj0Mv+z5OMhj9z2MtpbnHLA
# kep0odQClEyyCG/uR5tK5rW6mZH5Oq56UWS0NI6NV1JGS7Jri6jFMYIHRjCCB0IC
# AQEweDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTANBglghkgBZQMEAgEFAKCCBJ8w
# EQYLKoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAc
# BgkqhkiG9w0BCQUxDxcNMjYwNTE0MDU0MDA0WjAvBgkqhkiG9w0BCQQxIgQg9294
# cV5O/dGKJ28Ji2emEDInEqcpqeZ1ObYyeY5qpJ4wgbkGCyqGSIb3DQEJEAIvMYGp
# MIGmMIGjMIGgBCDYuTyXZIZiu799/v4PaqsmeSzBxh0rqkYq7sYYavj+zTB8MGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTCCA2EGCyqGSIb3DQEJEAISMYIDUDCC
# A0yhggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBP
# cGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5
# NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcg
# QXV0aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQAdO1QBgmW/tuBZV5EGjhfsV4cN6qBn
# MGWkYzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcg
# Q0EgMjAyMDANBgkqhkiG9w0BAQsFAAIFAO2vV68wIhgPMjAyNjA1MTMyMDAzNTla
# GA8yMDI2MDUxNDIwMDM1OVowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7a9XrwIB
# ADAKAgEAAgIucAIB/zAHAgEAAgITNjAKAgUA7bCpLwIBADA2BgorBgEEAYRZCgQC
# MSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqG
# SIb3DQEBCwUAA4IBAQCAY2kCaZ5ayUG3ZCTpY0l6lQ7J8tCAVQ9FwOiNAJHMvc9Q
# Ef2n8GATLkJj3C76bO5DnZ3C3dp62SQ7PMmiziKcqfXJwtirxE3mWgpOztLgtGhr
# n901pAQz25AvZGbhrHIbQ7aL9ohR/r63mKJia2/Uf0+Vipl/s4LfEhfBIWk+kKhv
# QATwHhhx4z5/X0yAXhJvJyvnz/J1qEmywzDbMDI23rjfdqogEnGXQHBOw/K0jO4J
# v416glecP0gP0u3fW+W4SIQ1vbzRB/WY8Y24y02m3eGYy2XwxQCqB4Ssk8raWwD8
# IV5/4H9RYiXLyx6ZEcyi+LTYeCVXvfnG5VCpyFtOMA0GCSqGSIb3DQEBAQUABIIC
# AGSaJS6CCa7fh11BStsZYnqnVmyh8VanAWCg2xrITbscjfn5a4Isr7rpt977VmAd
# +oh9Zbo6K9u9CwOElBSi7Ld1SDjQGaSH9t44x2XDiXSGprNitbDJQyqTgg2Jd9Px
# fE2wqUHhXR8R4llwa1ZPETZeKepxhafKtcRBA7vvK6G0tsqYoAQ4bQvaw5wuhMg3
# 2ZJho8vMFy7cNvejDJJmVCL7ld+V90OMDaNbP1sndh1JvYfhtsd9SOZkUXPgst2h
# 7chnBxEuIgEod/IYxxnWK6mVnL5srZ7/A/Eg0hPpaLKYSJMn8wMfK03bi4xMOIRw
# EwgSQI+Fntxc6DSWJLxONCuS8SBfcBh8A9URoTKswvW9ofNjWoBUVxAuA3tcsGGu
# zdzs+y8d+GmZTpsDBOKhlcXFv7GvhSNksQcDUvmquQ8jwEasVXIb9p9xkUlQNhtq
# jCYptkBiOA22SEWSDRbWxaTht+ITvTFt1uSujf5PmELh+IE4tyRCHSbhoxzLTzqR
# VtxrEfsl+5PmdY2AUs2x1O8/hiOKUHYAFqtb4gmMaQ6ejPYv+/1/W/oqypxe3wZj
# P71xuPjwP61aH0B5+rb4AjjHM+DkTxtyd5kMTFRbql+G8vb68nNY8VcVxtR7O96A
# hBITVdALU76CkICvoj6z20Lwu7bO9hVZy/MIG7R1UoOT
# SIG # End signature block
