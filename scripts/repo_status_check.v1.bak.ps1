# repo_status_check.ps1 — Run kopia repo status with a timeout
# Usage: repo_status_check.ps1 -KopiaBin <path> -ConfigFile <path> -LogFile <path> [-TimeoutSec 120]
param(
    [string]$KopiaBin,
    [string]$ConfigFile,
    [string]$LogFile,
    [int]$TimeoutSec = 120
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $KopiaBin
$psi.Arguments = "--config-file=`"$ConfigFile`" repository status"
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

try {
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $exited = $p.WaitForExit($TimeoutSec * 1000)

    if (-not $exited) {
        $p.Kill()
        Add-Content $LogFile "$(Get-Date -Format 'ddd MM/dd/yyyy  HH:mm:ss.ff') — [repo-check] TIMEOUT: killed after ${TimeoutSec}s"
        exit 99
    }

    if ($stdout) { Add-Content $LogFile $stdout }
    if ($stderr) { Add-Content $LogFile $stderr }
    exit $p.ExitCode
}
catch {
    Add-Content $LogFile "$(Get-Date -Format 'ddd MM/dd/yyyy  HH:mm:ss.ff') — [repo-check] EXCEPTION: $_"
    exit 98
}
