# ext/20-donate.ps1 - "Buy me a coffee" window for the tea button.
# Close X + Esc, QR code of the wallet address, network label, Copy button.
# The QR (version 4, ECC M, mask 2, byte mode) was generated offline and
# verified by decoding; it is drawn here module by module - no image files,
# no internet. Rebuilt on theme/lang change so colors and text follow.
$script:DonateAddr = '0x50153B5CC3eae905291d62602226C80896Aa64f2'
$script:DonateQr = @(
    '111111100100111001111001001111111',
    '100000100100011101001010001000001',
    '101110101010110001100000001011101',
    '101110101011001110001110001011101',
    '101110101101100100100100101011101',
    '100000101001011110001100001000001',
    '111111101010101010101010101111111',
    '000000001001000100100110100000000',
    '101111100111101111101010101111100',
    '111010010010100000010101000000011',
    '110001110000100100101100010010100',
    '111111011111001000000111101100100',
    '110110100011100100110100100011000',
    '110111011011001110001110011100011',
    '101010101100000001010111100000110',
    '000011001111110010111111001100100',
    '000011101111000011111001000011000',
    '001101011000000001010011111101111',
    '000100111101000101000010010001100',
    '010110000010011001110001100000100',
    '100100111001101110001110110111001',
    '111110010011111100100000101000011',
    '100001110110100111101100110001100',
    '101100010101011100100111110100101',
    '100110101010110111101000111111001',
    '000000001101101000010110100010111',
    '111111100010011100101100101010100',
    '100000101100110100001111100010111',
    '101110101001000100100100111111000',
    '101110101101001110001111010011101',
    '101110101110111001010100100100000',
    '100000100110100010111101010001100',
    '111111101101000011111000101100110'
)

function New-QrBitmap([int]$Px) {
    $n = $script:DonateQr.Count
    $quiet = 3
    $mod = [int][Math]::Floor($Px / ($n + 2 * $quiet))
    $bmp = New-Object Drawing.Bitmap($Px, $Px)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear([Drawing.Color]::White)
    $off = [int](($Px - $mod * $n) / 2)
    $br = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(17, 17, 17))
    for ($yy = 0; $yy -lt $n; $yy++) {
        $row = [string]$script:DonateQr[$yy]
        for ($xx = 0; $xx -lt $n; $xx++) {
            if ($row[$xx] -eq [char]'1') { $g.FillRectangle($br, [int]($off + $xx * $mod), [int]($off + $yy * $mod), $mod, $mod) }
        }
    }
    $br.Dispose()
    $g.Dispose()
    return $bmp
}

