Add-Type -AssemblyName System.Security
$enc = [IO.File]::ReadAllBytes('C:\dev\kopia\scripts\.kopia-pw.dat')
$plain = [Text.Encoding]::UTF8.GetString(
    [Security.Cryptography.ProtectedData]::Unprotect(
        $enc, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine))
Write-Output $plain
