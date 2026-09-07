# ============================================================
# deploy.ps1 - install app-next -> live and launch FROM live.
# Principle: zoo-brigada / GOLD spec (next -> live with backup
# and automatic rollback). ASCII-only source, do NOT "improve".
#
# Differences from the Node reference (deliberate):
#   - no port here: "wait until port is free" is replaced by
#     "our processes are stopped and files are released";
#   - state is NEVER carried over (GOLD 1.2): secrets.json and
#     logs live OUTSIDE the release (data\, logs\), so deploy
#     moves only code and rollback cannot lose keys;
#   - success = the app process is actually alive 3 s after
#     launch (our /readyz), not "spawn succeeded".
#
# Own processes are found by CommandLine match (ClodKey.ps1),
# excluding this deployer and its parent, and are re-stopped
# before EVERY rename attempt (watchdog rule).
# ============================================================
$ErrorActionPreference = 'Stop'

$Base  = $PSScriptRoot
$Src   = Join-Path $Base 'app-next'
$Dst   = Join-Path $Base 'live'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Prev  = Join-Path $Base ('live.prev-' + $Stamp)
$KeepPrev = 5

function Write-Step([string]$Msg) { Write-Host ('[deploy] ' + $Msg) }

function Get-OwnProcs {
    $me = $PID
    $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$me" -ErrorAction SilentlyContinue).ParentProcessId
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $me -and
            $_.ProcessId -ne $parent -and
            $_.CommandLine -match 'ClodKey\.ps1'
        }
}

function Stop-Own {
    foreach ($p in @(Get-OwnProcs)) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Step ('stopped own pid ' + $p.ProcessId)
        } catch {
            Write-Step ('could not stop pid ' + $p.ProcessId + ': ' + $_.Exception.Message)
        }
    }
}

function Invoke-WithRetry([scriptblock]$Action, [int]$Times = 6, [int]$DelayMs = 1500) {
    for ($i = 1; $i -le $Times; $i++) {
        try { return & $Action }
        catch {
            if ($i -ge $Times) { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Rollback {
    Write-Step 'ROLLBACK: removing failed live, restoring backup'
    try {
        Stop-Own
        if (Test-Path -LiteralPath $Dst) {
            Invoke-WithRetry { Remove-Item -LiteralPath $Dst -Recurse -Force }
        }
        if ((Test-Path -LiteralPath $Prev) -and -not (Test-Path -LiteralPath $Dst)) {
            Invoke-WithRetry { Move-Item -LiteralPath $Prev -Destination $Dst }
            Write-Step ('restored ' + $Dst + ' from ' + $Prev)
            # relaunch previous version
            Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $Dst 'run-hidden.vbs') + '"') -WorkingDirectory $Dst -WindowStyle Hidden
        }
    } catch {
        Write-Step ('ROLLBACK FAILED: ' + $_.Exception.Message)
        Write-Step ('restore manually: rename "' + $Prev + '" to "live"')
    }
}

# ---------- [1/6] preflight ----------
Write-Step '[1/6] preflight'
foreach ($need in 'ClodKey.ps1', 'strings.json', 'run-hidden.vbs') {
    if (-not (Test-Path -LiteralPath (Join-Path $Src $need))) {
        Write-Step ('preflight FAILED: app-next\' + $need + ' missing. Nothing on disk was touched.')
        exit 2
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $Base 'data'))) {
    New-Item -ItemType Directory -Path (Join-Path $Base 'data') -Force | Out-Null
}

# ---------- [2/6] stop own processes ----------
Write-Step '[2/6] stop own processes'
Stop-Own

# ---------- [3/6] backup: live -> live.prev-<stamp> ----------
$hadLive = $false
if (Test-Path -LiteralPath $Dst) {
    Write-Step ('[3/6] backup live -> ' + (Split-Path -Leaf $Prev))
    $hadLive = $true
    Invoke-WithRetry {
        Stop-Own   # watchdog rule: re-stop before EVERY rename attempt
        Move-Item -LiteralPath $Dst -Destination $Prev
    }
} else {
    Write-Step '[3/6] no live yet, nothing to back up'
}

# ---------- [4/6] copy app-next -> live (copy, NOT move) ----------
Write-Step '[4/6] copy app-next -> live'
try {
    Invoke-WithRetry { Copy-Item -LiteralPath $Src -Destination $Dst -Recurse -Force }
} catch {
    Write-Step ('copy FAILED: ' + $_.Exception.Message)
    if ($hadLive) { Rollback } else {
        Invoke-WithRetry { Remove-Item -LiteralPath $Dst -Recurse -Force -ErrorAction SilentlyContinue }
    }
    exit 3
}

# ---------- [5/6] state ----------
Write-Step '[5/6] state lives in data\ and logs\ (outside the release) - nothing to carry'

# ---------- [6/6] launch from live + verify alive ----------
Write-Step '[6/6] launch live\run-hidden.vbs and verify'
try {
    Stop-Own   # make sure no old copy races with the new one
    Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $Dst 'run-hidden.vbs') + '"') -WorkingDirectory $Dst -WindowStyle Hidden
} catch {
    Write-Step ('launch FAILED: ' + $_.Exception.Message)
    if ($hadLive) { Rollback }
    exit 4
}

$alive = $false
for ($i = 0; $i -lt 6; $i++) {
    Start-Sleep -Seconds 1
    if (@(Get-OwnProcs).Count -gt 0) { $alive = $true; break }
}
if (-not $alive) {
    Write-Step 'app is NOT running 6 s after launch (this is our /readyz check)'
    if ($hadLive) { Rollback }
    exit 5
}

# ---------- housekeeping: keep last N backups ----------
Get-ChildItem -LiteralPath $Base -Directory -Filter 'live.prev-*' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $KeepPrev |
    ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Recurse -Force } catch { }
    }

Write-Step 'DEPLOY OK: live is running from ' + $Dst
exit 0
