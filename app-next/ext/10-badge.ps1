# ext/10-badge.ps1 - "Fueled by [logo] LINUX SB" badge under the title.
# Click opens https://linux.sb. Placed by $script:ExtHeader (called from
# Do-Layout), repainted/re-measured by $script:ExtApply on theme/lang change.
# Logo: 32x32 PNG cut from the LINUX SB mark, embedded as base64 (ASCII).
$script:BadgeLogo = $null
try {
    $badgeBytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAMAAABEpIrGAAAASFBMVEUPDxCXl5j+/v5jY2Tf3tv9rwn5+fnz2qEDAwP3yWerq6sREREFBQX29vZSUlL4v0J/f39/f4CBgH+/xtH6+vvu7u0AAABmZmb3lEZQAAAAGHRSTlP6+g/77/+T/5n/DCViYp//Av/+//3+AP4DB7r+AAABUElEQVR42nVTi3LEIAgENOZ5j7ao//+nBdQYcy2TiQm7rqgspB7HAhbLcUmCvUmegJcIZMlG2FJanHM5u+wMl+/F0oVAidDQazgk0wDD+c8wBlQ8RvYOUMeRAUTkJW04OPs6w29vAkpBp0VG2aAqXBkhEegCipuAaXWGx01qCGUWdrwxooOn1MBnBV8NbwSZQ/AodQ0ClSEK+QHhFMCOx6aQA5Q9ikD2PvIHwUOshOzRYeRrmUpgKL8Rvc8Z/TrzQHAMZwKFME/TzHdCY0T8EbwSuC9xPZx1mla+Fxn65tZpWEHPAZ7loCznp1FAFeCoR6013AWkbsStXVZkqzDG+32X664CK9/6gbWjRMIa7jVssTeMtZwC82u+6bMXEP5v6tq0zRbO4tMYYMbaBcPvaioNHXazFhRrjs6s7qRuXom9WrsafB/dnUjYe7f/XjIav59DPBDNP34fAAAAAElFTkSuQmCC')
    $script:BadgeLogoStream = New-Object IO.MemoryStream(, $badgeBytes)
    $script:BadgeLogo = [Drawing.Image]::FromStream($script:BadgeLogoStream)
} catch {
    Write-Log 'warn' ('badge logo decode failed: ' + $_.Exception.Message)
}

$script:BadgeFontA = $fontMicro
$script:BadgeFontB = New-Object Drawing.Font($fontMicro, [Drawing.FontStyle]::Bold)
$script:BadgeH = 18
$script:BadgeHover = $false

function Measure-Badge {
    $nf = [Windows.Forms.TextFormatFlags]::NoPadding
    $big = New-Object Drawing.Size(2000, 100)
    $w1 = [Windows.Forms.TextRenderer]::MeasureText((TX 'badge_prefix'), $script:BadgeFontA, $big, $nf).Width
    $w2 = [Windows.Forms.TextRenderer]::MeasureText('LINUX SB', $script:BadgeFontB, $big, $nf).Width
    return [int]($w1 + 5 + ($script:BadgeH - 2) + 5 + $w2 + 4)
}

$script:Badge = New-Object Windows.Forms.Panel
$script:Badge.BackColor = [Drawing.Color]::Transparent
$script:Badge.Cursor = [Windows.Forms.Cursors]::Hand
$script:Badge.Size = New-Object Drawing.Size(160, $script:BadgeH)
$script:Badge.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $flags = [Windows.Forms.TextFormatFlags]::NoPadding -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::SingleLine
    $h = $s.Height
    $big = New-Object Drawing.Size(2000, 100)
    $t1 = TX 'badge_prefix'
    $w1 = [Windows.Forms.TextRenderer]::MeasureText($t1, $script:BadgeFontA, $big, [Windows.Forms.TextFormatFlags]::NoPadding).Width
    [Windows.Forms.TextRenderer]::DrawText($g, $t1, $script:BadgeFontA, (New-Object Drawing.Rectangle(0, 0, ($w1 + 2), $h)), $script:muted, $flags)
    $x = $w1 + 5
    $ls = $h - 2
    if ($script:BadgeLogo) { $g.DrawImage($script:BadgeLogo, (New-Object Drawing.Rectangle($x, 1, $ls, $ls))) }
    $x += $ls + 5
    $c = $script:ink
    if ($script:BadgeHover) { $c = $script:accentClr }
    [Windows.Forms.TextRenderer]::DrawText($g, 'LINUX SB', $script:BadgeFontB, (New-Object Drawing.Rectangle($x, 0, [Math]::Max(1, ($s.Width - $x)), $h)), $c, $flags)
})
$script:Badge.Add_MouseEnter({ $script:BadgeHover = $true; $script:Badge.Invalidate() })
$script:Badge.Add_MouseLeave({ $script:BadgeHover = $false; $script:Badge.Invalidate() })
$script:Badge.Add_Click({
    try { Start-Process 'https://linux.sb'; Write-Log 'info' 'badge: linux.sb opened' }
    catch { Write-Log 'error' ('badge open failed: ' + $_.Exception.Message) }
})
$script:BadgeTip = New-Object Windows.Forms.ToolTip
$script:BadgeTip.SetToolTip($script:Badge, (TX 'badge_tip'))
$form.Controls.Add($script:Badge)
$script:Badge.BringToFront()

# Do-Layout hook: place the badge under the sub label, return the height used.
$script:ExtHeader = {
    param($pad, $top, $W)
    $script:Badge.Size = New-Object Drawing.Size((Measure-Badge), $script:BadgeH)
    $script:Badge.Location = New-Object Drawing.Point(([int]$pad + 1), ([int]$top + 4))
    return ($script:BadgeH + 4)
}

$script:ExtApply += {
    if ($script:Badge -and -not $script:Badge.IsDisposed) {
        $script:Badge.Width = Measure-Badge
        $script:BadgeTip.SetToolTip($script:Badge, (TX 'badge_tip'))
        $script:Badge.Invalidate()
    }
}
