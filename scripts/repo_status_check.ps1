# repo_status_check.ps1 -- Run kopia repo status with a hard timeout
# Usage: repo_status_check.ps1 -KopiaBin <path> -ConfigFile <path> -LogFile <path> [-TimeoutSec 120]
#
# Redirects kopia's stdout/stderr to temp files via ProcessStartInfo so a
# full pipe buffer cannot stall the parent. Enforces -TimeoutSec hard deadline
# via WaitForExit(ms). Previous implementation used .StandardOutput.ReadToEnd()
# synchronously before WaitForExit, which defeated the timeout entirely.

param(
    [Parameter(Mandatory=$true)] [string]$KopiaBin,
    [Parameter(Mandatory=$true)] [string]$ConfigFile,
    [Parameter(Mandatory=$true)] [string]$LogFile,
    [int]$TimeoutSec = 120
)

function Write-TaggedLine {
    param([string]$Path, [string]$Text)
    $ts = Get-Date -Format 'ddd MM/dd/yyyy  HH:mm:ss.ff'
    Add-Content -LiteralPath $Path -Value "$ts - [repo-check] $Text"
}

$tmpOut = [IO.Path]::Combine($env:TEMP, "kopia_repo_status_out_$PID.txt")
$tmpErr = [IO.Path]::Combine($env:TEMP, "kopia_repo_status_err_$PID.txt")

try {
    # Use Start-Process with -RedirectStandardOutput/Error to files and pass through.
    $p = Start-Process -FilePath $KopiaBin `
        -ArgumentList @("--config-file=$ConfigFile", "repository", "status") `
        -RedirectStandardOutput $tmpOut `
        -RedirectStandardError $tmpErr `
        -NoNewWindow `
        -PassThru

    $exited = $p.WaitForExit($TimeoutSec * 1000)

    if (-not $exited) {
        try { $p.Kill() } catch { }
        Write-TaggedLine -Path $LogFile -Text "TIMEOUT: killed kopia after ${TimeoutSec}s"
        exit 99
    }

    if (Test-Path $tmpOut) {
        $so = Get-Content -LiteralPath $tmpOut -Raw -ErrorAction SilentlyContinue
        if ($so) { Add-Content -LiteralPath $LogFile -Value $so.TrimEnd() }
    }
    if (Test-Path $tmpErr) {
        $se = Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue
        if ($se) { Add-Content -LiteralPath $LogFile -Value $se.TrimEnd() }
    }

    exit $p.ExitCode
}
catch {
    Write-TaggedLine -Path $LogFile -Text ("EXCEPTION: " + $_.Exception.Message)
    exit 98
}
finally {
    Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpErr -ErrorAction SilentlyContinue
}
