# One-shot helper after password rotation:
#   1. Prompt for new password (SecureString, never visible)
#   2. Verify by running `kopia repository status` with KOPIA_PASSWORD env
#   3. Write new DPAPI-encrypted file at scripts\.kopia-pw.dat
#   4. Rewrite daily_kopia_backup.cmd to replace the hardcoded KOPIA_PASSWORD line
# Password is held only in a local variable and zeroed before exit.

$ErrorActionPreference = 'Stop'

$kopiaBin   = 'C:\Users\david\go\bin\kopia.exe'
$configFile = 'C:\Users\david\AppData\Roaming\kopia\repository.config'
$dpapiFile  = 'C:\dev\kopia\scripts\.kopia-pw.dat'
$cmdPath    = 'C:\dev\kopia\scripts\daily_kopia_backup.cmd'

Write-Host "Enter NEW kopia repository password (input hidden):"
$secure = Read-Host -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

try {
    # Step 2: verify + reconnect in one shot. `kopia repository connect`
    # will fail if the password is wrong, and on success it restores the
    # user-scope Credential Manager entry so interactive kopia stops prompting.
    # Disconnect first so connect is idempotent if the repo is already linked.
    # Native exes that write to stderr would trip $ErrorActionPreference=Stop,
    # so relax it around the kopia calls and check $LASTEXITCODE manually.
    Write-Host "Verifying password by reconnecting to the repository..."
    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $kopiaBin repository disconnect 2>&1 | Out-Null
        $env:KOPIA_PASSWORD = $pw
        & $kopiaBin repository connect filesystem --path D:\KopiaRepo 2>&1 | Out-Null
        $verifyRc = $LASTEXITCODE
    } finally {
        Remove-Item Env:\KOPIA_PASSWORD -ErrorAction SilentlyContinue
        $ErrorActionPreference = $savedEAP
    }
    if ($verifyRc -ne 0) {
        throw "kopia repository connect failed (rc=$verifyRc). Wrong password?"
    }
    Write-Host "OK: password verified and repository reconnected."

    # Guard: characters that can't be embedded in cmd `set "KEY=VAL"`
    if ($pw.Contains('"')) {
        throw "Password contains a double-quote character; cannot safely hardcode in cmd file."
    }

    # Step 3: write DPAPI-encrypted file (machine scope).
    # Existing file has lockdown ACL (Administrators:R, SYSTEM:R — no Write)
    # so we clear the ACL, overwrite, then re-apply lockdown.
    Add-Type -AssemblyName System.Security
    $enc = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($pw), $null,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)

    if (Test-Path -LiteralPath $dpapiFile) {
        & icacls $dpapiFile /reset *> $null
    }
    [IO.File]::WriteAllBytes($dpapiFile, $enc)
    # Re-apply lockdown: inheritance off, only SYSTEM and Administrators can read.
    & icacls $dpapiFile /inheritance:r /grant:r "SYSTEM:(R)" "Administrators:(R)" *> $null
    Write-Host "OK: DPAPI file updated ($((Get-Item $dpapiFile).Length) bytes, ACL re-locked)."

    # Step 4: rewrite any literal `set "KOPIA_PASSWORD=..."` line in
    # daily_kopia_backup.cmd. As of 2026-05-01 the wrapper relies entirely
    # on kopia's persisted creds (no env var), so this is a best-effort
    # legacy hook: if the pattern is present we update it, otherwise we
    # skip silently. This used to throw, which made step 3's success
    # invisible in the script's exit code.
    $pwEsc = $pw -replace '%', '%%'
    $newLine = "set `"KOPIA_PASSWORD=$pwEsc`""
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $cmdContent = [IO.File]::ReadAllText($cmdPath, $utf8NoBom)
    $pattern = '(?m)^set "KOPIA_PASSWORD=[^"]*"'
    if ($cmdContent -match $pattern) {
        $cmdContent = [regex]::Replace($cmdContent, $pattern, { param($m) $newLine })
        [IO.File]::WriteAllText($cmdPath, $cmdContent, $utf8NoBom)
        Write-Host "OK: daily_kopia_backup.cmd updated."
    } else {
        Write-Host "Skipped: daily_kopia_backup.cmd has no literal KOPIA_PASSWORD line (uses persisted creds)."
    }

    Write-Host ""
    Write-Host "DONE. Next: fire the V2 task to confirm end-to-end."
}
finally {
    $pw = $null
    [GC]::Collect()
}
