# pre_backup_scan.ps1 — Pre-backup scanner for Kopia
# Identifies: large directory trees (stall risk), locked files, and new unexcluded heavy dirs
# Run before kopia snapshot to proactively update .kopiaignore
param(
    [string]$BackupRoot = "C:\Users\david",
    [string]$KopiaIgnoreFile = "C:\Users\david\.kopiaignore",
    [string]$ScanLog = "C:\dev\kopia\logs\pre_backup_scan.log",
    [int]$FileCountThreshold = 3000,
    [int]$DirSizeThresholdMB = 500,
    [int]$MaxDepth = 4,
    [switch]$AutoExclude
)

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$newExclusions = @()

# Load existing .kopiaignore patterns
$existingPatterns = @()
if (Test-Path $KopiaIgnoreFile) {
    $existingPatterns = Get-Content $KopiaIgnoreFile | Where-Object { $_ -and $_ -notmatch '^\s*#' }
}

function Test-Excluded {
    param([string]$RelPath)
    foreach ($pattern in $existingPatterns) {
        $p = $pattern.TrimEnd('/')
        if ($RelPath -like "*$p*") { return $true }
    }
    return $false
}

function Get-RelativePath {
    param([string]$FullPath)
    $FullPath.Substring($BackupRoot.Length + 1).Replace('\', '/')
}

"[$timestamp] Pre-backup scan started" | Out-File $ScanLog -Encoding UTF8
"Backup root: $BackupRoot" | Out-File $ScanLog -Append
"Thresholds: $FileCountThreshold files or ${DirSizeThresholdMB}MB" | Out-File $ScanLog -Append
"" | Out-File $ScanLog -Append

# --- Phase 1: Scan for heavy directories ---
"=== Phase 1: Scanning for heavy directories ===" | Out-File $ScanLog -Append
Write-Host "Phase 1: Scanning for heavy directories (>$FileCountThreshold files or >${DirSizeThresholdMB}MB)..."

$heavyDirs = @()
$scannedCount = 0

# Walk top-level dirs first, skip already-excluded ones early
$topDirs = Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue
foreach ($topDir in $topDirs) {
    $rel = Get-RelativePath $topDir.FullName
    if (Test-Excluded $rel) { continue }

    # Recurse into subdirs up to MaxDepth
    $subDirs = @($topDir)
    try {
        $subDirs += Get-ChildItem $topDir.FullName -Directory -Recurse -Depth $MaxDepth -ErrorAction SilentlyContinue
    } catch {}

    foreach ($dir in $subDirs) {
        $relPath = Get-RelativePath $dir.FullName
        if (Test-Excluded $relPath) { continue }

        $scannedCount++
        try {
            $items = [System.IO.Directory]::GetFiles($dir.FullName, "*", [System.IO.SearchOption]::AllDirectories)
            $fileCount = $items.Count
        } catch {
            continue
        }

        if ($fileCount -ge $FileCountThreshold) {
            # Get total size
            $totalSize = 0
            try {
                foreach ($f in $items) {
                    $totalSize += (New-Object System.IO.FileInfo $f).Length
                }
            } catch {}
            $sizeMB = [math]::Round($totalSize / 1MB, 1)

            $entry = [PSCustomObject]@{
                Path      = $relPath
                Files     = $fileCount
                SizeMB    = $sizeMB
                Excluded  = $false
            }
            $heavyDirs += $entry
            "  HEAVY: $relPath ($fileCount files, ${sizeMB}MB)" | Out-File $ScanLog -Append

            # Don't recurse into children of heavy dirs (already counted)
            break
        }
    }
}

"Scanned $scannedCount directories" | Out-File $ScanLog -Append

# --- Phase 2: Scan for locked files in common problem areas ---
"" | Out-File $ScanLog -Append
"=== Phase 2: Scanning for locked files ===" | Out-File $ScanLog -Append
Write-Host "Phase 2: Scanning for locked files..."

$lockedFiles = @()
$lockScanPaths = @(
    "AppData\Local\Intel",
    "AppData\Local\Microsoft",
    "AppData\Roaming\discord",
    "AppData\Roaming\Thunderbird",
    "AppData\Local\Perplexity",
    "AppData\Roaming\ReadirisPDF23"
)

foreach ($subPath in $lockScanPaths) {
    $fullPath = Join-Path $BackupRoot $subPath
    if (-not (Test-Path $fullPath)) { continue }
    $relSub = $subPath.Replace('\', '/')
    if (Test-Excluded $relSub) { continue }

    try {
        $files = Get-ChildItem $fullPath -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 500
        foreach ($file in $files) {
            try {
                $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'None')
                $stream.Close()
            } catch {
                $relFile = Get-RelativePath $file.FullName
                $lockedFiles += $relFile
                "  LOCKED: $relFile" | Out-File $ScanLog -Append
            }
        }
    } catch {}
}

"Found $($lockedFiles.Count) locked files" | Out-File $ScanLog -Append

# --- Phase 3: Recommend or auto-add exclusions ---
"" | Out-File $ScanLog -Append
"=== Phase 3: Exclusion recommendations ===" | Out-File $ScanLog -Append

# Determine parent dirs for locked files (exclude at dir level, not per-file)
$lockedDirSet = @{}
foreach ($lf in $lockedFiles) {
    $parts = $lf -split '/'
    # Find the most specific AppData subdir (3 levels deep)
    $depth = [Math]::Min(4, $parts.Count - 1)
    $dirKey = ($parts[0..$depth] -join '/') + '/'
    if (-not $lockedDirSet.ContainsKey($dirKey)) {
        $lockedDirSet[$dirKey] = 0
    }
    $lockedDirSet[$dirKey]++
}

# Combine heavy dirs and locked-file dirs
foreach ($hd in $heavyDirs) {
    $key = $hd.Path + '/'
    if (-not $lockedDirSet.ContainsKey($key)) {
        $newExclusions += $key
    }
}
foreach ($ld in $lockedDirSet.Keys) {
    $newExclusions += $ld
}

# Deduplicate and filter already-excluded
$newExclusions = $newExclusions | Sort-Object -Unique | Where-Object { -not (Test-Excluded $_) }

if ($newExclusions.Count -eq 0) {
    $msg = "No new exclusions needed. All heavy/locked paths are already covered."
    Write-Host $msg
    $msg | Out-File $ScanLog -Append
} else {
    Write-Host ""
    Write-Host "=== New exclusions recommended ==="
    foreach ($ex in $newExclusions) {
        Write-Host "  + $ex"
        "  RECOMMEND: $ex" | Out-File $ScanLog -Append
    }

    if ($AutoExclude) {
        Write-Host ""
        Write-Host "Auto-adding to $KopiaIgnoreFile..."
        "" | Out-File $KopiaIgnoreFile -Append -Encoding UTF8
        "# Auto-added by pre-backup scan on $timestamp" | Out-File $KopiaIgnoreFile -Append -Encoding UTF8
        foreach ($ex in $newExclusions) {
            $ex | Out-File $KopiaIgnoreFile -Append -Encoding UTF8
            "  ADDED: $ex" | Out-File $ScanLog -Append
        }
        Write-Host "Added $($newExclusions.Count) exclusion(s) to .kopiaignore"
    } else {
        Write-Host ""
        Write-Host "Run with -AutoExclude to add these automatically."
    }
}

# --- Summary ---
"" | Out-File $ScanLog -Append
"=== Scan Summary ===" | Out-File $ScanLog -Append
$summary = @(
    "Directories scanned: $scannedCount",
    "Heavy directories found: $($heavyDirs.Count)",
    "Locked files found: $($lockedFiles.Count)",
    "New exclusions: $($newExclusions.Count)",
    "Existing .kopiaignore rules: $($existingPatterns.Count)"
)
foreach ($s in $summary) {
    $s | Out-File $ScanLog -Append
    Write-Host $s
}
"[$timestamp] Pre-backup scan complete" | Out-File $ScanLog -Append
Write-Host ""

# Return exit code: 0 = clean, 1 = new exclusions found but not applied
if ($newExclusions.Count -gt 0 -and -not $AutoExclude) {
    exit 1
} else {
    exit 0
}
