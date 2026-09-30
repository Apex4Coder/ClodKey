# ============================================================
# parse-check.ps1 - honest PowerShell syntax check with line numbers.
#
# Why a script file and not a one-liner: in this environment complex
# quoted one-liners have repeatedly been routed to cmd.exe instead of
# PowerShell, and an inline `[ref]$errs` on an undeclared variable
# fails with "argument missing for [ref]". That error came from the
# CHECK ITSELF, not from the file under test, and it produced a false
# "unclosed brace" report. A file removes both failure modes.
#
# Exit codes: 0 = clean parse, 1 = parse errors (listed), 2 = bad input.
# ============================================================
param([string]$Path)

$ErrorActionPreference = 'Stop'

if (-not $Path -or $Path -eq '') {
    $Path = Join-Path $PSScriptRoot 'app-next\ClodKeyProxy.ps1'
}
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host ('NO SUCH FILE: ' + $Path)
    exit 2
}

$full = (Resolve-Path -LiteralPath $Path).Path
Write-Host ('file : ' + $full)
Write-Host ('lines: ' + (Get-Content -LiteralPath $full).Count)

# Declared BEFORE use: this is exactly what the failing one-liner missed.
$tokens = $null
$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)

if ($errors -and $errors.Count -gt 0) {
    Write-Host ('PARSE ERRORS: ' + $errors.Count)
    foreach ($e in $errors) {
        $ln = $e.Extent.StartLineNumber
        $col = $e.Extent.StartColumnNumber
        Write-Host ('  line ' + $ln + ' col ' + $col + ' : ' + $e.Message)
    }
    exit 1
}

# Brace/paren balance from the TOKEN stream, not from text scanning:
# tokens ignore braces inside strings, comments and here-strings, which
# is what makes naive counting lie on this file (C# here-strings).
$open = 0
$close = 0
foreach ($t in $tokens) {
    if ($t.Kind -eq 'LCurly') { $open++ }
    if ($t.Kind -eq 'RCurly') { $close++ }
}
Write-Host ('braces: open=' + $open + ' close=' + $close)

Write-Host 'PARSE OK'
exit 0
