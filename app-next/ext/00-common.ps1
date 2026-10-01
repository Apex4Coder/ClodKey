# ext/00-common.ps1 - shared helpers for ext add-ons.
# Dot-sourced by the EXT socket in ClodKeyProxy.ps1 (script scope).
# ASCII-only: all UI text lives in ext/strings-ext.json (UTF-8, 4 locales).
$script:ExtS = $null
try {
    $extStrings = Join-Path $AppDir 'ext\strings-ext.json'
    $script:ExtS = [IO.File]::ReadAllText($extStrings, [Text.Encoding]::UTF8) | ConvertFrom-Json
} catch {
    Write-Log 'error' ('ext strings load failed: ' + $_.Exception.Message)
}

# TX = T for ext strings: current language, then en, then the key itself.
function TX([string]$Key) {
    $loc = $null
    if ($script:ExtS -and ($script:ExtS.PSObject.Properties.Name -contains $script:Lang)) { $loc = $script:ExtS.$script:Lang }
    if (-not $loc -and $script:ExtS -and ($script:ExtS.PSObject.Properties.Name -contains 'en')) { $loc = $script:ExtS.en }
    if ($loc -and ($loc.PSObject.Properties.Name -contains $Key)) { return [string]$loc.$Key }
    return $Key
}
