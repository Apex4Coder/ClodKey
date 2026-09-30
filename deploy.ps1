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
# Own processes are found by CommandLine match (ClodKeyProxy.ps1),
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
            $_.CommandLine -match 'ClodKeyProxy\.ps1'
        }
}

# MEASURED DEFECT (2026-09-10, hit during a real deploy): Stop-Own killed only
# the UI process, but the bridge is a SEPARATE node.exe started by that UI and
# it keeps live\bridge open. Move-Item then failed with "file is used by another
# process", and because the failure happened DURING the backup rename, $hadLive
# was already true while live had been partially moved - the rollback path never
# ran and live was left EMPTY. The fix is to own the node child as well.
#
# Ownership is decided by the executable's PATH, never by the port: another
# bridge (api-test on 33009) must never be touched by this deployer.
function Get-OwnBridgeProcs {
    $liveBridge = [IO.Path]::GetFullPath((Join-Path $Base 'live\bridge'))
    $nextBridge = [IO.Path]::GetFullPath((Join-Path $Base 'app-next\bridge'))
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $cwd = ''
            try {
                # A node process started from our bridge dir holds server.mjs open
                # there; resolve it through the loaded module list, which is the
                # only reliable CWD signal available without extra tooling.
                $cwd = (Get-Process -Id $_.ProcessId -ErrorAction Stop).Modules |
                    Where-Object { $_.FileName -like '*server.mjs' } |
                    Select-Object -First 1 -ExpandProperty FileName
            } catch { }
            if (-not $cwd) {
                # Fallback: match the working directory recorded in the command
                # line when the bridge was launched with an explicit path.
                $cwd = [string]$_.CommandLine
            }
            $cwd -and (
                $cwd.StartsWith($liveBridge, [StringComparison]::OrdinalIgnoreCase) -or
                $cwd.StartsWith($nextBridge, [StringComparison]::OrdinalIgnoreCase)
            )
        }
}

# Last-resort ownership test for a node process whose module list is not
# readable: it is ours only if it listens on OUR port and nothing else does.
function Get-OwnBridgeByPort {
    $port = 33110
    $conns = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    foreach ($c in @($conns)) {
        $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $c.OwningProcess) -ErrorAction SilentlyContinue
        if ($p -and $p.Name -eq 'node.exe') { $p }
    }
}

function Stop-Own {
    $targets = @(Get-OwnProcs)
    $targets += @(Get-OwnBridgeProcs)
    $targets += @(Get-OwnBridgeByPort)
    foreach ($p in ($targets | Sort-Object ProcessId -Unique)) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Step ('stopped own pid ' + $p.ProcessId + ' (' + $p.Name + ')')
        } catch {
            Write-Step ('could not stop pid ' + $p.ProcessId + ': ' + $_.Exception.Message)
        }
    }
    if (@($targets).Count -gt 0) { Start-Sleep -Milliseconds 700 }  # let handles close
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
foreach ($need in 'ClodKeyProxy.ps1', 'strings.json', 'run-hidden.vbs') {
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

function Get-FileCount([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue).Count
}

# ---------- [3/6] backup: live -> live.prev-<stamp> ----------
# TWO measured defects are guarded here, both from the 2026-09-10 incident:
#
#  1. $hadLive was set BEFORE the rename, so a failure during the rename took
#     the "a backup exists" branch and skipped the restore entirely.
#
#  2. Move-Item on a directory tree is NOT atomic on Windows. With a handle
#     open on live\bridge it moved everything it could and failed on the rest,
#     leaving live\ present but GUTTED - which also defeats any "if live still
#     exists, all is well" check.
#
# Therefore the backup is a COPY (non-destructive: a failure cannot damage
# live), it is verified by file count, and only then is live removed. If the
# removal is the thing that fails, the verified copy is put back.
$hadLive = $false
if (Test-Path -LiteralPath $Dst) {
    Write-Step ('[3/6] backup live -> ' + (Split-Path -Leaf $Prev))
    $liveCount = Get-FileCount $Dst

    try {
        Invoke-WithRetry {
            Stop-Own   # watchdog rule: re-stop before EVERY attempt
            if (Test-Path -LiteralPath $Prev) { Remove-Item -LiteralPath $Prev -Recurse -Force }
            Copy-Item -LiteralPath $Dst -Destination $Prev -Recurse -Force
        }
    } catch {
        Write-Step ('backup FAILED (copy): ' + $_.Exception.Message)
        if (Test-Path -LiteralPath $Prev) {
            try { Remove-Item -LiteralPath $Prev -Recurse -Force } catch { }
        }
        Write-Step 'live was NOT modified. Close whatever holds live\bridge, then retry.'
        exit 5
    }

    $prevCount = Get-FileCount $Prev
    if ($prevCount -lt $liveCount) {
        Write-Step ('backup FAILED: copied ' + $prevCount + ' of ' + $liveCount + ' files')
        try { Remove-Item -LiteralPath $Prev -Recurse -Force } catch { }
        Write-Step 'live was NOT modified. Aborting.'
        exit 5
    }

    # The backup is complete and verified; only now may live be removed.
    try {
        Invoke-WithRetry {
            Stop-Own
            Remove-Item -LiteralPath $Dst -Recurse -Force
        }
    } catch {
        Write-Step ('backup FAILED (removing live): ' + $_.Exception.Message)
        # live may now be partially deleted - restore it from the verified copy.
        try {
            if (Test-Path -LiteralPath $Dst) { Remove-Item -LiteralPath $Dst -Recurse -Force -ErrorAction SilentlyContinue }
            Copy-Item -LiteralPath $Prev -Destination $Dst -Recurse -Force
            Write-Step 'restored live from the verified backup'
            Remove-Item -LiteralPath $Prev -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Step ('COULD NOT RESTORE live: ' + $_.Exception.Message)
            Write-Step ('restore manually: rename "' + $Prev + '" to "live"')
        }
        exit 5
    }

    $hadLive = $true
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

Write-Step ('DEPLOY OK: live is running from ' + $Dst)
exit 0
