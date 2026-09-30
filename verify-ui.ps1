# ============================================================
# verify-ui.ps1 - prove the tray UI really builds, brands and
# renders. Written because the previous "verification" only
# checked that a process existed, which said nothing about the
# icon, the tray name or whether a click opens the window.
#
# Steps:
#   1. free the single-instance mutex (kill own tray processes)
#   2. -Smoke    : build the whole UI, verify DPAPI/JSON, exit
#   3. -SelfTest : exercise save/apply/import/lang/theme, exit
#   4. -Shot     : render the panel to logs\shot.png, exit
#   5. tail the app log
#
# Own processes only: matched on the ClodKeyProxy.ps1 command
# line, so the old ClodKey app is never touched.
# ============================================================
$ErrorActionPreference = 'Stop'

$Root   = $PSScriptRoot
$App    = Join-Path $Root 'app-next\ClodKeyProxy.ps1'
$LogDir = Join-Path $Root 'logs'
$Shot   = Join-Path $LogDir 'shot.png'
$Log    = Join-Path $LogDir 'clodkey.log'

function Get-OwnProcs {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'ClodKeyProxy\.ps1' }
}

Write-Host '=== verify-ui: Clod-key-proxy ==='
Write-Host ('app: ' + $App)

Write-Host '--- [1/5] free the single-instance mutex ---'
$own = @(Get-OwnProcs)
if ($own.Count -eq 0) {
    Write-Host '  no own tray process running'
} else {
    foreach ($p in $own) {
        Write-Host ('  stopping PID ' + $p.ProcessId)
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop }
        catch { Write-Host ('  could not stop: ' + $_.Exception.Message) }
    }
    Start-Sleep -Milliseconds 800
}

if (Test-Path -LiteralPath $Shot) { Remove-Item -LiteralPath $Shot -Force }

Write-Host '--- [2/5] -Smoke (build UI, verify DPAPI/JSON) ---'
& powershell -NoProfile -ExecutionPolicy Bypass -File $App -Smoke
Write-Host ('  exit=' + $LASTEXITCODE)

Write-Host '--- [3/5] -SelfTest (save/apply/import/lang/theme) ---'
& powershell -NoProfile -ExecutionPolicy Bypass -File $App -SelfTest
Write-Host ('  exit=' + $LASTEXITCODE)

Write-Host '--- [4/5] -Shot (render panel to png) ---'
& powershell -NoProfile -ExecutionPolicy Bypass -File $App -Shot
Write-Host ('  exit=' + $LASTEXITCODE)
if (Test-Path -LiteralPath $Shot) {
    $fi = Get-Item -LiteralPath $Shot
    Write-Host ('  shot: ' + $fi.FullName + '  ' + $fi.Length + ' bytes')
} else {
    Write-Host '  shot: MISSING'
}

Write-Host '--- [5/5] app log tail ---'
if (Test-Path -LiteralPath $Log) {
    Get-Content -LiteralPath $Log -Tail 18 | ForEach-Object { Write-Host ('  ' + $_) }
} else {
    Write-Host '  no log file'
}
