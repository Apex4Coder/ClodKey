# ============================================================
# tests\deploy-lock.tests.ps1 - regression guard for the deploy
# defect measured on 2026-09-10.
#
# WHAT BROKE (real incident, not a hypothetical):
#   deploy.ps1 stopped only the UI process (ClodKeyProxy.ps1) but not the
#   node.exe bridge it had started. The bridge kept live\bridge open, so
#   "Move-Item live -> live.prev-*" failed with "file is used by another
#   process". Because $hadLive had ALREADY been set to $true before the
#   rename, the failure path believed a backup existed and skipped the
#   restore - leaving live\ EMPTY and the app unlaunchable.
#
# Evidence left on disk: live.prev-20260910-052832 and
# live.prev-20260910-211803 both contain ZERO files.
#
# These tests run entirely on a throwaway tree under $env:TEMP. They never
# touch the real Clod-key-proxy install, never bind a port and never stop a
# process that is not their own child.
#
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tests\deploy-lock.tests.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$script:Pass = 0
$script:Fail = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:Pass++; Write-Host ('  PASS  ' + $Name) }
    else { $script:Fail++; Write-Host ('  FAIL  ' + $Name + ' :: ' + $Detail) }
}

$Root = Join-Path $env:TEMP ('ck-deploy-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Deploy = Join-Path $PSScriptRoot '..\deploy.ps1'
$Deploy = [IO.Path]::GetFullPath($Deploy)

Write-Host ''
Write-Host '--- static guarantees in deploy.ps1 ---'
$src = Get-Content $Deploy -Raw

# Ordering checks below compare positions of statements in the deploy path.
# Rollback is declared ABOVE that path and legitimately removes $Dst - that is
# its whole job after a failed release. Measuring order against the raw file
# therefore matched Rollback's Remove-Item first and reported a defect that did
# not exist. Strip the function body so ordering is judged on the deploy path
# only; text-presence checks keep using the full source.
$body = $src -replace '(?s)function Rollback \{.*?\r?\n\}\r?\n', ''
if ($body -eq $src) {
    Write-Host 'FAIL  test harness: could not isolate the Rollback body'
    Write-Host '      -> ordering checks would silently measure the wrong block'
    $script:Fail++
}

Check 'the deployer knows about the node bridge, not just the UI' `
    ($src -match 'Get-OwnBridgeProcs') `
    'Stop-Own would again leave live\bridge locked'

Check 'ownership is decided by path, so a foreign bridge is never killed' `
    ($src.Contains('app-next\bridge') -and $src.Contains('live\bridge')) `
    'no path-based ownership test found'

Check 'the backup is a copy, so a failure cannot damage live' `
    ($src -match 'Copy-Item -LiteralPath \$Dst -Destination \$Prev') `
    'live is still moved directly - a partial move guts the release'

Check 'the backup is verified before live is removed' `
    ($src -match '\$prevCount -lt \$liveCount') `
    'no file-count verification of the backup'

# The ordering invariant is what actually prevented the empty-live bug:
# rollback must never be armed until a verified backup exists AND live is gone.
Check 'hadLive is set only AFTER the backup is verified and live removed' `
    ($body -match '(?s)\$prevCount -lt \$liveCount.*?Remove-Item -LiteralPath \$Dst -Recurse -Force.*?\$hadLive = \$true') `
    'hadLive is armed too early - the empty-live bug is back'

Check 'a failed backup aborts instead of continuing into copy' `
    ($src -match 'backup FAILED') `
    'no abort path on backup failure'

Check 'a failure while removing live restores it from the verified copy' `
    ($src -match 'restored live from the verified backup') `
    'no restore path after a partial removal of live'

Check 'live is never removed before the backup exists' `
    ($body.IndexOf('$prevCount -lt $liveCount') -lt $body.IndexOf('Remove-Item -LiteralPath $Dst -Recurse -Force')) `
    'live removal appears before backup verification'

Check 'rollback still owns a removal path of its own' `
    ($src -match '(?s)function Rollback \{.*?Remove-Item -LiteralPath \$Dst -Recurse -Force') `
    'rollback no longer clears a half-written live'

Write-Host ''
Write-Host '--- behaviour: a locked live\bridge must not destroy live ---'
try {
    # Build a miniature installation that looks like the real one.
    New-Item -ItemType Directory -Path (Join-Path $Root 'app-next\bridge') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'live\bridge') -Force | Out-Null
    foreach ($n in 'ClodKeyProxy.ps1', 'strings.json', 'run-hidden.vbs') {
        Set-Content -Path (Join-Path $Root ('app-next\' + $n)) -Value '# next' -Encoding ASCII
        Set-Content -Path (Join-Path $Root ('live\' + $n)) -Value '# live' -Encoding ASCII
    }
    Set-Content -Path (Join-Path $Root 'app-next\bridge\server.mjs') -Value '// next' -Encoding ASCII
    Set-Content -Path (Join-Path $Root 'live\bridge\server.mjs') -Value '// live' -Encoding ASCII

    $marker = Join-Path $Root 'live\bridge\locked.bin'
    Set-Content -Path $marker -Value 'x' -Encoding ASCII

    # Hold a real OS handle on a file inside live\bridge: this reproduces
    # exactly what the running node.exe did.
    $stream = [IO.File]::Open($marker, 'Open', 'Read', 'None')
    try {
        $copy = Join-Path $Root 'deploy.ps1'
        Copy-Item $Deploy $copy -Force

        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $copy 2>&1
        $code = $LASTEXITCODE
        $text = ($out | Out-String)

        Check 'deploy refuses to proceed while live is locked' `
            ($code -ne 0) ('exit code was ' + $code)

        Check 'live still exists after the failed deploy' `
            (Test-Path (Join-Path $Root 'live')) 'live was deleted'

        $liveFiles = @(Get-ChildItem (Join-Path $Root 'live') -Recurse -File -ErrorAction SilentlyContinue).Count
        Check 'live is NOT empty after the failed deploy' `
            ($liveFiles -gt 0) ('live contains ' + $liveFiles + ' files - the original bug')

        $liveEntry = Join-Path $Root 'live\ClodKeyProxy.ps1'
        Check 'the original live entry point survives' `
            (Test-Path $liveEntry) 'live\ClodKeyProxy.ps1 was destroyed by the failed deploy'

        Check 'the original live content is intact' `
            ((Test-Path $liveEntry) -and ((Get-Content $liveEntry -Raw).Trim() -eq '# live')) `
            'live content was replaced despite the failure'

        Check 'every original live file is still present' `
            ($liveFiles -ge 5) ('only ' + $liveFiles + ' of 5 files remain')

        Check 'the failure is reported, not swallowed' `
            ($text -match 'backup FAILED|could not|aborted') `
            'no diagnostic in output'

        $emptyPrev = @(Get-ChildItem $Root -Directory -Filter 'live.prev-*' -ErrorAction SilentlyContinue |
            Where-Object { @(Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 }).Count
        Check 'no empty live.prev-* backup is left behind' `
            ($emptyPrev -eq 0) ($emptyPrev.ToString() + ' empty backup dir(s) created')
    } finally {
        $stream.Close()
        $stream.Dispose()
    }
} finally {
    # Never leave test debris, even on failure.
    try { Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host ('ALL GREEN: ' + $script:Pass + ' passed, 0 failed')
    exit 0
} else {
    Write-Host ('FAILURES PRESENT: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
    exit 1
}
