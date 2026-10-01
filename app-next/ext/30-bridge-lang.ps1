# ext/30-bridge-lang.ps1 - FIX: Bridge window kept the language it was built in.
#
# Root cause: Show-Bridge builds the window ONCE and then only re-shows the
# cached form. Apply-Language refreshes just the caption and the status line,
# so buttons (Start/Stop/Restart/Load current profile/Mini log) and the inner
# title stayed in the old language (typically RU) after switching to EN.
#
# Fix: remember the language the window was built in; when it differs from
# the current one, dispose the cached window and build a fresh one.
# ASCII-only on purpose (see header of ClodKeyProxy.ps1).

$script:BridgeLang = $null
$script:OrigShowBridge = ${function:Show-Bridge}

function Reset-BridgeWindow {
    if ($script:BridgeTimer) { try { $script:BridgeTimer.Stop() } catch { } }
    if ($script:BridgeForm -and -not $script:BridgeForm.IsDisposed) {
        # Dispose (not Close): Close is cancelled by FormClosing -> Hide
        try { $script:BridgeForm.Dispose() } catch { }
    }
    $script:BridgeForm = $null
    $script:BridgeTimer = $null
}

function Show-Bridge {
    if ($script:BridgeForm -and -not $script:BridgeForm.IsDisposed -and $script:BridgeLang -ne $script:Lang) {
        Write-Log 'info' ('bridge window rebuilt: lang ' + [string]$script:BridgeLang + ' -> ' + $script:Lang)
        Reset-BridgeWindow
    }
    & $script:OrigShowBridge
    $script:BridgeLang = $script:Lang
}

# Language switched while the Bridge window is open: rebuild it in place.
$script:ExtApply += {
    if ($script:BridgeForm -and -not $script:BridgeForm.IsDisposed -and $script:BridgeLang -ne $script:Lang) {
        $wasVisible = $script:BridgeForm.Visible
        Reset-BridgeWindow
        if ($wasVisible) { Show-Bridge }
    }
}
