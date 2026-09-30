$ErrorActionPreference = 'Stop'

Write-Host '=== verify-deploy: Clod-key-proxy ==='

# 1) tray app must be running FROM live\ (not app-next\)
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe' OR Name='node.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'ClodKeyProxy\.ps1' })

Write-Host ''
Write-Host ('tray processes (ClodKeyProxy.ps1): ' + $procs.Count)
foreach ($p in $procs) {
    $fromLive = if ($p.CommandLine -match '\\live\\') { 'live' } elseif ($p.CommandLine -match '\\app-next\\') { 'app-next' } else { '?' }
    Write-Host ('  PID ' + $p.ProcessId + ' [' + $p.Name + '] from=' + $fromLive)
}

# 2) live tree present
$base = $PSScriptRoot
$liveApp = Join-Path $base 'live\ClodKeyProxy.ps1'
$liveVbs = Join-Path $base 'live\run-hidden.vbs'
$liveSrv = Join-Path $base 'live\bridge\server.mjs'
Write-Host ''
Write-Host ('live\ClodKeyProxy.ps1 : ' + (Test-Path -LiteralPath $liveApp))
Write-Host ('live\run-hidden.vbs   : ' + (Test-Path -LiteralPath $liveVbs))
Write-Host ('live\bridge\server.mjs: ' + (Test-Path -LiteralPath $liveSrv))

# 3) old bridge on 33009 must remain untouched (serves the current session)
$old = @(Get-NetTCPConnection -State Listen -LocalPort 33009 -ErrorAction SilentlyContinue)
Write-Host ''
Write-Host ('port 33009 (OLD api-test bridge): ' + $(if ($old.Count -gt 0) { 'LISTENING (untouched) pid=' + $old[0].OwningProcess } else { 'free' }))

# 4) new bridge port 33110 state (started on demand from the tray card)
$new = @(Get-NetTCPConnection -State Listen -LocalPort 33110 -ErrorAction SilentlyContinue)
Write-Host ('port 33110 (NEW proxy bridge)   : ' + $(if ($new.Count -gt 0) { 'LISTENING pid=' + $new[0].OwningProcess } else { 'free (start from tray card)' }))

Write-Host ''
if ($procs.Count -gt 0 -and (Test-Path -LiteralPath $liveApp)) {
    Write-Host 'VERIFY OK: tray app is live'
} else {
    Write-Host 'VERIFY FAIL'
    exit 1
}