function New-DonateButton([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [bool]$IsAccent) {
    $b = New-Object ClodUi.ClodButton
    $b.Text = $Text
    $b.Location = New-Object Drawing.Point($X, $Y)
    $b.Size = New-Object Drawing.Size($W, $H)
    $b.Pad = 5
    $b.Radius = [int](($H - 10) / 2)
    $b.Surface = $script:surface
    $b.Ink = $script:ink
    $b.ShadowDark = $script:shadowDark
    $b.LightShadow = $script:shadowLight
    $b.AccentColor = $script:accentClr
    $b.AccentText = $script:accentText
    $b.Accent = $IsAccent
    $b.ForeColor = $script:ink
    $b.Font = $fontMicro
    return $b
}

function New-DonateLabel([string]$Text, $Font, $Color, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text
    $l.Font = $Font
    $l.ForeColor = $Color
    $l.BackColor = [Drawing.Color]::Transparent
    $l.AutoSize = $false
    $l.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
    $l.Location = New-Object Drawing.Point($X, $Y)
    $l.Size = New-Object Drawing.Size($W, $H)
    return $l
}

function Copy-DonateAddr {
    try { [Windows.Forms.Clipboard]::SetText($script:DonateAddr) }
    catch { Write-Log 'error' ('donate copy failed: ' + $_.Exception.Message); return }
    Set-Status (TX 'tea_copied')
    Write-Log 'info' 'donate: address copied'
    if ($script:DonateCopyBtn -and -not $script:DonateCopyBtn.IsDisposed) {
        $script:DonateCopyBtn.Text = TX 'tea_copied'
        $script:DonateCopyBtn.Invalidate()
    }
    if (-not $script:DonateCopyTimer) {
        $script:DonateCopyTimer = New-Object Windows.Forms.Timer
        $script:DonateCopyTimer.Interval = 1600
        $script:DonateCopyTimer.Add_Tick({
            $script:DonateCopyTimer.Stop()
            if ($script:DonateCopyBtn -and -not $script:DonateCopyBtn.IsDisposed) {
                $script:DonateCopyBtn.Text = TX 'tea_copy'
                $script:DonateCopyBtn.Invalidate()
            }
        })
    }
    $script:DonateCopyTimer.Stop()
    $script:DonateCopyTimer.Start()
}

function Show-Donate {
    if ($script:DonateForm -and -not $script:DonateForm.IsDisposed) { $script:DonateForm.Close() }
    $W = 340; $H = 478
    $df = New-Object ClodUi.ClodForm
    $df.Text = TX 'tea_title'
    $df.ClientSize = New-Object Drawing.Size($W, $H)
    $df.StartPosition = 'Manual'
    $df.Surface = $script:surface; $df.Border = $script:borderClr
    $df.BackColor = $script:surface; $df.ForeColor = $script:ink
    $df.Font = $fontUi; $df.ShowInTaskbar = $false; $df.KeyPreview = $true
    if ($script:AppIcon) { $df.Icon = $script:AppIcon }
    # centered over the main window, clamped to the working area
    $wa = [Windows.Forms.Screen]::GetWorkingArea($form)
    $x = $form.Left + [int](($form.Width - $W) / 2)
    $y = $form.Top + [int](($form.Height - $H) / 2)
    $x = [Math]::Max($wa.Left + 8, [Math]::Min($x, $wa.Right - $W - 8))
    $y = [Math]::Max($wa.Top + 8, [Math]::Min($y, $wa.Bottom - $H - 8))
    $df.Location = New-Object Drawing.Point($x, $y)
    $df.Opacity = 0.0

    $title = New-Object Windows.Forms.Label
    $title.Text = (TX 'tea_title') + ' ' + [string][char]0x2615
    $title.Font = $fontTitle; $title.ForeColor = $script:ink
    $title.BackColor = [Drawing.Color]::Transparent; $title.AutoSize = $true
    $title.Location = New-Object Drawing.Point(18, 16)
    $df.Controls.Add($title)

    $btnX = New-DonateButton (T 'btn_close') ($W - 50) 12 36 30 $false
    $btnX.Add_Click({ if ($script:DonateForm) { $script:DonateForm.Close() } })
    $df.Controls.Add($btnX)

    $df.Controls.Add((New-DonateLabel (TX 'tea_sub') $fontUi $script:muted 18 50 ($W - 36) 40))

    $qs = 210
    $script:DonateQrBmp = New-QrBitmap $qs
    $pb = New-Object Windows.Forms.PictureBox
    $pb.Size = New-Object Drawing.Size($qs, $qs)
    $pb.Location = New-Object Drawing.Point([int](($W - $qs) / 2), 98)
    $pb.Image = $script:DonateQrBmp
    $pb.BackColor = [Drawing.Color]::White
    $pb.Region = New-Object Drawing.Region([ClodUi.Shape]::Round((New-Object Drawing.Rectangle(0, 0, $qs, $qs)), 14))
    $df.Controls.Add($pb)

    $df.Controls.Add((New-DonateLabel (TX 'tea_net') $fontUiB $script:ink 18 316 ($W - 36) 24))

    $well = New-Object ClodUi.ClodPanel
    $well.Surface = $script:surface; $well.ShadowDark = $script:shadowDark; $well.LightShadow = $script:shadowLight
    $well.BackColor = $script:surface; $well.Radius = 12
    $well.Location = New-Object Drawing.Point(14, 344)
    $well.Size = New-Object Drawing.Size(($W - 28), 44)
    $script:DonateMono = New-Object Drawing.Font($fontMono.FontFamily, 8.25)
    $addr = New-DonateLabel $script:DonateAddr $script:DonateMono $script:ink 4 4 ($W - 36) 36
    $addr.Cursor = [Windows.Forms.Cursors]::Hand
    $addr.Add_Click({ Copy-DonateAddr })
    $well.Controls.Add($addr)
    $df.Controls.Add($well)

    $script:DonateCopyBtn = New-DonateButton (TX 'tea_copy') ([int](($W - 190) / 2)) 398 190 34 $true
    $script:DonateCopyBtn.Add_Click({ Copy-DonateAddr })
    $df.Controls.Add($script:DonateCopyBtn)

    $df.Controls.Add((New-DonateLabel (TX 'tea_warn') $fontMicro $script:muted 18 440 ($W - 36) 32))

    $df.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) { $script:DonateForm.Close() }
    })
    $df.Add_FormClosed({
        if ($script:DonateQrBmp) { $script:DonateQrBmp.Dispose(); $script:DonateQrBmp = $null }
        Write-Log 'info' 'donate window closed'
    })

    $script:DonateForm = $df
    $df.Show($form)
    $df.Activate()
    if (-not $script:DonateFade) {
        $script:DonateFade = New-Object Windows.Forms.Timer
        $script:DonateFade.Interval = 15
        $script:DonateFade.Add_Tick({
            if (-not $script:DonateForm -or $script:DonateForm.IsDisposed) { $script:DonateFade.Stop(); return }
            $o = $script:DonateForm.Opacity + 0.12
            if ($o -ge 1.0) { $o = 1.0; $script:DonateFade.Stop() }
            $script:DonateForm.Opacity = $o
        })
    }
    $script:DonateFade.Start()
    Write-Log 'info' 'donate window opened'
}

$script:ExtTea = { Show-Donate }

$script:ExtApply += {
    if ($script:DonateForm -and -not $script:DonateForm.IsDisposed -and $script:DonateForm.Visible) { Show-Donate }
}
