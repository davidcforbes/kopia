# diagnose-signing.ps1 — Phase 1 of the cicd pipeline.
# Verifies every prerequisite for a successful Trusted Signing operation:
#   1. signing/metadata.json present + parses
#   2. signing/dlib/dlib.csproj version vs latest on NuGet
#   3. az CLI token valid + correct audience + correct identity
#   4. Role assignment present at the cert profile or account scope
#   5. Endpoint reachable over IPv4 (kopia-2vk: IPv6 to mgmt.azure.com is broken)
#   6. Sign API returns 400 (not 403) on empty POST — proves auth/RBAC OK
#   7. Bitdefender MITM CA NOT intercepting the signing endpoint
#
# Exit codes: 0 success, 1 expected failure with reason, 2 unexpected error.

[CmdletBinding()]
param([switch]$VerifyOnly)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\pipeline-state.ps1"

$run = Start-PhaseRun -Phase 'diagnose'

try {
$failures = @()
$warnings = @()
$repo = 'C:\dev\kopia'

Write-PhaseLog "[diagnose] Phase 1 — signing infrastructure preflight" -Level info

# Check 1 — metadata.json
try {
    $metaPath = Join-Path $repo 'signing\metadata.json'
    $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
    foreach ($f in 'Endpoint','CodeSigningAccountName','CertificateProfileName') {
        if (-not $meta.$f) { throw "metadata.json missing required field: $f" }
    }
    Write-PhaseLog "  [ok] metadata.json: $($meta.CodeSigningAccountName)/$($meta.CertificateProfileName)" -Level ok
} catch {
    $failures += "metadata.json: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] metadata.json: $($_.Exception.Message)" -Level err
}

# Check 2 — dlib version vs NuGet latest
try {
    $csproj = [xml](Get-Content (Join-Path $repo 'signing\dlib\dlib.csproj'))
    $pinned = ($csproj.Project.ItemGroup.PackageReference | Where-Object Include -eq 'Microsoft.Trusted.Signing.Client').Version
    $idx = Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/microsoft.trusted.signing.client/index.json' -ErrorAction Stop -TimeoutSec 10
    $latest = $idx.versions[-1]
    if ($pinned -ne $latest) {
        $warnings += "dlib pinned at $pinned; NuGet latest is $latest"
        Write-PhaseLog "  [WARN] dlib pin: $pinned (latest $latest)" -Level warn
    } else {
        Write-PhaseLog "  [ok] dlib pin: $pinned (matches NuGet latest)" -Level ok
    }
} catch {
    $warnings += "could not verify dlib version: $($_.Exception.Message)"
    Write-PhaseLog "  [WARN] dlib version check: $($_.Exception.Message)" -Level warn
}

# Check 3 — az token valid for codesigning audience
try {
    $az = (Get-Command az.cmd -ErrorAction SilentlyContinue).Source
    if (-not $az) { $az = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' }
    $rawToken = & $az account get-access-token --resource 'https://codesigning.azure.net' --query accessToken -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az get-access-token failed: $rawToken" }
    $payloadB64 = ($rawToken -split '\.')[1]
    while ($payloadB64.Length % 4 -ne 0) { $payloadB64 += '=' }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
        $payloadB64.Replace('-','+').Replace('_','/'))) | ConvertFrom-Json
    if ($claims.aud.TrimEnd('/') -ne 'https://codesigning.azure.net') {
        throw "token audience mismatch: $($claims.aud)"
    }
    $expiresIn = ([DateTimeOffset]::FromUnixTimeSeconds($claims.exp).LocalDateTime - (Get-Date)).TotalMinutes
    if ($expiresIn -lt 5) { throw "token expires in $([int]$expiresIn) min — refresh with az login" }
    Write-PhaseLog "  [ok] az token: $($claims.upn) ($([int]$expiresIn) min remaining)" -Level ok
    $script:tokenOid = $claims.oid
    $script:tokenUpn = $claims.upn
} catch {
    $failures += "az token: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] az token: $($_.Exception.Message)" -Level err
}

