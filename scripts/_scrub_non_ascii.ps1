# _scrub_non_ascii.ps1 -- one-time hygiene helper (kopia-tik).
#
# For each *.ps1 in scripts/, replaces common smart-typography Unicode chars
# with ASCII equivalents and writes the file back as UTF-8 with BOM. This
# protects against the failure mode discovered 2026-05-12 where PS 5.1
# (which the \Backup\DailyDReplica task uses) reads BOM-less UTF-8 as
# Windows-1252 and treats byte 0x94 (the third byte of UTF-8 em-dash) as a
# curly close-quote, terminating any double-quoted string mid-line.
#
# Substitutions are conservative; ASCII content is byte-identical after the
# pass. Signatures are invalidated by content edits and must be reapplied
# via signing/sign-all.ps1.
#
# Source file is pure-ASCII by construction: char keys are built via [char]
# casts at runtime, so this script can re-run under PS 5.1 even when its
# own file is BOM-less.
#
# Run with -WhatIf to preview, or -Verify to scan without modifying.

[CmdletBinding()]
param(
    [string]$Root,
    [switch]$WhatIf,
    [switch]$Verify
)

if (-not $Root) { $Root = $PSScriptRoot }
if (-not $Root) { $Root = (Get-Location).Path }

$subs = [ordered]@{
    ([char]0x2014) = '--'    # em-dash
    ([char]0x2013) = '-'     # en-dash
    ([char]0x201C) = '"'     # left double curly quote
    ([char]0x201D) = '"'     # right double curly quote
    ([char]0x2018) = "'"     # left single curly quote
    ([char]0x2019) = "'"     # right single curly quote
    ([char]0x2026) = '...'   # ellipsis
    ([char]0x00B1) = '+/-'   # plus-minus
    ([char]0x00A0) = ' '     # non-breaking space
    ([char]0x00B7) = '*'     # middle dot
    ([char]0x2022) = '*'     # bullet
    ([char]0x2190) = '<-'    # left arrow
    ([char]0x2191) = '^'     # up arrow
    ([char]0x2192) = '->'    # right arrow
    ([char]0x2193) = 'v'     # down arrow
    ([char]0x2264) = '<='    # less-than-or-equal
    ([char]0x2265) = '>='    # greater-than-or-equal
    ([char]0x2260) = '!='    # not-equal
    ([char]0x00D7) = 'x'     # multiplication sign
    ([char]0x00B0) = 'deg'   # degree sign
}

$utf8WithBom = New-Object System.Text.UTF8Encoding($true)

# Residual non-ASCII detector: anything outside U+0000..U+007F still left
# after substitution. Pattern built from [char] casts so this source stays
# pure ASCII.
$residualPattern = '[' + [char]0x80 + '-' + [char]0xFFFF + ']'
$residualRe      = [regex]$residualPattern

$files = Get-ChildItem -LiteralPath $Root -Filter *.ps1 -File |
    Where-Object { $_.Name -ne '_scrub_non_ascii.ps1' } |
    Sort-Object Name

$totalFiles   = 0
$changedFiles = 0
$reportRows   = @()

foreach ($f in $files) {
    $totalFiles++
    $bytes  = [System.IO.File]::ReadAllBytes($f.FullName)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = [System.Text.Encoding]::UTF8.GetString($bytes)
    # Strip a stray leading U+FEFF (UTF8.GetString does not consume the BOM),
    # otherwise WriteAllText with UTF8(true) would emit a double BOM.
    if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
        $text = $text.Substring(1)
    }
    $orig   = $text

    $subCounts = @{}
    foreach ($k in @($subs.Keys)) {
        $needle = [string]$k
        $count = ($text.Length - $text.Replace($needle,'').Length) / $needle.Length
        if ($count -gt 0) {
            $subCounts[[int][char]$k] = [int]$count
            $text = $text.Replace($needle, $subs[$k])
        }
    }

    $residual = $residualRe.Matches($text).Count
    $changed  = ($text -ne $orig) -or (-not $hadBom)

    $reportRows += [pscustomobject]@{
        File      = $f.Name
        HadBOM    = $hadBom
        Subs      = if ($subCounts.Count) {
                      ($subCounts.GetEnumerator() | Sort-Object Name | ForEach-Object {
                         'U+{0:X4}x{1}' -f $_.Key, $_.Value
                      }) -join ','
                    } else { '' }
        Residual  = $residual
        WillWrite = $changed
    }

    if ($Verify) { continue }

    if ($changed -and -not $WhatIf) {
        $tmp = "$($f.FullName).new"
        [System.IO.File]::WriteAllText($tmp, $text, $utf8WithBom)
        Move-Item -LiteralPath $tmp -Destination $f.FullName -Force
        $changedFiles++
    }
}

$reportRows | Format-Table -AutoSize -Wrap

Write-Host ''
Write-Host ("Total .ps1 files scanned: {0}" -f $totalFiles)
if ($Verify)     { Write-Host "Verify-only: no writes performed." }
elseif ($WhatIf) { Write-Host "WhatIf: no writes performed." }
else             { Write-Host ("Files rewritten:          {0}" -f $changedFiles) }

if ($reportRows | Where-Object { $_.Residual -gt 0 }) {
    Write-Host ''
    Write-Host "WARNING: residual non-ASCII characters remain in some files (see Residual column above). Review and add to substitution map." -ForegroundColor Yellow
}
