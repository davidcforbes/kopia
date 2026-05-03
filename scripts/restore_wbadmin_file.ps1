#Requires -RunAsAdministrator
<#
Restore a single file from the most recent wbadmin system image.

  restore_wbadmin_file.ps1 -FilePath 'C:\dev\EUC\.pencil\EUC.pen'
  restore_wbadmin_file.ps1 -FilePath 'C:\dev\EUC\.pencil\EUC.pen' -OutputDir 'C:\Restored'

The latest backup is picked by lex-sorting the 'Backup YYYY-MM-DD HHMMSS' folder names.
The C: volume VHDX is identified as the largest .vhdx in that folder.
#>
param(
  [Parameter(Mandatory)][string]$FilePath,
  [string]$OutputDir,
  [string]$BackupRoot = 'D:\WindowsImageBackup\ChrisLaptop2'
)

$ErrorActionPreference = 'Stop'

if ($FilePath -notmatch '^[A-Za-z]:\\') {
  throw "FilePath must be an absolute path starting with a drive letter (e.g. C:\dev\foo.txt)"
}

$latest = Get-ChildItem -Path $BackupRoot -Directory -Filter 'Backup *' -ErrorAction Stop |
          Sort-Object Name -Descending | Select-Object -First 1
if (-not $latest) { throw "No 'Backup ...' folders found under $BackupRoot" }
Write-Host "Backup folder: $($latest.Name)"

$vhdx = Get-ChildItem -Path $latest.FullName -Filter '*.vhdx' |
        Sort-Object Length -Descending | Select-Object -First 1
if (-not $vhdx) { throw "No .vhdx files in $($latest.FullName)" }
Write-Host ("Mounting:      {0} ({1:N1} GB)" -f $vhdx.Name, ($vhdx.Length/1GB))

$assignedLetter = $null
$partition = $null
Mount-DiskImage -ImagePath $vhdx.FullName -Access ReadOnly | Out-Null

try {
  $disk = Get-DiskImage -ImagePath $vhdx.FullName | Get-Disk

  $partition = Get-Partition -DiskNumber $disk.Number |
               Where-Object { $_.Size -gt 1GB } |
               Sort-Object Size -Descending | Select-Object -First 1
  if (-not $partition) { throw "No data partition found on mounted VHDX" }

  if ($partition.DriveLetter) {
    $mountLetter = [string]$partition.DriveLetter
  } else {
    $used = (Get-Volume | Where-Object { $_.DriveLetter }).DriveLetter
    $candidate = @('V','W','X','Y','Z','U','T','S','R','Q','P') |
                 Where-Object { $used -notcontains $_ } | Select-Object -First 1
    if (-not $candidate) { throw "No free drive letter available for mount" }
    Add-PartitionAccessPath -DiskNumber $disk.Number `
                            -PartitionNumber $partition.PartitionNumber `
                            -AccessPath "${candidate}:\"
    $assignedLetter = $candidate
    $mountLetter = $candidate
  }
  Write-Host "Mount point:   ${mountLetter}:\"

  $relative = $FilePath.Substring(2)   # strip 'C:' leaving '\dev\EUC\...'
  $sourceFile = "${mountLetter}:${relative}"
  if (-not (Test-Path -LiteralPath $sourceFile)) {
    throw "File not present in backup: $sourceFile"
  }

  if (-not $OutputDir) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = Join-Path ([Environment]::GetFolderPath('Desktop')) "wbadmin-restore-$stamp"
  }
  New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
  $destFile = Join-Path $OutputDir (Split-Path -Leaf $FilePath)
  Copy-Item -LiteralPath $sourceFile -Destination $destFile -Force

  $info = Get-Item -LiteralPath $destFile
  Write-Host ("Restored:      {0}" -f $destFile)
  Write-Host ("               {0:N0} bytes, mtime {1}" -f $info.Length, $info.LastWriteTime)
}
finally {
  if ($assignedLetter -and $partition) {
    Remove-PartitionAccessPath -DiskNumber (Get-DiskImage -ImagePath $vhdx.FullName | Get-Disk).Number `
                               -PartitionNumber $partition.PartitionNumber `
                               -AccessPath "${assignedLetter}:\" -ErrorAction SilentlyContinue
  }
  Dismount-DiskImage -ImagePath $vhdx.FullName | Out-Null
  Write-Host "Detached."
}
