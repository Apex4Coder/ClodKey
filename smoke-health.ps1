# ============================================================
# smoke-health.ps1 - pre-deploy smoke test for the de-degraded bridge.
#
# Starts app-next/bridge/server.mjs on its configured port, polls
# /health until it answers, then asserts the key invariant of this
# rebuild: the `gracefulDegrade` field must be GONE from /health
# (the old bridge reported "gracefulDegrade": true).
#
# Lives at the Clod-key-proxy root on purpose: deploy copies only
# app-next -> live, so this test artifact never ships to live.
# ASCII-only body; run with: powershell -NoProfile -File smoke-health.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
$bridgeDir = Join-Path $PSScriptRoot 'app-next\bridge'
$port = 33110

Write-Output ("bridge dir : {0}" -f $bridgeDir)
Write-Output ("target port: {0}" -f $port)

$proc = Start-Process -FilePath 'node' -ArgumentList 'server.mjs' `
    -WorkingDirectory $bridgeDir -PassThru -WindowStyle Hidden

try {
    $h = $null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 400
        try {
            $h = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/health" -f $port) -TimeoutSec 3
            break
        } catch {
            $h = $null
        }
    }

    if ($null -eq $h) {
        Write-Output 'SMOKE FAIL: /health unreachable'
    } else {
        Write-Output '=== HEALTH JSON ==='
        ($h | ConvertTo-Json -Depth 6)
        $hasDegrade = ($h.PSObject.Properties.Name -contains 'gracefulDegrade')
        Write-Output ("has gracefulDegrade: {0}" -f $hasDegrade)
        if ($hasDegrade) {
            Write-Output 'SMOKE FAIL: gracefulDegrade still present'
        } else {
            Write-Output 'SMOKE OK: gracefulDegrade removed; /health up'
        }
    }
} finally {
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Output ("STOPPED PID {0}" -f $proc.Id)
}
