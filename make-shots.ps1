# helper: render light + dark shots, restore original theme, relaunch live.
# ASCII only. Stops the running ClodKey instance first (single-instance
# mutex would otherwise reject the -Shot run).
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$sp = Join-Path $root 'data\secrets.json'
$app = Join-Path $root 'app-next\ClodKey.ps1'

function Stop-Own {
    $me = $PID
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -match 'ClodKey\.ps1' } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force } catch { }
        }
}

function Set-ThemeInStore([string]$Th) {
    $j = [IO.File]::ReadAllText($sp, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not ($j.PSObject.Properties.Name -contains 'settings')) {
        $j | Add-Member NoteProperty settings ([pscustomobject]@{ lang = 'ru'; theme = 'light' })
    }
    $j.settings.theme = $Th
    [IO.File]::WriteAllText($sp, ($j | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}

Stop-Own

# light shot
Set-ThemeInStore 'light'
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File $app -Shot
Write-Output ('SHOT_LIGHT_EXIT=' + $LASTEXITCODE)
Copy-Item (Join-Path $root 'logs\shot.png') (Join-Path $root 'logs\shot-light.png') -Force

# dark shot
Set-ThemeInStore 'dark'
& powershell -NoProfile -STA -ExecutionPolicy Bypass -File $app -Shot
Write-Output ('SHOT_DARK_EXIT=' + $LASTEXITCODE)
Copy-Item (Join-Path $root 'logs\shot.png') (Join-Path $root 'logs\shot-dark.png') -Force

# restore light as the live default and relaunch the tray app from live
Set-ThemeInStore 'light'
$liveVbs = Join-Path $root 'live\run-hidden.vbs'
if (Test-Path -LiteralPath $liveVbs) {
    Start-Process wscript.exe -ArgumentList ('"' + $liveVbs + '"') -WindowStyle Hidden
    Write-Output 'live relaunched'
}
Write-Output 'shots done'