# Check 4 — role assignment present
if ($script:tokenOid -and $meta) {
    try {
        $scope = "/subscriptions/$($meta.SubscriptionId ?? '0dee2894-9caa-4e29-a059-6b241427c811')/resourceGroups/codesign/providers/Microsoft.CodeSigning/codeSigningAccounts/$($meta.CodeSigningAccountName)"
        $assignments = & $az role assignment list --assignee $script:tokenOid --scope $scope --include-inherited --query "[?roleDefinitionName=='Artifact Signing Certificate Profile Signer'].roleDefinitionName" -o tsv 2>&1
        if (-not $assignments) {
            $rec = "az role assignment create --assignee $($script:tokenOid) --role 'Artifact Signing Certificate Profile Signer' --scope `"$scope/certificateProfiles/$($meta.CertificateProfileName)`""
            $failures += "role 'Artifact Signing Certificate Profile Signer' not assigned to $($script:tokenUpn) at $scope or descendants"
            Write-PhaseLog "  [FAIL] no Signer role for $($script:tokenUpn)" -Level err
            Write-PhaseLog "         Suggested fix: $rec" -Level warn
            $script:roleFix = $rec
        } else {
            Write-PhaseLog "  [ok] Signer role assigned (visible at $scope or descendant)" -Level ok
        }
    } catch {
        $warnings += "role assignment check failed: $($_.Exception.Message)"
        Write-PhaseLog "  [WARN] role check: $($_.Exception.Message)" -Level warn
    }
}

# Check 5 — endpoint reachable over IPv4
# Use raw .NET TcpClient + DNS instead of Test-NetConnection (latter is broken
# under pwsh 7 on Win11: MI native type initializer fails).
try {
    $endpoint = $meta.Endpoint
    $epHost = ([uri]$endpoint).Host
    $v4 = [System.Net.Dns]::GetHostAddresses($epHost) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        Select-Object -First 1
    if (-not $v4) { throw "no IPv4 address resolved for $epHost" }
    $tcpClient = [System.Net.Sockets.TcpClient]::new()
    try {
        $iar = $tcpClient.BeginConnect($v4, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(5000, $false)) {
            throw "TCP to ${epHost}:443 ($v4) timed out after 5s"
        }
        $tcpClient.EndConnect($iar)
    } finally {
        $tcpClient.Dispose()
    }
    Write-PhaseLog "  [ok] $epHost reachable (v4: $v4)" -Level ok
} catch {
    $failures += "endpoint reachability: $($_.Exception.Message)"
    Write-PhaseLog "  [FAIL] endpoint: $($_.Exception.Message)" -Level err
}

# Check 6 — sign API returns 400 on empty POST (proves auth+RBAC OK; isolates dlib drift)
if ($VerifyOnly) {
    Write-PhaseLog "  [skip] sign API smoke probe (VerifyOnly mode)" -Level info
} elseif ($script:tokenOid -and $rawToken -and $meta) {
    try {
        $url = "$($meta.Endpoint)/codesigningaccounts/$($meta.CodeSigningAccountName)/certificateprofiles/$($meta.CertificateProfileName)/sign?api-version=2024-06-15"
        $curl = (Get-Command curl.exe).Source
        # Single-quoted '%{http_code}' is preserved literally by PowerShell; passed verbatim to curl.
        $resp = & $curl -4 -s -o NUL -w '%{http_code}' -X POST -H "Authorization: Bearer $rawToken" -H 'Content-Type: application/json' -d '{}' --max-time 15 $url 2>$null
        if ($resp -eq '400') {
            Write-PhaseLog "  [ok] sign API smoke probe: HTTP 400 (auth+RBAC accepted, body rejected as expected)" -Level ok
        } elseif ($resp -eq '403') {
            $failures += "sign API returns 403 — RBAC issue or service-side deny"
            Write-PhaseLog "  [FAIL] sign API: HTTP 403 — auth was rejected" -Level err
        } else {
            $warnings += "sign API smoke probe returned HTTP $resp (expected 400)"
            Write-PhaseLog "  [WARN] sign API: HTTP $resp" -Level warn
        }
    } catch {
        $warnings += "sign API smoke probe error: $($_.Exception.Message)"
        Write-PhaseLog "  [WARN] sign API probe: $($_.Exception.Message)" -Level warn
    }
}

# Check 7 — Bitdefender MITM CA in trust store (informational)
$bdCa = Get-ChildItem Cert:\CurrentUser\Root,Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -match 'Bitdefender' }
if ($bdCa) {
    $warnings += "Bitdefender MITM CA present in trust store ($(($bdCa | Select-Object -First 1).Thumbprint)) — verify HTTPS-scan exemptions if signing fails"
    Write-PhaseLog "  [WARN] Bitdefender MITM CA detected in trust store" -Level warn
} else {
    Write-PhaseLog "  [ok] no MITM CA in trust store" -Level ok
}

# Clear the access token from session memory before exit.
$rawToken = $null
Remove-Variable -Name rawToken -ErrorAction SilentlyContinue

# Verdict
$message = if ($failures) {
    "FAIL: $($failures.Count) failure(s); $($warnings.Count) warning(s)"
} elseif ($warnings) {
    "OK with $($warnings.Count) warning(s)"
} else {
    "all checks passed"
}

if ($failures) {
    Complete-PhaseRun -Run $run -Status 'failed' -Message $message -RecommendedAction ($script:roleFix)
    Write-PhaseLog "[diagnose] $message" -Level err
    foreach ($f in $failures) { Write-PhaseLog "  - $f" -Level err }
    exit 1
} else {
    Complete-PhaseRun -Run $run -Status 'ok' -Message $message
    Write-PhaseLog "[diagnose] $message" -Level ok
    foreach ($w in $warnings) { Write-PhaseLog "  - $w" -Level warn }
    exit 0
}
} catch {
    Write-PhaseLog "[diagnose] UNEXPECTED ERROR: $($_.Exception.Message)" -Level err
    Write-PhaseLog "  $($_.ScriptStackTrace)" -Level err
    try {
        Complete-PhaseRun -Run $run -Status 'failed' -Message "unexpected error: $($_.Exception.Message)"
    } catch {} # state lib itself might be broken
    exit 2
}
