# ============================================================
# check-locales.ps1 - machine invariant for the UI text layer.
#
# Why this exists: a missing locale key does NOT throw in this app.
# The T() helper returns the key name or an empty string, so the window
# renders a blank label. That is invisible in a screenshot review and
# survives every syntax check - exactly how the bridge key button shipped
# with an empty status line. Only a cross-check between the code and
# strings.json catches it, so it runs as a gate before deploy.
#
# Checks:
#   1. every (T 'key') referenced in ClodKeyProxy.ps1 exists in EVERY locale
#   2. locales agree with each other (no skew) - otherwise switching the
#      language blanks text that worked a second earlier
# ============================================================
$ErrorActionPreference = 'Stop'

$root        = $PSScriptRoot
$appPath     = Join-Path $root 'app-next\ClodKeyProxy.ps1'
$stringsPath = Join-Path $root 'app-next\strings.json'

Write-Host '=== check-locales: Clod-key-proxy ==='
Write-Host ('app     : ' + $appPath)
Write-Host ('strings : ' + $stringsPath)

if (-not (Test-Path -LiteralPath $appPath))     { Write-Host 'MISSING app script';  exit 2 }
if (-not (Test-Path -LiteralPath $stringsPath)) { Write-Host 'MISSING strings.json'; exit 2 }

$src  = Get-Content -LiteralPath $appPath -Raw -Encoding UTF8
$json = Get-Content -LiteralPath $stringsPath -Raw -Encoding UTF8 | ConvertFrom-Json

$locales = @($json.PSObject.Properties.Name)
Write-Host ('locales : ' + ($locales -join ', '))

# ---------- collect keys referenced by the code ----------
# Covers both call shapes used in the source: (T 'key') and T "key".
#
# The lookbehind is load-bearing: without it the bare letter T also matches
# the tail of ordinary words, and a comment reading `do NOT "improve"` was
# reported as a referenced key missing from every locale - a false failure
# that hides real ones. T is a standalone function, so the character before
# it can never be a word character.
$refs = New-Object System.Collections.Generic.HashSet[string]
foreach ($m in [regex]::Matches($src, "(?<![A-Za-z0-9_])T\s+'([A-Za-z0-9_]+)'"))  { [void]$refs.Add($m.Groups[1].Value) }
foreach ($m in [regex]::Matches($src, '(?<![A-Za-z0-9_])T\s+"([A-Za-z0-9_]+)"'))  { [void]$refs.Add($m.Groups[1].Value) }
Write-Host ('referenced keys: ' + $refs.Count)

$fail = 0

# ---------- 1. every referenced key exists in every locale ----------
foreach ($loc in $locales) {
    $have    = @($json.$loc.PSObject.Properties.Name)
    $missing = @($refs | Where-Object { $have -notcontains $_ } | Sort-Object)
    if ($missing.Count -gt 0) {
        $fail = 1
        Write-Host ('MISSING in ' + $loc + ' (' + $missing.Count + '): ' + ($missing -join ', '))
    } else {
        Write-Host ('ok ' + $loc + ' - ' + $have.Count + ' keys, no missing references')
    }
}

# ---------- 2. locales must not drift apart ----------
$baseLoc  = $locales[0]
$baseKeys = @($json.$baseLoc.PSObject.Properties.Name)
foreach ($loc in $locales) {
    if ($loc -eq $baseLoc) { continue }
    $have  = @($json.$loc.PSObject.Properties.Name)
    $lacks = @($baseKeys | Where-Object { $have -notcontains $_ })
    $extra = @($have     | Where-Object { $baseKeys -notcontains $_ })
    if ($lacks.Count -gt 0 -or $extra.Count -gt 0) {
        $fail = 1
        Write-Host ('SKEW ' + $baseLoc + ' vs ' + $loc + ' - lacks: [' + ($lacks -join ', ') + '] extra: [' + ($extra -join ', ') + ']')
    }
}

if ($fail -ne 0) {
    Write-Host 'LOCALE CHECK FAILED'
    exit 3
}
Write-Host 'LOCALE CHECK OK'
exit 0
