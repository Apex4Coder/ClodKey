# ============================================================
# ClodKey.ps1 - tray flyout key manager for Anthropic Claude CLI
#
# Stack: Windows PowerShell 5.1 + WinForms (ships with Windows,
#        zero binary deps, AV-safe).
#
# Platform invariants (from GOLD spec, do NOT "improve"):
#   - main loop is [Application]::Run(), never ShowDialog()
#   - close (X) / minimize = hide to tray; Exit is explicit only
#   - GUI mode writes NOTHING to stdout: file log only (logs\)
#   - .ps1 source is ASCII-only; all human strings live in
#     strings.json (UTF-8, 4 locales) because OEM codepage kills
#     non-ASCII in BOM-less .ps1 files
#   - no console window: launched via run-hidden.vbs (WMI,
#     CreateFlags=CREATE_NO_WINDOW) + FreeConsole() at startup
#   - secrets: DPAPI CurrentUser scope, entropy salted, stored in
#     data\secrets.json (state lives OUTSIDE the release)
#   - file writes are atomic (tmp + move) with retry 6x1.5s
#
# Visual language: SOFT NEUMORPHISM (tokens from canonical
# themesberg/neumorphism-ui-bootstrap, 1k stars):
#   - raised = same fill as background + two offset soft shadows
#     (dark bottom-right, light top-left); NO borders, NO gradients
#   - pressed / selected / input = inset shadows
#   - header micro icon buttons (no text): lang RU/EN/ZH/ES as
#     glyphs, theme light/dark toggle, tea break, close
#   - light + dark palettes, persisted in store settings
#   - slide-up + fade flyout anchored to the tray, hover tooltips
#   - font stack: Segoe UI Variable Text -> Segoe UI; keys in
#     Cascadia Mono -> Consolas
#   - system keys (env vars + ~/.claude/settings.json) are
#     imported on startup as the "System" profile
# ============================================================
param(
    [switch]$Minimized,
    [switch]$Smoke,     # build UI, verify DPAPI/JSON, exit without loop
    [switch]$SelfTest,  # exercise save+apply+import+lang+theme, exit
    [switch]$Shot       # render the panel, save png to logs\shot.png, exit
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

# ---------- paths ----------
# GOLD INV: state NEVER lives inside a release. The script may run from
# app-next\ (dev) or live\ (installed); data and logs live one level up,
# so deploy/rollback moves only code, state never moves.
$AppDir      = $PSScriptRoot
$Base        = Split-Path -Parent $AppDir
$SecretsPath = Join-Path $Base 'data\secrets.json'
$StringsPath = Join-Path $AppDir 'strings.json'
$LogDir      = Join-Path $Base 'logs'
$LogPath     = Join-Path $LogDir 'clodkey.log'

# ---------- logging (GUI subsystem has no stdout: file only) ----------
function Write-Log([string]$Level, [string]$Message) {
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        $line = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpper(), $Message
        [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# ---------- native helpers ----------
if (-not ('ClodNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClodNative {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] public static extern bool FreeConsole();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]   public static extern bool ReleaseCapture();
    [DllImport("user32.dll")]   public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
}
'@
}
# ZERO console windows, visible OR hidden (G22). powershell.exe always
# allocates a console at startup; CREATE_NO_WINDOW makes its window hidden
# but it still EXISTS. FreeConsole() detaches the process from it, and
# conhost DESTROYS the window because no attached process remains.
if (-not ($Smoke -or $SelfTest)) {
    # CLI twins keep their console for Write-Host evidence
    try {
        [void][ClodNative]::FreeConsole()
    } catch { Write-Log 'warn' ('FreeConsole failed: ' + $_.Exception.Message) }
    $script:ConsoleMode = 'detached_freeconsole'
    try {
        if ([ClodNative]::GetConsoleWindow() -ne [IntPtr]::Zero) {
            # should never happen after FreeConsole; last-resort hide
            [void][ClodNative]::ShowWindow([ClodNative]::GetConsoleWindow(), 0)
            $script:ConsoleMode = 'hidden_fallback'
        }
    } catch { }
}

# ---------- custom controls: soft neumorphism, themeable ----------
if (-not ('ClodUi.ClodForm' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Drawing.dll', 'System.Windows.Forms.dll') -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

namespace ClodUi {

    public static class Shape {
        public static GraphicsPath Round(Rectangle r, int rad) {
            int d = Math.Max(1, rad * 2);
            if (d > r.Width) d = r.Width;
            if (d > r.Height) d = r.Height;
            var p = new GraphicsPath();
            p.StartFigure();
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
        public static Color Mix(Color c, Color with, double t) {
            return Color.FromArgb(c.A,
                (int)(c.R + (with.R - c.R) * t),
                (int)(c.G + (with.G - c.G) * t),
                (int)(c.B + (with.B - c.B) * t));
        }
        public static Color Lighten(Color c, double t) { return Mix(c, Color.White, t); }
        public static Color Darken(Color c, double t) { return Mix(c, Color.Black, t); }

        // raised: soft dark halo bottom-right + light halo top-left,
        // then the body in surface color (themesberg $box-shadow-soft)
        public static void Raised(Graphics g, Rectangle r, int rad, Color body, Color dark, Color light, int spread, int dx, int dy) {
            for (int i = spread; i >= 1; i--) {
                double t = (double)i / spread;
                int a = (int)(34 * (1 - t) + 6);
                using (var br = new SolidBrush(Color.FromArgb(a, dark)))
                using (var p = Round(new Rectangle(r.X + (int)Math.Round(dx * t), r.Y + (int)Math.Round(dy * t), r.Width, r.Height), rad))
                    g.FillPath(br, p);
            }
            for (int i = spread; i >= 1; i--) {
                double t = (double)i / spread;
                int a = (int)(60 * (1 - t) + 8);
                using (var br = new SolidBrush(Color.FromArgb(a, light)))
                using (var p = Round(new Rectangle(r.X - (int)Math.Round(dx * t), r.Y - (int)Math.Round(dy * t), r.Width, r.Height), rad))
                    g.FillPath(br, p);
            }
            using (var br = new SolidBrush(body))
            using (var p = Round(r, rad)) g.FillPath(br, p);
        }

        // inset: body first, then clipped stroked crescents - dark on the
        // inner top-left edge, light on the inner bottom-right edge
        // (themesberg $shadow-inset for inputs / active buttons)
        public static void Inset(Graphics g, Rectangle r, int rad, Color body, Color dark, Color light, int depth) {
            using (var br = new SolidBrush(body))
            using (var p = Round(r, rad)) g.FillPath(br, p);
            var old = g.Clip;
            using (var clip = Round(r, rad)) g.SetClip(clip, CombineMode.Replace);
            for (int i = 1; i <= depth; i++) {
                double t = (double)i / depth;
                int ad = (int)(150 * (1 - t) + 25);
                int al = (int)(255 * (1 - t) + 40);
                using (var pen = new Pen(Color.FromArgb(ad, dark), 2.5f))
                using (var p = Round(new Rectangle(r.X + i, r.Y + i, r.Width, r.Height), rad))
                    g.DrawPath(pen, p);
                using (var pen = new Pen(Color.FromArgb(al, light), 2.5f))
                using (var p = Round(new Rectangle(r.X - i, r.Y - i, r.Width, r.Height), rad))
                    g.DrawPath(pen, p);
            }
            g.Clip = old;
        }
    }

    // borderless rounded form with real drop shadow (CS_DROPSHADOW)
    public class ClodForm : Form {
        public int Radius = 16;
        public Color Surface = Color.FromArgb(230, 231, 238);   // themesberg $soft
        public Color Border = Color.FromArgb(214, 216, 226);
        public ClodForm() {
            DoubleBuffered = true;
            FormBorderStyle = FormBorderStyle.None;
            BackColor = Surface;
            // layout is computed from measured text (Do-Layout); WinForms
            // font auto-scaling would double-scale our runtime-set fonts
            // at DPI != 100% and make labels overlap (observed bug)
            AutoScaleMode = AutoScaleMode.None;
        }
        protected override CreateParams CreateParams {
            get { var cp = base.CreateParams; cp.ClassStyle |= 0x00020000; return cp; }
        }
        protected override void OnResize(EventArgs e) {
            base.OnResize(e);
            if (Width > 4 && Height > 4) {
                using (var p = Shape.Round(new Rectangle(0, 0, Width - 1, Height - 1), Radius))
                    Region = new Region(p);
                Invalidate();
            }
        }
        protected override void OnPaintBackground(PaintEventArgs e) { }
        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var p = Shape.Round(r, Radius))
            using (var br = new SolidBrush(Surface)) g.FillPath(br, p);
            using (var p = Shape.Round(new Rectangle(1, 1, Width - 3, Height - 3), Radius - 1))
            using (var pen = new Pen(Border, 1f)) g.DrawPath(pen, p);
        }
    }

    // inset rounded container for borderless TextBoxes (carved field)
    public class ClodPanel : Panel {
        public int Radius = 13;
        public Color Surface = Color.FromArgb(230, 231, 238);
        public Color ShadowDark = Color.FromArgb(184, 185, 190);
        public Color LightShadow = Color.White;
        public ClodPanel() {
            DoubleBuffered = true;
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            BackColor = Surface;
        }
        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Surface);
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            Shape.Inset(g, r, Radius, Surface, ShadowDark, LightShadow, 5);
        }
    }

    // micro pill button: raised by default; pressed / selected = inset.
    // Accent = filled body (AccentColor) - the only non-surface fill.
    public class ClodButton : Button {
        public int Radius = 9;
        public int Pad = 5;
        public Color Surface = Color.FromArgb(230, 231, 238);
        public Color Ink = Color.FromArgb(68, 71, 106);
        public Color ShadowDark = Color.FromArgb(184, 185, 190);
        public Color LightShadow = Color.White;
        public Color AccentColor = Color.FromArgb(68, 71, 106);
        public Color AccentText = Color.White;
        public bool Accent = false;
        public bool Selected = false;
        public float Good = 0f;   // 0..1 green success pulse overlay
        private bool _down = false;
        private bool _over = false;
        public ClodButton() {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            BackColor = Surface;
        }
        protected override bool ShowFocusCues { get { return false; } }
        protected override void OnMouseEnter(EventArgs e) { _over = true; base.OnMouseEnter(e); Invalidate(); }
        protected override void OnMouseLeave(EventArgs e) { _over = false; _down = false; base.OnMouseLeave(e); Invalidate(); }
        protected override void OnMouseDown(MouseEventArgs e) { _down = true; base.OnMouseDown(e); Invalidate(); }
        protected override void OnMouseUp(MouseEventArgs e) { _down = false; base.OnMouseUp(e); Invalidate(); }
        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            if (Width < 3 || Height < 3) return;
            g.Clear(Surface);
            var pill = new Rectangle(Pad, Pad, Width - 2 * Pad - 1, Height - 2 * Pad - 1);
            if (pill.Width < 4 || pill.Height < 4) return;
            int rad = Math.Min(Radius, pill.Height / 2);
            bool carved = _down || Selected;
            Color body = (Accent || Selected) ? AccentColor : Surface;
            if (carved) {
                Shape.Inset(g, pill, rad, body, ShadowDark, LightShadow, 4);
            } else {
                int spread = Accent ? 6 : 5;
                Shape.Raised(g, pill, rad, body, ShadowDark, LightShadow, spread, 3, 3);
                if (_over && !Accent) {
                    // hover: the pill lifts a bit more (stronger halo)
                    Shape.Raised(g, pill, rad, body, ShadowDark, LightShadow, 3, 2, 2);
                }
            }
            Color tc = (Accent || Selected) ? AccentText : Ink;
            if (carved && !Accent) tc = Shape.Darken(tc, 0.12);
            TextRenderer.DrawText(g, Text, Font, new Rectangle(0, _down ? 1 : 0, Width, Height), tc,
                Color.Transparent,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.EndEllipsis);
            if (Good > 0f) {
                // success pulse: green wash + brighter ring, alpha = Good
                int a = (int)(Good * 130);
                using (var p = Shape.Round(pill, rad))
                using (var br = new SolidBrush(Color.FromArgb(a, 46, 160, 67)))
                    g.FillPath(br, p);
                using (var p = Shape.Round(pill, rad))
                using (var pen = new Pen(Color.FromArgb((int)(Good * 220), 60, 200, 90), 2f))
                    g.DrawPath(pen, p);
            }
        }
    }
}
'@
}

# ---------- single instance ----------
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\ClodKey-Tray-Single')
if (-not $script:Mutex.WaitOne(0)) {
    Write-Log 'warn' 'second instance refused (mutex held)'
    exit 0
}

# ---------- strings (UTF-8 data, 4 locales, not code) ----------
$script:S = [pscustomobject]@{}
try {
    $script:S = [IO.File]::ReadAllText($StringsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
} catch {
    Write-Log 'error' ('strings.json load failed: ' + $_.Exception.Message)
}
$script:Langs = @('ru', 'en', 'zh', 'es')
function T([string]$Key) {
    $loc = $null
    if ($script:S -and ($script:S.PSObject.Properties.Name -contains $script:Lang)) { $loc = $script:S.$script:Lang }
    if (-not $loc -and $script:S -and ($script:S.PSObject.Properties.Name -contains 'ru')) { $loc = $script:S.ru }
    if ($loc -and ($loc.PSObject.Properties.Name -contains $Key)) { return [string]$loc.$Key }
    return $Key
}

# ---------- retry wrapper (AV / editors hold files) ----------
function Invoke-WithRetry([scriptblock]$Action, [int]$Times = 6, [int]$DelayMs = 1500) {
    for ($i = 1; $i -le $Times; $i++) {
        try { return & $Action }
        catch {
            if ($i -ge $Times) { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

# ---------- DPAPI ----------
$Entropy = [Text.Encoding]::UTF8.GetBytes('ClodKey.v1')
function Protect-String([string]$Plain) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Plain)
    $enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $Entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return 'DPAPI:' + [Convert]::ToBase64String($enc)
}
function Unprotect-String([string]$Value) {
    if ($Value -like 'DPAPI:*') {
        $enc = [Convert]::FromBase64String($Value.Substring(6))
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($enc, $Entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($plain)
    }
    # unknown format: typed ignorance, never silent default
    Write-Log 'warn' 'apiKey has unknown format, treated as empty'
    return ''
}

# ---------- store (data\secrets.json) ----------
$script:Store = $null
function Load-Store {
    if (Test-Path -LiteralPath $SecretsPath) {
        try {
            $obj = [IO.File]::ReadAllText($SecretsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -eq $obj) { throw 'empty file' }
            if (-not ($obj.PSObject.Properties.Name -contains 'profiles')) {
                $obj | Add-Member NoteProperty 'profiles' @()
            }
            $script:Store = $obj
            Write-Log 'info' ('store loaded, profiles=' + @($script:Store.profiles).Count)
            return
        } catch {
            Write-Log 'error' ('secrets load failed: ' + $_.Exception.Message + '; trying backup')
            if (Test-Path -LiteralPath "$SecretsPath.bak") {
                try {
                    $script:Store = [IO.File]::ReadAllText("$SecretsPath.bak", [Text.Encoding]::UTF8) | ConvertFrom-Json
                    Write-Log 'info' 'store restored from backup'
                    return
                } catch { Write-Log 'error' ('backup also unreadable: ' + $_.Exception.Message) }
            }
        }
    }
    $script:Store = [pscustomobject]@{ version = 1; profiles = @(); lastAppliedId = $null }
}
function Save-Store {
    $json = $script:Store | ConvertTo-Json -Depth 8
    Invoke-WithRetry {
        $dir = Split-Path -Parent $SecretsPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmp = "$SecretsPath.tmp"
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $SecretsPath) {
            Copy-Item -LiteralPath $SecretsPath -Destination "$SecretsPath.bak" -Force
        }
        Move-Item -LiteralPath $tmp -Destination $SecretsPath -Force
    }
}

# ---------- PSCustomObject property helpers ----------
function Set-Prop($Obj, [string]$Name, $Value) {
    if ($Obj.PSObject.Properties.Name -contains $Name) { $Obj.$Name = $Value }
    else { $Obj | Add-Member NoteProperty $Name $Value }
}
function Remove-Prop($Obj, [string]$Name) {
    if ($Obj.PSObject.Properties.Name -contains $Name) { $Obj.PSObject.Properties.Remove($Name) }
}

# ---------- settings (lang + theme), persisted in the store ----------
Load-Store
$script:Lang = 'ru'
$script:Theme = 'light'
if ($script:Store.PSObject.Properties.Name -contains 'settings') {
    $st = $script:Store.settings
    if ($st) {
        $l = [string]$st.lang
        if ($script:Langs -contains $l) { $script:Lang = $l }
        elseif ($l) { Write-Log 'warn' ('unknown lang in settings: ' + $l) }
        $th = [string]$st.theme
        if (@('light', 'dark') -contains $th) { $script:Theme = $th }
        elseif ($th) { Write-Log 'warn' ('unknown theme in settings: ' + $th) }
    }
}
function Save-Settings {
    Set-Prop $script:Store 'settings' ([pscustomobject]@{ lang = $script:Lang; theme = $script:Theme })
    Save-Store
}

# ---------- palettes (themesberg tokens, light + dark) ----------
function Set-Palette([string]$Name) {
    if ($Name -eq 'dark') {
        $script:surface     = [Drawing.Color]::FromArgb(42, 43, 54)
        $script:ink         = [Drawing.Color]::FromArgb(214, 216, 228)
        $script:muted       = [Drawing.Color]::FromArgb(126, 130, 152)
        $script:shadowDark  = [Drawing.Color]::FromArgb(24, 25, 32)
        $script:shadowLight = [Drawing.Color]::FromArgb(60, 62, 78)
        $script:borderClr   = [Drawing.Color]::FromArgb(54, 56, 70)
        $script:accentClr   = [Drawing.Color]::FromArgb(94, 98, 140)
        $script:accentText  = [Drawing.Color]::FromArgb(240, 241, 246)
    } else {
        $script:surface     = [Drawing.Color]::FromArgb(230, 231, 238)
        $script:ink         = [Drawing.Color]::FromArgb(68, 71, 106)
        $script:muted       = [Drawing.Color]::FromArgb(147, 165, 190)
        $script:shadowDark  = [Drawing.Color]::FromArgb(184, 185, 190)
        $script:shadowLight = [Drawing.Color]::FromArgb(255, 255, 255)
        $script:borderClr   = [Drawing.Color]::FromArgb(214, 216, 226)
        $script:accentClr   = [Drawing.Color]::FromArgb(68, 71, 106)
        $script:accentText  = [Drawing.Color]::FromArgb(255, 255, 255)
    }
}
Set-Palette $script:Theme

# ---------- font stack (try newest first, verify GDI+ did not substitute) ----------
function New-FontFromStack([string[]]$Names, [single]$Size, [Drawing.FontStyle]$Style) {
    foreach ($n in $Names) {
        try {
            $f = New-Object Drawing.Font($n, $Size, $Style)
            if ($f.Name -eq $n) { return $f }
        } catch { }
    }
    return New-Object Drawing.Font('Segoe UI', $Size, $Style)
}
function New-UiFont([double]$Size, [bool]$Bold) {
    $style = [Drawing.FontStyle]::Regular
    if ($Bold) { $style = [Drawing.FontStyle]::Bold }
    return New-FontFromStack @('Segoe UI Variable Text', 'Segoe UI') ([single]$Size) $style
}

$REG  = [Drawing.FontStyle]::Regular
$BOLD = [Drawing.FontStyle]::Bold
# title: presentational face; micro labels: DIN-like tech face (has
# Cyrillic, GDI+ falls back per-glyph for CJK); input: programmer's mono
$fontUi    = New-FontFromStack @('Segoe UI Variable Text', 'Segoe UI') 9.0 $REG
$fontUiB   = New-FontFromStack @('Segoe UI Variable Text', 'Segoe UI') 9.0 $BOLD
$fontTitle = New-FontFromStack @('Segoe UI Variable Display', 'Bahnschrift SemiBold', 'Segoe UI Semibold', 'Segoe UI') 12.5 $BOLD
$fontMicro = New-FontFromStack @('Bahnschrift', 'Segoe UI Variable Text', 'Segoe UI') 8.25 $REG
$fontMono  = New-FontFromStack @('Cascadia Code', 'Cascadia Mono', 'Consolas') 9.0 $REG
$fontGlyph = New-FontFromStack @('Segoe UI Variable Text', 'Segoe UI', 'Microsoft YaHei', 'Segoe UI Emoji') 9.0 $REG

# ---------- system keys discovery (~/.claude/settings.json + env vars) ----------
# Priority: settings.json FIRST, then env vars fill only what it does not
# define. settings.json is what Claude CLI actually uses and what "Apply"
# writes - a stale ANTHROPIC_* env var must never shadow a freshly applied
# key (reported bug: apply new -> import returns old from env).
# $Override lets the selftest inject env values deterministically;
# the real app calls this with no arguments.
function Get-SystemEnv([hashtable]$Override) {
    $vals = @{}
    $p = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path -LiteralPath $p) {
        try {
            $d = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($d -and $d.env) {
                foreach ($n in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL')) {
                    if ($d.env.PSObject.Properties.Name -contains $n) {
                        $v = [string]$d.env.$n
                        if ($v) { $vals[$n] = $v }
                    }
                }
            }
        } catch { Write-Log 'warn' ('settings.json read failed: ' + $_.Exception.Message) }
    }
    if ($Override) {
        foreach ($k in $Override.Keys) { if ($Override[$k] -and -not $vals[$k]) { $vals[$k] = [string]$Override[$k] } }
    } else {
        foreach ($n in @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL')) {
            if (-not $vals[$n]) {
                $v = [Environment]::GetEnvironmentVariable($n, 'User')
                if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, 'Machine') }
                if ($v) { $vals[$n] = [string]$v }
            }
        }
    }
    return $vals
}

# A profile is "the system one" if flagged, or - for stores written
# before the flag existed (legacy) - if its name equals sys_name in any
# locale. Without this, a legacy profile is invisible to rename/dedup
# and the NAME field keeps the old-language name after switching (bug).
function Test-SystemProfile($P) {
    if ($null -eq $P) { return $false }
    if ($P.PSObject.Properties.Name -contains 'system' -and [bool]$P.system) { return $true }
    foreach ($loc in $script:Langs) {
        $n = $null
        if ($script:S -and ($script:S.PSObject.Properties.Name -contains $loc)) {
            $o = $script:S.$loc
            if ($o -and ($o.PSObject.Properties.Name -contains 'sys_name')) { $n = [string]$o.sys_name }
        }
        if ($n -and ([string]$P.name -eq $n)) { return $true }
    }
    return $false
}

function Import-System([bool]$Silent, [hashtable]$EnvOverride) {
    $vals = Get-SystemEnv $EnvOverride
    $key = $null
    $mode = 'both'
    if ($vals['ANTHROPIC_API_KEY'] -and $vals['ANTHROPIC_AUTH_TOKEN']) { $key = $vals['ANTHROPIC_API_KEY']; $mode = 'both' }
    elseif ($vals['ANTHROPIC_API_KEY']) { $key = $vals['ANTHROPIC_API_KEY']; $mode = 'api_key' }
    elseif ($vals['ANTHROPIC_AUTH_TOKEN']) { $key = $vals['ANTHROPIC_AUTH_TOKEN']; $mode = 'auth_token' }
    if (-not $key) {
        if (-not $Silent) { Set-Status (T 'sys_none') }
        return $false
    }
    $base = $vals['ANTHROPIC_BASE_URL']
    if (-not $base) { $base = 'https://api.anthropic.com' }
    $profiles = @($script:Store.profiles)
    $sysList = @($profiles | Where-Object { Test-SystemProfile $_ })
    if ($sysList.Count -gt 1) {
        # dedup legacy duplicates (old unflagged + new flagged): keep first
        $keepId = [string]$sysList[0].id
        $profiles = @($profiles | Where-Object { -not (Test-SystemProfile $_) -or [string]$_.id -eq $keepId })
        Set-Prop $script:Store 'profiles' $profiles
        Save-Store
        Write-Log 'info' ('deduped system profiles, kept ' + $keepId)
    }
    $existing = $null
    if ($sysList.Count -gt 0) { $existing = $sysList[0] }
    if ($existing -and -not ($existing.PSObject.Properties.Name -contains 'system')) {
        # migrate legacy profile: stamp the flag once
        $existing | Add-Member NoteProperty 'system' $true
        Set-Prop $script:Store 'profiles' $profiles
        Save-Store
        Write-Log 'info' 'legacy system profile migrated (flag added)'
    }
    if ($existing -and (Unprotect-String ([string]$existing.apiKey)) -eq $key) {
        # already imported: do not touch user edits, but the button must
        # still give feedback - silence read as "did not load" (bug)
        if (-not $Silent) { Set-Status (T 'sys_exists') }
        return $true
    }
    $prof = [pscustomobject]@{
        id        = $(if ($existing) { [string]$existing.id } else { [guid]::NewGuid().ToString() })
        name      = (T 'sys_name')
        baseUrl   = $base.TrimEnd('/')
        apiKey    = (Protect-String $key)
        authMode  = $mode
        system    = $true
        updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $found = $false
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        if ([string]$profiles[$i].id -eq [string]$prof.id) { $profiles[$i] = $prof; $found = $true; break }
    }
    if (-not $found) { $profiles += $prof }
    Set-Prop $script:Store 'profiles' $profiles
    Save-Store
    Write-Log 'info' 'system keys imported'
    if (-not $Silent) { Set-Status (T 'sys_imported') }
    return $true
}

# ---------- apply profile to Claude CLI settings ----------
function Apply-ToClaudeCli($Prof) {
    $keyPlain = Unprotect-String ([string]$Prof.apiKey)
    if (-not $keyPlain) { throw 'empty key' }
    $dir  = Join-Path $env:USERPROFILE '.claude'
    $path = Join-Path $dir 'settings.json'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $doc = $null
    if (Test-Path -LiteralPath $path) {
        $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        if ($raw.Trim().Length -gt 0) {
            try { $doc = $raw | ConvertFrom-Json }
            catch { throw ('settings.json parse failed, file untouched: ' + $_.Exception.Message) }
        }
    }
    if ($null -eq $doc) { $doc = [pscustomobject]@{} }
    if ($doc -isnot [pscustomobject]) { $doc = [pscustomobject]@{} }
    if (-not ($doc.PSObject.Properties.Name -contains 'env')) {
        $doc | Add-Member NoteProperty 'env' ([pscustomobject]@{})
    }
    $e = $doc.env
    if ($e -isnot [pscustomobject]) { $e = [pscustomobject]@{}; Set-Prop $doc 'env' $e }

    Set-Prop $e 'ANTHROPIC_BASE_URL' ([string]$Prof.baseUrl.TrimEnd('/'))
    $mode = [string]$Prof.authMode
    if ($mode -eq 'api_key') {
        Set-Prop $e 'ANTHROPIC_API_KEY' $keyPlain
        Remove-Prop $e 'ANTHROPIC_AUTH_TOKEN'
    } elseif ($mode -eq 'auth_token') {
        Set-Prop $e 'ANTHROPIC_AUTH_TOKEN' $keyPlain
        Remove-Prop $e 'ANTHROPIC_API_KEY'
    } else {
        Set-Prop $e 'ANTHROPIC_API_KEY' $keyPlain
        Set-Prop $e 'ANTHROPIC_AUTH_TOKEN' $keyPlain
    }
    # model pin: the profile fully describes the env block - a profile
    # without a model REMOVES the pin (CLI falls back to its default)
    if ($Prof.PSObject.Properties.Name -contains 'model' -and [string]$Prof.model) {
        Set-Prop $e 'ANTHROPIC_MODEL' ([string]$Prof.model)
    } else {
        Remove-Prop $e 'ANTHROPIC_MODEL'
    }

    Invoke-WithRetry {
        if (Test-Path -LiteralPath $path) {
            Copy-Item -LiteralPath $path -Destination "$path.clodkey.bak" -Force
        }
        $tmp = "$path.clodkey.tmp"
        [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
    Set-Prop $script:Store 'lastAppliedId' ([string]$Prof.id)
    Save-Store
    Write-Log 'info' ('applied profile "' + [string]$Prof.name + '" to ' + $path)
    return $path
}

# ============================================================
# UI - soft-neumorphic mini flyout anchored to the tray
# ============================================================
# control registries for theme/language re-application
$script:Buttons = New-Object System.Collections.ArrayList
$script:Panels  = New-Object System.Collections.ArrayList
$script:Labels  = New-Object System.Collections.ArrayList
$script:Fields  = New-Object System.Collections.ArrayList
$script:FieldPairs = New-Object System.Collections.ArrayList

# ---------- icon: drawn with GDI+, no external .ico ----------
function New-ClodKeyIcon {
    $bmp = New-Object Drawing.Bitmap(32, 32)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([Drawing.Color]::Transparent)
        # soft tile: same surface color as the flyout, ink key glyph
        $rect = New-Object Drawing.Rectangle(2, 2, 28, 28)
        $path = New-Object Drawing.Drawing2D.GraphicsPath
        $d = 16
        $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
        $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
        $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
        $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
        $path.CloseFigure()
        $br = New-Object Drawing.SolidBrush($script:surface)
        $g.FillPath($br, $path)
        $br.Dispose(); $path.Dispose()
        $pen = New-Object Drawing.Pen($script:ink, 2.6)
        $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $g.DrawEllipse($pen, 7, 7, 9, 9)
        $g.DrawLine($pen, 15, 15, 25, 25)
        $g.DrawLine($pen, 20, 20, 23, 17)
        $g.DrawLine($pen, 23, 23, 26, 20)
        $pen.Dispose()
        $hicon = $bmp.GetHicon()
        return [Drawing.Icon]::FromHandle($hicon)
    } finally {
        $g.Dispose()
    }
}
$script:AppIcon = New-ClodKeyIcon

# ---------- form ----------
$form = New-Object ClodUi.ClodForm
$form.Text = T 'app_title'
$form.ClientSize = New-Object Drawing.Size(300, 486)
$form.StartPosition = 'Manual'
$form.ForeColor = $script:ink
$form.Font = $fontUi
$form.Icon = $script:AppIcon
$form.ShowInTaskbar = $true
$form.TopMost = $false
$form.Opacity = 1.0
# sync the form's own palette with the persisted theme at boot
# (Apply-Theme only runs on toggle; the C# defaults are light)
$form.Surface = $script:surface
$form.Border = $script:borderClr
$form.BackColor = $script:surface

# ---------- hover tooltips ("mini hovers") ----------
$script:Tips = New-Object Windows.Forms.ToolTip
$script:Tips.IsBalloon = $false
$script:Tips.BackColor = $script:ink
$script:Tips.ForeColor = [Drawing.Color]::White
$script:Tips.AutomaticDelay = 350
$script:Tips.UseAnimation = $true
$script:Tips.UseFading = $true
function Tip($Ctl, [string]$Key) {
    $script:Tips.SetToolTip($Ctl, (T $Key))
}

function New-MicroLabel([string]$Text, [int]$X, [int]$Y) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    $l.Location = New-Object Drawing.Point($X, $Y)
    $l.ForeColor = $script:muted
    $l.BackColor = [Drawing.Color]::Transparent
    $l.Font = $fontMicro
    $form.Controls.Add($l)
    [void]$script:Labels.Add($l)
    return $l
}

function New-Field([string]$Name, [int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Mono) {
    $panel = New-Object ClodUi.ClodPanel
    $panel.Surface = $script:surface
    $panel.ShadowDark = $script:shadowDark
    $panel.LightShadow = $script:shadowLight
    $tb = New-Object Windows.Forms.TextBox
    $tb.BorderStyle = 'None'
    $tb.BackColor = $script:surface
    $tb.ForeColor = $script:ink
    $tbFont = $fontUi
    if ($Mono) { $tbFont = $fontMono }
    $tb.Font = $tbFont
    $panel.Controls.Add($tb)
    $form.Controls.Add($panel)
    [void]$script:Panels.Add($panel)
    [void]$script:Fields.Add($tb)
    [void]$script:FieldPairs.Add(@{ panel = $panel; tb = $tb })
    Set-Variable -Name $Name -Value $tb -Scope Script
    return $panel
}

function New-MicroButton([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [bool]$IsAccent) {
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
    $form.Controls.Add($b)
    [void]$script:Buttons.Add($b)
    return $b
}

function New-IconButton([string]$Glyph, [int]$X, [int]$Y) {
    $b = New-MicroButton $Glyph $X $Y 26 26 $false
    $b.Pad = 4
    $b.Radius = 11
    $b.Font = $fontGlyph
    return $b
}

# ---------- header (drag handle) + icon row ----------
$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text = (T 'app_title')
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = $script:ink
$lblTitle.BackColor = [Drawing.Color]::Transparent
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object Drawing.Point(14, 10)
$form.Controls.Add($lblTitle)

$lblDot = New-Object Windows.Forms.Label
$lblDot.Text = (T 'app_sub')
$lblDot.Font = $fontMicro
$lblDot.ForeColor = $script:muted
$lblDot.BackColor = [Drawing.Color]::Transparent
$lblDot.AutoSize = $true
$lblDot.Location = New-Object Drawing.Point(15, 31)
$form.Controls.Add($lblDot)

# micro icon buttons, no text: lang x4, theme, tea, close
$btnLangRu  = New-IconButton (T 'glyph_ru') 104 8
$btnLangEn  = New-IconButton (T 'glyph_en') 130 8
$btnLangZh  = New-IconButton (T 'glyph_zh') 156 8
$btnLangEs  = New-IconButton (T 'glyph_es') 182 8
$btnLogs    = New-IconButton (T 'glyph_logs') 208 8
Tip $btnLogs 'tip_logs'
$btnLogs.Add_Click({ Show-Logs })
$btnTheme   = New-IconButton (T 'glyph_theme_light') 234 8
$btnTea     = New-IconButton (T 'glyph_tea') 238 8
$btnClose   = New-IconButton (T 'btn_close') 264 8
$script:LangBtns = @{ ru = $btnLangRu; en = $btnLangEn; zh = $btnLangZh; es = $btnLangEs }

Tip $btnLangRu 'tip_lang'; Tip $btnLangEn 'tip_lang'; Tip $btnLangZh 'tip_lang'; Tip $btnLangEs 'tip_lang'
Tip $btnTheme 'tip_theme'; Tip $btnTea 'tip_tea'; Tip $btnClose 'tip_close'

function Update-LanguageButtons {
    foreach ($k in $script:Langs) {
        $script:LangBtns[$k].Selected = ($k -eq $script:Lang)
        $script:LangBtns[$k].Invalidate()
    }
}
function Update-ThemeButton {
    if ($script:Theme -eq 'dark') { $btnTheme.Text = T 'glyph_theme_dark' }
    else { $btnTheme.Text = T 'glyph_theme_light' }
    $btnTheme.Invalidate()
}

function Set-Lang([string]$L) {
    if (-not ($script:Langs -contains $L)) { Write-Log 'warn' ('unknown lang: ' + $L); return }
    $script:Lang = $L
    Save-Settings
    Apply-Language
    Write-Log 'info' ('lang=' + $L)
}

function Set-Theme([string]$Th) {
    if (-not (@('light', 'dark') -contains $Th)) { Write-Log 'warn' ('unknown theme: ' + $Th); return }
    $script:Theme = $Th
    Save-Settings
    Apply-Theme
    Update-ThemeButton
    Write-Log 'info' ('theme=' + $Th)
}

$btnLangRu.Add_Click({ Set-Lang 'ru' })
$btnLangEn.Add_Click({ Set-Lang 'en' })
$btnLangZh.Add_Click({ Set-Lang 'zh' })
$btnLangEs.Add_Click({ Set-Lang 'es' })
$btnTheme.Add_Click({
    if ($script:Theme -eq 'light') { Set-Theme 'dark' } else { Set-Theme 'light' }
})
$btnTea.Add_Click({
    Set-Status (T 'tea_msg')
    Write-Log 'info' 'tea break'
})

# drag the borderless window by its header
$dragHeader = {
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) {
        [void][ClodNative]::ReleaseCapture()
        [void][ClodNative]::SendMessage($form.Handle, 0xA1, [IntPtr]2, [IntPtr]0)
    }
}
$lblTitle.Add_MouseDown($dragHeader)
$lblDot.Add_MouseDown($dragHeader)

# ---------- profile list (owner-drawn, inset selection) ----------
$lblProfiles = New-MicroLabel (T 'lbl_profiles') 14 48
$btnImport = New-MicroButton (T 'btn_import') 214 44 74 22 $false
Tip $btnImport 'tip_import'

$lvWell = New-Object ClodUi.ClodPanel
$lvWell.Location = New-Object Drawing.Point(6, 62)
$lvWell.Size = New-Object Drawing.Size(288, 108)
$lvWell.Radius = 14
$lvWell.Surface = $script:surface
$lvWell.ShadowDark = $script:shadowDark
$lvWell.LightShadow = $script:shadowLight
$form.Controls.Add($lvWell)
[void]$script:Panels.Add($lvWell)

$lv = New-Object Windows.Forms.ListView
$lv.Location = New-Object Drawing.Point(10, 66)
$lv.Size = New-Object Drawing.Size(280, 100)
$lv.View = 'Details'
$lv.FullRowSelect = $true
$lv.HideSelection = $false
$lv.MultiSelect = $false
$lv.OwnerDraw = $true
$lv.BackColor = $script:surface
$lv.ForeColor = $script:ink
$lv.BorderStyle = 'None'
$lv.Font = $fontUi
[void]$lv.Columns.Add((T 'col_name'), 92)
[void]$lv.Columns.Add((T 'col_base'), 128)
[void]$lv.Columns.Add((T 'col_updated'), 52)
$form.Controls.Add($lv)

$lv.Add_DrawColumnHeader({
    param($s, $e)
    $e.DrawText = $false
    $g = $e.Graphics
    # kill the default gray header band: paint surface, then our text
    $g.Clear($surface)
    $b = New-Object Drawing.SolidBrush($muted)
    $g.DrawString($e.Text, $fontMicro, $b, $e.Bounds.X + 4, $e.Bounds.Y + 1)
    $b.Dispose()
})
$lv.Add_DrawItem({
    param($s, $e)
    if ($e.ItemIndex -ge 0) {
        $e.DrawBackground = $false
        # system focus rectangle paints solid blue over owner-draw rows
        $e.DrawFocusRectangle = $false
    }
})
$lv.Add_DrawSubItem({
    param($s, $e)
    $g = $e.Graphics
    $b = $e.SubItem.Bounds
    $sel = $e.Item.Selected
    if ($sel) {
        $r = New-Object Drawing.Rectangle(2, ($b.Y + 1), ($lv.Width - 6), ($b.Height - 2))
        [ClodUi.Shape]::Inset($g, $r, 9, $surface, $shadowDark, $shadowLight, 3)
    } else {
        $g.Clear($surface)
    }
    $clr = $muted
    if ($sel) { $clr = $ink }
    elseif ($e.ColumnIndex -eq 0) { $clr = $ink }
    $tb = New-Object Drawing.SolidBrush($clr)
    $fmt = New-Object Drawing.StringFormat
    $fmt.Trimming = [Drawing.StringTrimming]::EllipsisCharacter
    $rectB = New-Object Drawing.RectangleF(($b.X + 8), ($b.Y + 2), ($b.Width - 12), ($b.Height - 4))
    $g.DrawString($e.SubItem.Text, $fontUi, $tb, $rectB, $fmt)
    $tb.Dispose()
})

# ---------- fields (positions: Do-Layout) ----------
$lblName = New-MicroLabel (T 'lbl_name') 14 172
$pnlName = New-Field 'txtName' 10 190 280 30 $false

$lblBase = New-MicroLabel (T 'lbl_base') 14 222
$pnlBase = New-Field 'txtBase' 10 240 280 30 $true

$lblKey = New-MicroLabel (T 'lbl_key') 14 272
$pnlKey = New-Field 'txtKey' 10 290 246 30 $true
$txtKey.UseSystemPasswordChar = $true

$btnEye = New-MicroButton (T 'eye_open') 258 290 32 28 $false
$btnEye.Font = New-UiFont 9.0 $false
Tip $btnEye 'tip_eye'

# ---------- model dropdown: probed live from base url + key ----------
$lblModel = New-MicroLabel (T 'lbl_model') 14 322
$cmbModel = New-Object Windows.Forms.ComboBox
$cmbModel.DropDownStyle = 'DropDownList'
$cmbModel.DrawMode = 'OwnerDrawFixed'
$cmbModel.ItemHeight = 24
$cmbModel.FlatStyle = 'Flat'
$cmbModel.BackColor = $script:surface
$cmbModel.ForeColor = $script:ink
$cmbModel.Font = $fontUi
$form.Controls.Add($cmbModel)
Tip $cmbModel 'tip_model'

# neumorphic skin: the native flat combo draws a square button and a
# hard 1px border - repaint the whole face as a carved inset pill with
# a hand-drawn chevron, matching the text fields. DrawItem keeps its
# own styling for the dropdown rows (separate popup window).
$comboDbProp = $cmbModel.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Instance)
$comboDbProp.SetValue($cmbModel, $true, $null)
$cmbModel.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($script:surface)
    $r = New-Object Drawing.Rectangle(0, 0, ($cmbModel.Width - 1), ($cmbModel.Height - 1))
    [ClodUi.Shape]::Inset($g, $r, 13, $script:surface, $script:shadowDark, $script:shadowLight, 4)
    $cy = [int](($cmbModel.Height - 1) / 2)
    $cx = $cmbModel.Width - 18
    $pen = New-Object Drawing.Pen($script:muted, 1.8)
    $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $pts = @(
        [Drawing.PointF]::new(($cx - 4), ($cy - 2)),
        [Drawing.PointF]::new($cx, ($cy + 3)),
        [Drawing.PointF]::new(($cx + 4), ($cy - 2))
    )
    $g.DrawLines($pen, $pts)
    $pen.Dispose()
    # closed face: name + state badge (the native display area is repainted
    # over, so DrawItem's row styling must be reproduced here)
    if ($cmbModel.SelectedItem) {
        $item = $cmbModel.SelectedItem
        $st = [string]$item.state
        $badge = Get-ModelBadge $st
        $bw = [Windows.Forms.TextRenderer]::MeasureText($badge, $fontMicro).Width + 12
        $fmt = New-Object Drawing.StringFormat
        $fmt.Trimming = [Drawing.StringTrimming]::EllipsisCharacter
        $fmt.LineAlignment = [Drawing.StringAlignment]::Center
        $rect = New-Object Drawing.RectangleF(12, 0, ($cmbModel.Width - 36 - $bw), ($cmbModel.Height - 1))
        $tb = New-Object Drawing.SolidBrush($script:ink)
        $g.DrawString([string]$item.id, $fontUi, $tb, $rect, $fmt)
        $tb.Dispose()
        $badgeClr = [Drawing.Color]::FromArgb(147, 165, 190)
        if ($st -eq 'ok') { $badgeClr = [Drawing.Color]::FromArgb(46, 160, 67) }
        if ($st -eq 'quota') { $badgeClr = [Drawing.Color]::FromArgb(210, 153, 34) }
        if ($st -eq 'err') { $badgeClr = [Drawing.Color]::FromArgb(218, 54, 54) }
        $bb = New-Object Drawing.SolidBrush($badgeClr)
        $g.DrawString($badge, $fontMicro, $bb, ($cmbModel.Width - 24 - $bw + 4), [int](($cmbModel.Height - 12) / 2))
        $bb.Dispose()
    }
})

# manual re-check button (the probe is automatic, but a visible "redo"
# control was requested): clears the fingerprint guard and relaunches
$btnRefresh = New-MicroButton (T 'glyph_refresh') 258 322 30 26 $false
$btnRefresh.Font = $fontGlyph
Tip $btnRefresh 'tip_refresh'
$btnRefresh.Add_Click({ $script:ProbeLastFp = $null; Start-ModelProbe })

$script:ProbeId = 0
$script:ProbeMyId = 0
$script:ProbePS = $null
$script:ProbeRS = $null
$script:ProbeHandle = $null
$script:ProbeRunning = $false
$script:ProbeLastFp = $null
$script:ModelReverting = $false
$script:LastGoodModelIdx = -1

function Get-ModelBadge([string]$State) {
    if ($State -eq 'ok') { return 'OK' }
    if ($State -eq 'quota') { return 'QUOTA' }
    if ($State -eq 'pending') { return '...' }
    return 'ERR'
}

# self-contained: runs in a background MTA runspace, returns a hashtable
# { status = ok|badkey; models = @( @{id;state}, ... ) }. Classification:
# 200 -> ok; 402/429 or quota-ish body -> quota; anything else -> err.
$script:ProbeScript = {
    param($Base, $Key)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $UA = 'claude-cli/1.0.83 (external, cli)'
    $H = @{ Authorization = ('Bearer ' + $Key); 'x-api-key' = $Key; 'User-Agent' = $UA; 'anthropic-version' = '2023-06-01' }
    $out = @{ status = 'ok'; models = @(); authApi = $false; authBearer = $false }
    # auth method detection: which single header does the gateway accept?
    # /v1/models is free (no quota), so two extra probes cost nothing.
    try {
        $null = Invoke-WebRequest -Uri ($Base.TrimEnd('/') + '/v1/models') -Headers @{ 'x-api-key' = $Key; 'User-Agent' = $UA } -TimeoutSec 10 -UseBasicParsing
        $out.authApi = $true
    } catch { }
    try {
        $null = Invoke-WebRequest -Uri ($Base.TrimEnd('/') + '/v1/models') -Headers @{ 'Authorization' = ('Bearer ' + $Key); 'User-Agent' = $UA } -TimeoutSec 10 -UseBasicParsing
        $out.authBearer = $true
    } catch { }
    if (-not $out.authApi -and -not $out.authBearer) {
        $out.status = 'badkey'
        return $out
    }
    try {
        $r = Invoke-WebRequest -Uri ($Base.TrimEnd('/') + '/v1/models') -Headers $H -TimeoutSec 12 -UseBasicParsing
        $d = $r.Content | ConvertFrom-Json
        $ids = @($d.data | ForEach-Object { [string]$_.id } | Where-Object { $_ } | Select-Object -First 8)
    } catch {
        $out.status = 'badkey'
        return $out
    }
    # The gateway runs a deterministic CONTENT FILTER before the model
    # (measured in api-test/README.md): literal short strings like "ok"
    # are rejected even on healthy models, while appending one neutral
    # nudge sentence rescues 12/12 refused payloads. The old probe body
    # was exactly such a literal -> false ERR on working models. Ladder:
    # nudged probe first, one rephrased retry, only then err. 402/429
    # short-circuits to quota immediately.
    foreach ($id in $ids) {
        $state = 'err'; $det = ''
        $bodies = @(
            ('{"model":"' + $id + '","max_tokens":8,"messages":[{"role":"user","content":"ok (Please respond to the message above.)"}]}'),
            ('{"model":"' + $id + '","max_tokens":8,"messages":[{"role":"user","content":"What is 2+2? Reply with just the number."}]}')
        )
        foreach ($body in $bodies) {
            try {
                # 30 s, not 12: measured gpt-5.6-sol answers 200 in ~9 s
                # under a quiet line and blows a 12 s budget under the
                # sequential probe load -> false ERR (HTTP 0 = timeout)
                $null = Invoke-WebRequest -Uri ($Base.TrimEnd('/') + '/v1/messages') -Method POST -Body $body -ContentType 'application/json' -Headers $H -TimeoutSec 30 -UseBasicParsing
                $state = 'ok'; break
            } catch {
                $code = 0; $msg = ''
                try {
                    $resp = $_.Exception.Response
                    if ($resp) {
                        $code = [int]$resp.StatusCode
                        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                        $msg = $sr.ReadToEnd(); $sr.Close()
                    }
                } catch { }
                $det = ('HTTP ' + $code)
                if ($code -eq 402 -or $code -eq 429 -or $msg -match 'quota|exhausted|insufficient|billing') { $state = 'quota'; break }
                $state = 'err'
            }
        }
        $out.models += @{ id = $id; state = $state; detail = $det }
    }
    return $out
}

function Mask-Key([string]$K) {
    if (-not $K) { return '(empty)' }
    if ($K.Length -le 12) { return 'len=' + $K.Length }
    return ($K.Substring(0, 8) + '...' + $K.Substring($K.Length - 4) + ' len=' + $K.Length)
}

function Start-ModelProbe {
    $base = $txtBase.Text.Trim().TrimEnd('/')
    $key = $txtKey.Text
    if ($key.Length -lt 12 -or $base -notmatch '^https?://') { return }
    # fingerprint guard: boot probe + TextChanged debounce must not launch
    # the same check twice
    $fp = $base + '|' + $key
    if ($script:ProbeRunning -and $fp -eq $script:ProbeLastFp) {
        Write-Log 'info' 'probe skipped: same fingerprint already running'
        return
    }
    $script:ProbeLastFp = $fp
    Write-Log 'info' ('probe start: base=' + $base + ' key=' + (Mask-Key $key))
    if ($script:ProbePS) {
        try { $script:ProbePS.Stop() } catch { }
        try { $script:ProbePS.Dispose() } catch { }
        try { $script:ProbeRS.Dispose() } catch { }
    }
    $script:ProbeId++
    $script:ProbeMyId = $script:ProbeId
    $script:ProbeRS = [runspacefactory]::CreateRunspace()
    $script:ProbeRS.ApartmentState = 'MTA'
    $script:ProbeRS.Open()
    $script:ProbePS = [PowerShell]::Create()
    $script:ProbePS.Runspace = $script:ProbeRS
    [void]$script:ProbePS.AddScript($script:ProbeScript).AddArgument($base).AddArgument($key)
    $script:ProbeHandle = $script:ProbePS.BeginInvoke()
    $script:ProbeRunning = $true
    $script:ProgTick = 0
    $pnlProgress.Visible = $true
    $script:ProgTimer.Start()
    Set-Status (T 'models_loading')
    $script:ProbeTimer.Start()
}

$script:ProbeTimer = New-Object Windows.Forms.Timer
$script:ProbeTimer.Interval = 250
$script:ProbeTimer.Add_Tick({
    if (-not $script:ProbeHandle -or -not $script:ProbeHandle.IsCompleted) { return }
    $script:ProbeTimer.Stop()
    $res = $null
    try { $res = $script:ProbePS.EndInvoke($script:ProbeHandle) } catch { }
    try { $script:ProbePS.Dispose() } catch { }
    try { $script:ProbeRS.Dispose() } catch { }
    $script:ProbePS = $null; $script:ProbeRS = $null; $script:ProbeHandle = $null
    if ($script:ProbeId -ne $script:ProbeMyId) { return }   # stale: newer probe owns the UI
    $script:ProbeRunning = $false
    $script:ProgTimer.Stop()
    $pnlProgress.Visible = $false
    if (-not $res -or @($res).Count -lt 1) { return }
    $data = @($res)[0]
    if ([string]$data.status -eq 'badkey') {
        Write-Log 'info' 'probe result: badkey (neither auth header accepted)'
        $cmbModel.Items.Clear()
        $script:LastGoodModelIdx = -1
        Set-Status (T 'models_badkey')
        return
    }
    Write-Log 'info' ('probe auth: x-api-key=' + [string]$data.authApi + ' bearer=' + [string]$data.authBearer)
    # detected auth method: select the segment and keep it glowing green
    # until the user picks a mode manually
    $authLbl = ''
    if ($data.authApi -and $data.authBearer) {
        Set-Mode 'both'; Start-Glow $segBoth; $authLbl = (T 'seg_both')
    } elseif ($data.authApi) {
        Set-Mode 'api_key'; Start-Glow $segApi; $authLbl = (T 'seg_api')
    } elseif ($data.authBearer) {
        Set-Mode 'auth_token'; Start-Glow $segToken; $authLbl = (T 'seg_token')
    }
    $script:DetectedAuth = $authLbl
    $prev = $null
    if ($cmbModel.SelectedItem) { $prev = [string]$cmbModel.SelectedItem.id }
    $cmbModel.Items.Clear()
    $script:LastGoodModelIdx = -1
    $okN = 0; $qN = 0
    foreach ($m in @($data.models)) {
        $obj = [pscustomobject]@{ id = [string]$m.id; state = [string]$m.state }
        # per-model verdict + HTTP detail into the log: validates the
        # content-filter diagnosis for any future false ERR
        Write-Log 'info' ('probe: ' + [string]$m.id + ' = ' + [string]$m.state + ' ' + [string]$m.detail)
        $i = $cmbModel.Items.Add($obj)
        if ($obj.state -eq 'ok') {
            $okN++
            if ($script:LastGoodModelIdx -lt 0) { $script:LastGoodModelIdx = $i }
        } elseif ($obj.state -eq 'quota') { $qN++ }
    }
    if ($cmbModel.Items.Count -eq 0) { Set-Status (T 'models_none'); return }
    $script:DetectedAuth = $authLbl
    $target = -1
    if ($prev) {
        for ($i = 0; $i -lt $cmbModel.Items.Count; $i++) {
            if ($cmbModel.Items[$i].id -eq $prev -and $cmbModel.Items[$i].state -eq 'ok') { $target = $i; break }
        }
    }
    if ($target -lt 0) { $target = $script:LastGoodModelIdx }
    if ($target -ge 0) {
        $script:ModelReverting = $true
        $cmbModel.SelectedIndex = $target
        $script:ModelReverting = $false
        $script:LastGoodModelIdx = $target
    }
    Set-Status ((T 'models_ready') -f $okN, $qN, $script:DetectedAuth)
})

# persistent green glow on the detected auth segment: breathes forever
# until the user clicks ANY mode manually (Set-Mode calls Stop-Glow)
$script:GlowTarget = $null
$script:GlowPhase = 0
$script:GlowTimer = New-Object Windows.Forms.Timer
$script:GlowTimer.Interval = 40
$script:GlowTimer.Add_Tick({
    if (-not $script:GlowTarget) { $script:GlowTimer.Stop(); return }
    $script:GlowPhase = ($script:GlowPhase + 1)
    $script:GlowTarget.Good = 0.30 + 0.22 * [Math]::Sin(($script:GlowPhase / 14.0) * [Math]::PI * 2.0)
    $script:GlowTarget.Invalidate()
})
function Start-Glow($btn) {
    if (-not $btn) { return }
    $script:GlowTarget = $btn
    $script:GlowPhase = 0
    $script:GlowTimer.Start()
}
function Stop-Glow {
    $script:GlowTimer.Stop()
    if ($script:GlowTarget) { $script:GlowTarget.Good = 0; $script:GlowTarget.Invalidate() }
    $script:GlowTarget = $null
}

# debounce: probe ~0.9 s after the last key/base keystroke
$script:KeyTimer = New-Object Windows.Forms.Timer
$script:KeyTimer.Interval = 900
$script:KeyTimer.Add_Tick({ $script:KeyTimer.Stop(); Write-Log 'info' 'probe debounce fired'; Start-ModelProbe })
$txtKey.Add_TextChanged({ $script:KeyTimer.Stop(); $script:KeyTimer.Start() })
$txtBase.Add_TextChanged({ $script:KeyTimer.Stop(); $script:KeyTimer.Start() })

# ---------- progress strip: marquee while a probe runs ----------
# The check takes 10-30 s (auth detection + per-model probes); without a
# live indicator the window looks frozen. Thin inset track + moving accent
# segment, visible only during probing.
$pnlProgress = New-Object Windows.Forms.Panel
$pnlProgress.BackColor = $script:surface
$pnlProgress.Size = New-Object Drawing.Size(276, 6)
$pnlProgress.Visible = $false
$form.Controls.Add($pnlProgress)
$script:ProgTick = 0
$script:ProgTimer = New-Object Windows.Forms.Timer
$script:ProgTimer.Interval = 30
$script:ProgTimer.Add_Tick({
    $script:ProgTick = ($script:ProgTick + 1) % 40
    $pnlProgress.Invalidate()
})
$pnlProgress.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($script:surface)
    $w = $pnlProgress.Width; $h = $pnlProgress.Height
    $rad = [int]($h / 2)
    $track = New-Object Drawing.Rectangle(0, 0, $w, $h)
    $pathT = [ClodUi.Shape]::Round($track, $rad)
    $brT = New-Object Drawing.SolidBrush($script:borderClr)
    $g.FillPath($brT, $pathT)
    $brT.Dispose(); $pathT.Dispose()
    $segW = [int]($w * 0.28)
    if ($segW -lt 8) { $segW = 8 }
    $t = $script:ProgTick / 40.0
    $x = [int]((($w + $segW) * $t) - $segW)
    $seg = New-Object Drawing.Rectangle($x, 0, $segW, $h)
    $pathS = [ClodUi.Shape]::Round($seg, $rad)
    $brS = New-Object Drawing.SolidBrush($script:accentClr)
    $g.FillPath($brS, $pathS)
    $brS.Dispose(); $pathS.Dispose()
})

# ---------- log viewer window: the algorithm must be observable ----------
# Every probe/apply step goes to clodkey.log via Write-Log; this window
# tails it live so the user can SEE what the app is doing and why.
function Get-LogTail([int]$Lines) {
    try {
        if (-not (Test-Path -LiteralPath $LogPath)) { return '(log file not created yet)' }
        $fs = New-Object IO.FileStream($LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $all = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        $arr = @($all -split "`r?`n")
        if ($arr.Count -gt $Lines) { $arr = $arr[($arr.Count - $Lines)..($arr.Count - 1)] }
        return ($arr -join "`r`n")
    } catch {
        return ('log read failed: ' + $_.Exception.Message)
    }
}

$script:LogForm = $null
$script:LogBox = $null
$script:LogTimer = $null

function Update-LogView {
    if (-not $script:LogBox) { return }
    $txt = Get-LogTail 600
    if ($txt -ne $script:LogBox.Text) {
        $script:LogBox.Text = $txt
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
}

function Show-Logs {
    if ($script:LogForm -and -not $script:LogForm.IsDisposed) {
        $script:LogForm.Show()
        $script:LogForm.BringToFront()
        $script:LogForm.Activate()
        Update-LogView
        return
    }
    $lf = New-Object ClodUi.ClodForm
    $lf.Text = (T 'logs_title')
    $lf.ClientSize = New-Object Drawing.Size(470, 540)
    $lf.StartPosition = 'Manual'
    $lf.Surface = $script:surface
    $lf.Border = $script:borderClr
    $lf.BackColor = $script:surface
    $lf.ForeColor = $script:ink
    $lf.Font = $fontUi
    $lf.Icon = $script:AppIcon
    $lf.ShowInTaskbar = $true
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $lf.Location = New-Object Drawing.Point(($wa.Left + [int](($wa.Width - $lf.Width) / 2)), ($wa.Top + 40))

    $lt = New-Object Windows.Forms.Label
    $lt.Text = (T 'logs_title')
    $lt.Font = $fontTitle
    $lt.ForeColor = $script:ink
    $lt.BackColor = [Drawing.Color]::Transparent
    $lt.AutoSize = $true
    $lt.Location = New-Object Drawing.Point(14, 10)
    $lf.Controls.Add($lt)

    # local factory: ClodButton on THIS form (New-MicroButton targets main)
    $mkLogBtn = {
        param($text, $x, $y, $w, $h)
        $b = New-Object ClodUi.ClodButton
        $b.Text = $text
        $b.Location = New-Object Drawing.Point($x, $y)
        $b.Size = New-Object Drawing.Size($w, $h)
        $b.Pad = 5
        $b.Radius = [int](($h - 10) / 2)
        $b.Surface = $script:surface
        $b.Ink = $script:ink
        $b.ShadowDark = $script:shadowDark
        $b.LightShadow = $script:shadowLight
        $b.AccentColor = $script:accentClr
        $b.AccentText = $script:accentText
        $b.ForeColor = $script:ink
        $b.Font = $fontMicro
        $lf.Controls.Add($b)
        return $b
    }
    $bw = 92
    $btnLfRefresh = & $mkLogBtn (T 'btn_logs_refresh') ($lf.ClientSize.Width - 14 - 3 * ($bw + 6)) 10 $bw 26
    $btnLfOpen    = & $mkLogBtn (T 'btn_logs_open')    ($lf.ClientSize.Width - 14 - 2 * ($bw + 6)) 10 $bw 26
    $btnLfClose   = & $mkLogBtn (T 'btn_close')        ($lf.ClientSize.Width - 14 - 34) 10 34 26

    $wp = New-Object ClodUi.ClodPanel
    $wp.Surface = $script:surface
    $wp.ShadowDark = $script:shadowDark
    $wp.LightShadow = $script:shadowLight
    $wp.Radius = 14
    $wp.Location = New-Object Drawing.Point(8, 44)
    $wp.Size = New-Object Drawing.Size(($lf.ClientSize.Width - 16), ($lf.ClientSize.Height - 52))
    $lf.Controls.Add($wp)

    $tb = New-Object Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Vertical'
    $tb.BorderStyle = 'None'
    $tb.BackColor = $script:surface
    $tb.ForeColor = $script:ink
    $tb.Font = $fontMono
    $tb.Location = New-Object Drawing.Point(10, 8)
    $tb.Size = New-Object Drawing.Size(($wp.Width - 26), ($wp.Height - 16))
    $tb.Anchor = 'Top,Left,Right,Bottom'
    $wp.Controls.Add($tb)
    $script:LogBox = $tb

    $dragLog = {
        param($s, $e)
        if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) {
            [void][ClodNative]::ReleaseCapture()
            [void][ClodNative]::SendMessage($script:LogForm.Handle, 0xA1, [IntPtr]2, [IntPtr]0)
        }
    }
    $lt.Add_MouseDown($dragLog)
    $btnLfRefresh.Add_Click({ Update-LogView })
    $btnLfOpen.Add_Click({ Start-Process explorer.exe -ArgumentList ('/select,"' + $LogPath + '"') })
    $btnLfClose.Add_Click({ $lf.Hide() })
    # X and Alt+F4 hide the window, never kill the app
    $lf.Add_FormClosing({
        param($s, $e)
        $e.Cancel = $true
        $lf.Hide()
    })

    if (-not $script:LogTimer) {
        $script:LogTimer = New-Object Windows.Forms.Timer
        $script:LogTimer.Interval = 2000
        $script:LogTimer.Add_Tick({
            if ($script:LogForm -and $script:LogForm.Visible) { Update-LogView }
        })
        $script:LogTimer.Start()
    }
    $script:LogForm = $lf
    $lf.Show()
    Update-LogView
    Write-Log 'info' 'log viewer opened'
}

# owner-draw rows: name + status badge; non-ok rows grayed
$cmbModel.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $g = $e.Graphics
    $item = $cmbModel.Items[$e.Index]
    $st = [string]$item.state
    # DrawItemState.Selected is set for the EDIT row too (ComboBoxEdit) and
    # for hover; the old code turned those rows white-on-white. Only a real
    # list selection (hot) gets the accent pill + white text.
    $sel = (($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0) -and `
           (($e.State -band [Windows.Forms.DrawItemState]::ComboBoxEdit) -eq 0)
    # neumorphic popup rows: explicit surface fill (Clear can miss the
    # native white popup backing), selected row = inset accent pill
    $brBg = New-Object Drawing.SolidBrush($script:surface)
    $g.FillRectangle($brBg, $e.Bounds)
    $brBg.Dispose()
    if ($sel) {
        $pr = New-Object Drawing.Rectangle(3, ($e.Bounds.Y + 1), ($e.Bounds.Width - 7), ($e.Bounds.Height - 3))
        [ClodUi.Shape]::Inset($g, $pr, 9, $script:accentClr, $script:shadowDark, $script:shadowLight, 3)
    }
    $badge = Get-ModelBadge $st
    $bw = [Windows.Forms.TextRenderer]::MeasureText($badge, $fontMicro).Width + 12
    $fmt = New-Object Drawing.StringFormat
    $fmt.Trimming = [Drawing.StringTrimming]::EllipsisCharacter
    $fmt.LineAlignment = [Drawing.StringAlignment]::Center
    # readability first: names are ALWAYS ink. The old muted-on-surface
    # for pending/quota/err rows read as white-on-white (reported); the
    # state is carried by the badge color alone.
    $nameClr = $ink
    if ($sel) { $nameClr = [Drawing.Color]::White }
    $rect = New-Object Drawing.RectangleF(($e.Bounds.X + 8), $e.Bounds.Y, ($e.Bounds.Width - 16 - $bw), $e.Bounds.Height)
    $tb = New-Object Drawing.SolidBrush($nameClr)
    $g.DrawString([string]$item.id, $fontUi, $tb, $rect, $fmt)
    $tb.Dispose()
    $badgeClr = [Drawing.Color]::FromArgb(147, 165, 190)                        # pending: gray
    if ($st -eq 'ok') { $badgeClr = [Drawing.Color]::FromArgb(46, 160, 67) }   # ok: green
    if ($st -eq 'quota') { $badgeClr = [Drawing.Color]::FromArgb(210, 153, 34) } # quota: amber
    if ($st -eq 'err') { $badgeClr = [Drawing.Color]::FromArgb(218, 54, 54) }  # err: red
    if ($sel) { $badgeClr = [Drawing.Color]::White }
    $bb = New-Object Drawing.SolidBrush($badgeClr)
    $g.DrawString($badge, $fontMicro, $bb, ($e.Bounds.Right - 8 - $bw + 4), ($e.Bounds.Y + [int](($e.Bounds.Height - 12) / 2)))
    $bb.Dispose()
})

# quota/err models are NOT selectable: revert to the last good one
$cmbModel.Add_SelectedIndexChanged({
    if ($script:ModelReverting) { return }
    $idx = $cmbModel.SelectedIndex
    if ($idx -lt 0) { return }
    $item = $cmbModel.Items[$idx]
    if ([string]$item.state -ne 'ok') {
        Set-Status (T 'model_locked')
        $script:ModelReverting = $true
        $cmbModel.SelectedIndex = $script:LastGoodModelIdx
        $script:ModelReverting = $false
    } else {
        $script:LastGoodModelIdx = $idx
    }
})

function Select-ModelOrAdd([string]$Id) {
    $script:ModelReverting = $true
    try {
        if (-not $Id) { $cmbModel.SelectedIndex = -1; $script:LastGoodModelIdx = -1; return }
        for ($i = 0; $i -lt $cmbModel.Items.Count; $i++) {
            if ($cmbModel.Items[$i].id -eq $Id) {
                $cmbModel.SelectedIndex = $i
                if ($cmbModel.Items[$i].state -eq 'ok') { $script:LastGoodModelIdx = $i }
                return
            }
        }
        $obj = [pscustomobject]@{ id = $Id; state = 'ok' }
        $i = $cmbModel.Items.Add($obj)
        $cmbModel.SelectedIndex = $i
        $script:LastGoodModelIdx = $i
    } finally {
        $script:ModelReverting = $false
    }
}

# ---------- auth mode: segmented micro-control ----------
$lblMode = New-MicroLabel (T 'lbl_mode') 14 322
$segApi   = New-MicroButton (T 'seg_api')   10 340 90 26 $false
$segToken = New-MicroButton (T 'seg_token') 104 340 90 26 $false
$segBoth  = New-MicroButton (T 'seg_both')  198 340 90 26 $false
$script:Mode = 'both'
function Set-Mode([string]$M) {
    # any mode change (manual click or profile load) kills the detection
    # glow; the probe re-arms it right after via Start-Glow
    Stop-Glow
    $script:Mode = $M
    $segApi.Selected   = ($M -eq 'api_key')
    $segToken.Selected = ($M -eq 'auth_token')
    $segBoth.Selected  = ($M -eq 'both')
    $segApi.Invalidate(); $segToken.Invalidate(); $segBoth.Invalidate()
}
$segApi.Add_Click({ Set-Mode 'api_key' })
$segToken.Add_Click({ Set-Mode 'auth_token' })
$segBoth.Add_Click({ Set-Mode 'both' })
Set-Mode 'both'

# ---------- action rows ----------
$btnNew    = New-MicroButton (T 'btn_new')    10 372 56 26 $false
$btnSave   = New-MicroButton (T 'btn_save')   70 372 72 26 $false
$btnDelete = New-MicroButton (T 'btn_delete') 146 372 56 26 $false
$btnCopy   = New-MicroButton (T 'btn_copy')   206 372 82 26 $false
Tip $btnNew 'tip_new'; Tip $btnSave 'tip_save'; Tip $btnDelete 'tip_delete'; Tip $btnCopy 'tip_copy'

$btnApply  = New-MicroButton (T 'btn_apply')  10 404 280 30 $true
$btnApply.Font = $fontUiB
Tip $btnApply 'tip_apply'

# ---------- status ----------
$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Location = New-Object Drawing.Point(14, 440)
$lblStatus.Size = New-Object Drawing.Size(272, 40)
$lblStatus.ForeColor = $script:muted
$lblStatus.BackColor = [Drawing.Color]::Transparent
$lblStatus.Font = $fontMicro
$lblStatus.Text = T 'status_ready'
$form.Controls.Add($lblStatus)

function Set-Status([string]$Msg) {
    $lblStatus.Text = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Msg
    Write-Log 'info' $Msg
}

# ---------- dynamic layout: every position from measured text ----------
# Fixed pixel coordinates broke at DPI != 100% (WinForms scales fonts we
# set at runtime, so labels grew into the next row). Do-Layout measures
# real text heights/widths and stacks the flow; re-run on language change.
function Measure-W([string]$Text, [Drawing.Font]$F) {
    return [Windows.Forms.TextRenderer]::MeasureText($Text, $F).Width
}
function Place-Field($panel, $tb, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $panel.Location = New-Object Drawing.Point($X, $Y)
    $panel.Size = New-Object Drawing.Size($W, $H)
    $tb.Location = New-Object Drawing.Point(10, [int](($H - $tb.PreferredHeight) / 2))
    $tb.Width = $W - 20
}
function Do-Layout {
    $W = $form.ClientSize.Width
    if ($W -lt 100) { $W = 300 }
    $pad = 12
    $fw = $W - 2 * $pad
    $y = 8
    # header row 1: title left, icon row right (centered on the title).
    # row 2: sub label BELOW the whole icon row - the sub text is long
    # and used to run under the glyphs (reported overlap).
    $lblTitle.Location = New-Object Drawing.Point($pad, $y)
    $titleH = $lblTitle.PreferredHeight
    # 8 icons must still clear the title: measured title right edge is 89,
    # the row needs Left >= 93, so the icon box is 22 px (start = 98)
    $ibSize = 22; $ibGap = 2
    $icons = @($btnLangRu, $btnLangEn, $btnLangZh, $btnLangEs, $btnLogs, $btnTheme, $btnTea, $btnClose)
    $total = $icons.Count * $ibSize + ($icons.Count - 1) * $ibGap
    $ix = $W - $pad - $total
    $iy = $y + [int](($titleH - $ibSize) / 2)
    if ($iy -lt $y) { $iy = $y }
    foreach ($ib in $icons) {
        $ib.Size = New-Object Drawing.Size($ibSize, $ibSize)
        $ib.Radius = [int](($ibSize - 8) / 2)
        $ib.Location = New-Object Drawing.Point($ix, $iy)
        $ix += $ibSize + $ibGap
    }
    $rowBottom = [Math]::Max($y + $titleH, $iy + $ibSize)
    $subY = $rowBottom + 2
    $lblDot.Location = New-Object Drawing.Point(($pad + 1), $subY)
    $subH = $lblDot.PreferredHeight
    $headBottom = $subY + $subH
    $y = $headBottom + 10
    # profiles row: label left, import button right
    $lblProfiles.Location = New-Object Drawing.Point($pad, $y)
    $microH = $lblProfiles.PreferredHeight
    $impW = (Measure-W $btnImport.Text $fontMicro) + 26
    $btnImport.Size = New-Object Drawing.Size($impW, 24)
    $btnImport.Radius = 12
    $btnImport.Location = New-Object Drawing.Point(($W - $pad - $impW), ($y - 2))
    $y += $microH + 6
    # list well (inset) + listview inside
    $lvWell.Location = New-Object Drawing.Point(($pad - 6), $y)
    $lvWell.Size = New-Object Drawing.Size(($W - 2 * ($pad - 6)), 108)
    $lv.Location = New-Object Drawing.Point($pad, ($y + 4))
    $lv.Size = New-Object Drawing.Size($fw, 100)
    $colW = $fw - 8
    $c0 = [int]($colW * 0.32); $c1 = [int]($colW * 0.46)
    $lv.Columns[0].Width = $c0
    $lv.Columns[1].Width = $c1
    $lv.Columns[2].Width = $colW - $c0 - $c1
    $y += 108 + 12
    # fields: label + carved input, measured label height keeps gaps honest
    $fieldH = 30
    $lblName.Location = New-Object Drawing.Point($pad, $y)
    $y += $microH + 3
    Place-Field $pnlName $txtName $pad $y $fw $fieldH
    $y += $fieldH + 8
    $lblBase.Location = New-Object Drawing.Point($pad, $y)
    $y += $microH + 3
    Place-Field $pnlBase $txtBase $pad $y $fw $fieldH
    $y += $fieldH + 8
    $lblKey.Location = New-Object Drawing.Point($pad, $y)
    $y += $microH + 3
    $eyeW = 28; $eyeGap = 8
    Place-Field $pnlKey $txtKey $pad $y ($fw - $eyeW - $eyeGap) $fieldH
    $btnEye.Size = New-Object Drawing.Size($eyeW, $fieldH)
    $btnEye.Radius = [int](($fieldH - 10) / 2)
    $btnEye.Location = New-Object Drawing.Point(($pad + $fw - $eyeW), $y)
    $y += $fieldH + 8
    # model dropdown: label row with the refresh button at its far right
    # (user: place it to the right of the model block), full-width combo,
    # progress strip below (visible only while a probe runs)
    $refH = 22
    $lblModel.Location = New-Object Drawing.Point($pad, ($y + [int](($refH - $microH) / 2)))
    $btnRefresh.Size = New-Object Drawing.Size($refH, $refH)
    $btnRefresh.Radius = [int](($refH - 6) / 2)
    $btnRefresh.Location = New-Object Drawing.Point(($W - $pad - $refH), $y)
    $y += [Math]::Max($microH, $refH) + 3
    $cmbModel.Location = New-Object Drawing.Point($pad, $y)
    $cmbModel.Size = New-Object Drawing.Size($fw, 26)
    $y += 26 + 5
    $pnlProgress.Location = New-Object Drawing.Point($pad, $y)
    $pnlProgress.Size = New-Object Drawing.Size($fw, 6)
    $y += 6 + 6
    # auth mode: three equal segments
    $lblMode.Location = New-Object Drawing.Point($pad, $y)
    $y += $microH + 3
    $segH = 26; $segGap = 4
    $segW = [int](($fw - 2 * $segGap) / 3)
    $segs = @($segApi, $segToken, $segBoth)
    $sx = $pad
    foreach ($sg in $segs) {
        $sg.Size = New-Object Drawing.Size($segW, $segH)
        $sg.Radius = [int](($segH - 10) / 2)
        $sg.Location = New-Object Drawing.Point($sx, $y)
        $sx += $segW + $segGap
    }
    $y += $segH + 10
    # action row: widths from measured text, shrink-to-fit if needed
    $actH = 26; $actGap = 4
    $btns = @($btnNew, $btnSave, $btnDelete, $btnCopy)
    $widths = @()
    foreach ($b in $btns) { $widths += ((Measure-W $b.Text $fontMicro) + 26) }
    $need = ($widths | Measure-Object -Sum).Sum + $actGap * ($btns.Count - 1)
    $scale = 1.0
    if ($need -gt $fw) { $scale = [double]$fw / $need }
    $ax = $pad
    for ($i = 0; $i -lt $btns.Count; $i++) {
        $bw = [int]($widths[$i] * $scale)
        $btns[$i].Size = New-Object Drawing.Size($bw, $actH)
        $btns[$i].Radius = [int](($actH - 10) / 2)
        $btns[$i].Location = New-Object Drawing.Point($ax, $y)
        $ax += $bw + $actGap
    }
    $y += $actH + 8
    # apply: full width accent
    $btnApply.Size = New-Object Drawing.Size($fw, 32)
    $btnApply.Radius = 16
    $btnApply.Location = New-Object Drawing.Point($pad, $y)
    $y += 32 + 10
    # status: two measured lines
    $lineH = [Windows.Forms.TextRenderer]::MeasureText('Ag', $fontMicro).Height
    $statusH = 2 * $lineH + 6
    $lblStatus.Location = New-Object Drawing.Point($pad, $y)
    $lblStatus.Size = New-Object Drawing.Size($fw, $statusH)
    $y += $statusH + $pad
    $form.ClientSize = New-Object Drawing.Size(300, $y)
}

# ---------- state ----------
$script:CurrentId = $null
$script:Masked = $true
$script:Exiting = $false

# ---------- tray ----------
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = $script:AppIcon
$tray.Visible = $true
$tray.Text = 'ClodKey'

$menu = New-Object Windows.Forms.ContextMenuStrip
function Build-TrayMenu {
    $menu.Items.Clear()
    $miOpen = $menu.Items.Add((T 'tray_open'))
    $miOpen.Add_Click({ Show-Main })
    $miFolder = $menu.Items.Add((T 'tray_folder'))
    $miFolder.Add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $Base + '"') })
    $miLogs = $menu.Items.Add((T 'tray_logs'))
    $miLogs.Add_Click({ Show-Logs })
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $miExit = $menu.Items.Add((T 'tray_exit'))
    $miExit.Add_Click({ Exit-App })
}
Build-TrayMenu
$tray.ContextMenuStrip = $menu

function Update-TrayTooltip {
    $profiles = @($script:Store.profiles)
    $appliedName = T 'none'
    if ($script:Store.lastAppliedId) {
        foreach ($p in $profiles) {
            if ([string]$p.id -eq [string]$script:Store.lastAppliedId) { $appliedName = [string]$p.name; break }
        }
    }
    $tip = (T 'tooltip_fmt') -f $profiles.Count, $appliedName
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }   # WinForms tooltip hard limit
    $tray.Text = $tip
}

# ---------- theme re-application ----------
function Apply-Theme {
    Set-Palette $script:Theme
    $form.Surface = $script:surface
    $form.Border = $script:borderClr
    $form.BackColor = $script:surface
    $form.ForeColor = $script:ink
    $form.Invalidate()
    foreach ($p in $script:Panels) {
        $p.Surface = $script:surface; $p.ShadowDark = $script:shadowDark; $p.LightShadow = $script:shadowLight
        $p.BackColor = $script:surface
        $p.Invalidate()
    }
    foreach ($b in $script:Buttons) {
        $b.Surface = $script:surface; $b.Ink = $script:ink
        $b.ShadowDark = $script:shadowDark; $b.LightShadow = $script:shadowLight
        $b.AccentColor = $script:accentClr; $b.AccentText = $script:accentText
        $b.ForeColor = $script:ink
        $b.BackColor = $script:surface
        $b.Invalidate()
    }
    $lblTitle.ForeColor = $script:ink
    $lblDot.ForeColor = $script:muted
    $lblStatus.ForeColor = $script:muted
    foreach ($l in $script:Labels) { $l.ForeColor = $script:muted }
    $lv.BackColor = $script:surface
    $lv.ForeColor = $script:ink
    $lv.Invalidate()
    $cmbModel.BackColor = $script:surface
    $cmbModel.ForeColor = $script:ink
    $cmbModel.Invalidate()
    $pnlProgress.Invalidate()
    # the log viewer follows the palette too (if it is open)
    if ($script:LogForm -and -not $script:LogForm.IsDisposed) {
        $script:LogForm.Surface = $script:surface
        $script:LogForm.Border = $script:borderClr
        $script:LogForm.BackColor = $script:surface
        $script:LogForm.ForeColor = $script:ink
        $script:LogForm.Invalidate($true)
    }
    foreach ($tb in $script:Fields) {
        $tb.BackColor = $script:surface
        $tb.ForeColor = $script:ink
    }
    # tray icon follows the palette
    $newIcon = New-ClodKeyIcon
    $oldIcon = $tray.Icon
    $tray.Icon = $newIcon
    $form.Icon = $newIcon
    if ($oldIcon) { try { $oldIcon.Dispose() } catch { } }
    $script:Tips.BackColor = $script:ink
    $script:Tips.ForeColor = [Drawing.Color]::White
    $form.Refresh()
}

# ---------- language re-application ----------
function Apply-Language {
    $form.Text = T 'app_title'
    $lblTitle.Text = T 'app_title'
    $lblDot.Text = T 'app_sub'
    $lblProfiles.Text = T 'lbl_profiles'
    $lblName.Text = T 'lbl_name'
    $lblBase.Text = T 'lbl_base'
    $lblKey.Text = T 'lbl_key'
    $lblModel.Text = T 'lbl_model'
    $lblMode.Text = T 'lbl_mode'
    $btnImport.Text = T 'btn_import'
    $lv.Columns[0].Text = T 'col_name'
    $lv.Columns[1].Text = T 'col_base'
    $lv.Columns[2].Text = T 'col_updated'
    $segApi.Text = T 'seg_api'
    $segToken.Text = T 'seg_token'
    $segBoth.Text = T 'seg_both'
    $btnNew.Text = T 'btn_new'
    $btnSave.Text = T 'btn_save'
    $btnDelete.Text = T 'btn_delete'
    $btnCopy.Text = T 'btn_copy'
    $btnApply.Text = T 'btn_apply'
    $btnClose.Text = T 'btn_close'
    if ($script:Masked) { $btnEye.Text = T 'eye_open' } else { $btnEye.Text = T 'eye_close' }
    Update-ThemeButton
    Update-LanguageButtons
    # tooltips
    Tip $btnLangRu 'tip_lang'; Tip $btnLangEn 'tip_lang'; Tip $btnLangZh 'tip_lang'; Tip $btnLangEs 'tip_lang'
    Tip $btnTheme 'tip_theme'; Tip $btnTea 'tip_tea'; Tip $btnClose 'tip_close'
    Tip $btnLogs 'tip_logs'
    Tip $btnImport 'tip_import'; Tip $btnEye 'tip_eye'
    Tip $cmbModel 'tip_model'
    Tip $btnRefresh 'tip_refresh'
    Tip $btnNew 'tip_new'; Tip $btnSave 'tip_save'; Tip $btnDelete 'tip_delete'; Tip $btnCopy 'tip_copy'
    Tip $btnApply 'tip_apply'
    # tray menu + tooltip
    Build-TrayMenu
    Update-TrayTooltip
    # rename the system profile to the new locale (stable id, name is
    # cosmetic). Test-SystemProfile also catches legacy unflagged profiles.
    $profiles = @($script:Store.profiles)
    $changed = $false
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        if (Test-SystemProfile $profiles[$i]) {
            if ([string]$profiles[$i].name -ne (T 'sys_name')) {
                $profiles[$i].name = T 'sys_name'
                $changed = $true
            }
            break
        }
    }
    if ($changed) { Set-Prop $script:Store 'profiles' $profiles; Save-Store }
    Refresh-List
    # reload the selected profile into the fields: its name may have been
    # localized (system profile), otherwise the input keeps the old language
    if ($script:CurrentId) {
        foreach ($p in @($script:Store.profiles)) {
            if ([string]$p.id -eq [string]$script:CurrentId) { Load-IntoFields $p; break }
        }
    }
    Set-Status (T 'status_ready')
    # texts changed -> measured widths changed -> re-stack the flow
    Do-Layout
}

# ---------- flyout: anchor to the tray corner, slide-up + fade ----------
function Position-Flyout {
    $wa = [Windows.Forms.Screen]::GetWorkingArea($form)
    $x = $wa.Right - $form.Width - 12
    $y = $wa.Bottom - $form.Height - 12
    if ($x -lt $wa.Left) { $x = $wa.Left + 12 }
    if ($y -lt $wa.Top) { $y = $wa.Top + 12 }
    return New-Object Drawing.Point($x, $y)
}

$script:AnimFinalY = 0
$script:AnimStep = 0
$script:AnimSteps = 16
$script:AnimTimer = New-Object Windows.Forms.Timer
$script:AnimTimer.Interval = 16
$script:AnimTimer.Add_Tick({
    $script:AnimStep++
    $p = $script:AnimStep / $script:AnimSteps
    if ($p -ge 1.0) { $p = 1.0 }
    $e = 1.0 - [Math]::Pow(1.0 - $p, 3)          # ease-out cubic
    $y = ($script:AnimFinalY + 46) - (46 * $e)
    $form.Location = New-Object Drawing.Point($form.Location.X, [int]$y)
    $form.Opacity = [Math]::Min(1.0, 0.25 + 0.75 * $e)
    if ($p -ge 1.0) { $script:AnimTimer.Stop() }
})

function Show-Main {
    $pt = Position-Flyout
    $script:AnimFinalY = $pt.Y
    $form.Location = New-Object Drawing.Point($pt.X, ($pt.Y + 46))
    $form.Opacity = 0.25
    $form.Show()
    $form.Activate()
    $script:AnimStep = 0
    $script:AnimTimer.Start()
}
function Hide-Main { $form.Hide() }
function Toggle-Main {
    if ($form.Visible) { Hide-Main } else { Show-Main }
}

function Exit-App {
    $script:Exiting = $true
    $tray.Visible = $false
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
}

# ---------- list <-> fields ----------
function Refresh-List {
    $lv.Items.Clear()
    foreach ($p in @($script:Store.profiles)) {
        $item = New-Object Windows.Forms.ListViewItem([string]$p.name)
        [void]$item.SubItems.Add([string]$p.baseUrl)
        $shown = ''
        try {
            $dt = [DateTime]::Parse([string]$p.updatedAt, [Globalization.CultureInfo]::InvariantCulture)
            $shown = $dt.ToLocalTime().ToString('dd.MM HH:mm')
        } catch { $shown = '?' }
        [void]$item.SubItems.Add($shown)
        $item.Tag = $p
        [void]$lv.Items.Add($item)
    }
    Update-TrayTooltip
}

function Load-IntoFields($Prof) {
    $script:CurrentId = [string]$Prof.id
    $txtName.Text = [string]$Prof.name
    $txtBase.Text = [string]$Prof.baseUrl
    try {
        $txtKey.Text = Unprotect-String ([string]$Prof.apiKey)
    } catch {
        $txtKey.Text = ''
        Set-Status (T 'dpapi_fail')
    }
    Set-Mode ([string]$Prof.authMode)
    $m = ''
    if ($Prof.PSObject.Properties.Name -contains 'model') { $m = [string]$Prof.model }
    Select-ModelOrAdd $m
}

$lv.Add_SelectedIndexChanged({
    if ($lv.SelectedItems.Count -gt 0) { Load-IntoFields $lv.SelectedItems[0].Tag }
})

# select the system profile in the list and load it into the fields;
# the import button must fill the form even when nothing changed (bug:
# after "New" cleared the fields, import left them empty)
function Select-SystemInList {
    foreach ($item in $lv.Items) {
        if (Test-SystemProfile $item.Tag) {
            $lv.SelectedIndices.Clear()
            $item.Selected = $true
            $item.EnsureVisible()
            Load-IntoFields $item.Tag
            return $true
        }
    }
    return $false
}

# ---------- buttons ----------
# Save the VISIBLE form into the store and return the profile (or $null
# with a validation status). Shared by Save and Apply so both act on the
# same data the user sees.
function Save-FromFields {
    $name = $txtName.Text.Trim()
    $base = $txtBase.Text.Trim().TrimEnd('/')
    $key  = $txtKey.Text
    if (-not $name) { Set-Status (T 'err_name'); return $null }
    if (-not $base -or -not ($base -match '^https?://')) { Set-Status (T 'err_base'); return $null }
    if (-not $key)  { Set-Status (T 'err_key'); return $null }
    $prof = [pscustomobject]@{
        id        = $(if ($script:CurrentId) { $script:CurrentId } else { [guid]::NewGuid().ToString() })
        name      = $name
        baseUrl   = $base
        apiKey    = (Protect-String $key)
        authMode  = $script:Mode
        model     = $(if ($cmbModel.SelectedItem) { [string]$cmbModel.SelectedItem.id } else { '' })
        updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    # editing the imported system profile must not lose its flag
    foreach ($p in @($script:Store.profiles)) {
        if ([string]$p.id -eq [string]$prof.id -and (Test-SystemProfile $p)) {
            $prof = [pscustomobject]@{
                id = $prof.id; name = $prof.name; baseUrl = $prof.baseUrl
                apiKey = $prof.apiKey; authMode = $prof.authMode
                model = $prof.model; updatedAt = $prof.updatedAt; system = $true
            }
            break
        }
    }
    $profiles = @($script:Store.profiles)
    $found = $false
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        if ([string]$profiles[$i].id -eq [string]$prof.id) { $profiles[$i] = $prof; $found = $true; break }
    }
    if (-not $found) { $profiles += $prof }
    Set-Prop $script:Store 'profiles' $profiles
    Save-Store
    $script:CurrentId = [string]$prof.id
    Refresh-List
    foreach ($item in $lv.Items) {
        if ([string]$item.Tag.id -eq [string]$prof.id) { $item.Selected = $true; $item.EnsureVisible(); break }
    }
    Write-Log 'info' ('saved: name=' + $name + ' model=' + $(if ($prof.model) { $prof.model } else { '(none)' }) + ' mode=' + [string]$prof.authMode)
    return $prof
}

$btnNew.Add_Click({
    $script:CurrentId = $null
    $lv.SelectedIndices.Clear()
    $txtName.Text = ''; $txtBase.Text = ''; $txtKey.Text = ''
    Set-Mode 'both'
    $script:ModelReverting = $true
    $cmbModel.Items.Clear()
    $cmbModel.SelectedIndex = -1
    $script:LastGoodModelIdx = -1
    $script:ModelReverting = $false
    [void]$txtName.Focus()
})

$btnSave.Add_Click({
    try {
        $prof = Save-FromFields
        if ($prof) { Set-Status (T 'saved') }
    } catch {
        Set-Status ('save failed: ' + $_.Exception.Message)
        Write-Log 'error' ('save: ' + $_.Exception.Message)
    }
})

$btnDelete.Add_Click({
    if (-not $script:CurrentId) { return }
    $res = [Windows.Forms.MessageBox]::Show(
        (T 'confirm_delete') + ': ' + $txtName.Text + '?',
        (T 'app_title'),
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Question)
    if ($res -ne [Windows.Forms.DialogResult]::Yes) { return }
    $profiles = @($script:Store.profiles | Where-Object { [string]$_.id -ne [string]$script:CurrentId })
    Set-Prop $script:Store 'profiles' $profiles
    try {
        Save-Store
        $btnNew.PerformClick()
        Refresh-List
        Set-Status (T 'deleted')
    } catch { Set-Status ('delete failed: ' + $_.Exception.Message) }
})

$btnCopy.Add_Click({
    if ($txtKey.Text) {
        try { [Windows.Forms.Clipboard]::SetText($txtKey.Text); Set-Status (T 'copied') }
        catch { Set-Status ('clipboard failed: ' + $_.Exception.Message) }
    }
})

$btnImport.Add_Click({
    $found = Import-System $false
    Refresh-List
    if ($found) { [void](Select-SystemInList) }
})

$btnEye.Add_Click({
    $script:Masked = -not $script:Masked
    $txtKey.UseSystemPasswordChar = $script:Masked
    if ($script:Masked) { $btnEye.Text = T 'eye_open' } else { $btnEye.Text = T 'eye_close' }
})

$btnApply.Add_Click({
    # APPLY WHAT IS ON SCREEN (reported bug: the old handler applied the
    # STORED profile, so a freshly picked model/mode was silently ignored
    # unless Save was pressed first). Save the visible fields, then write.
    try {
        $prof = Save-FromFields
        if (-not $prof) { return }
        Write-Log 'info' ('apply: name=' + [string]$prof.name + ' model=' + $(if ($prof.model) { [string]$prof.model } else { '(none)' }) + ' mode=' + [string]$prof.authMode + ' base=' + [string]$prof.baseUrl)
        $path = Apply-ToClaudeCli $prof
        Refresh-List
        Set-Status ((T 'applied') + ' ' + [string]$prof.name)
    } catch {
        Set-Status ((T 'apply_fail') + ' ' + $_.Exception.Message)
        Write-Log 'error' ('apply: ' + $_.Exception.Message)
    }
})

$btnClose.Add_Click({ Hide-Main })

# ---------- tray events ----------
$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Toggle-Main }
})
$tray.Add_MouseDoubleClick({ Show-Main })

# close (X) and minimize = hide to tray, never exit
$form.Add_Resize({
    if ($form.WindowState -eq 'Minimized') { $form.Hide() }
})
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:Exiting) {
        $e.Cancel = $true
        $form.Hide()
        Set-Status (T 'hidden_hint')
    }
})

# ---------- boot ----------
[void](Import-System $true)
Update-LanguageButtons
Update-ThemeButton
Refresh-List
# real data on screen: auto-select the first profile so fields are filled.
# Do NOT focus the ListView: the native control draws a solid accent-blue
# focus rectangle over owner-drawn rows (observed in pixel scans). The
# selection pill is drawn by us and stays visible without focus.
if ($lv.Items.Count -gt 0) {
    $lv.Items[0].Selected = $true
}
Set-Status (T 'status_ready')
Do-Layout
# startup probe: same automatic check as on paste. The TextChanged debounce
# may already have armed a probe; the fingerprint guard prevents a double
# launch of the identical base+key.
if ($txtKey.Text.Length -ge 12 -and $txtBase.Text -match '^https?://') { Start-ModelProbe }

if ($SelfTest) {
    # every tray action has a CLI twin (GOLD: clicks are untestable, commands are)
    $tmpProfile = Join-Path ([IO.Path]::GetTempPath()) ('clodkey-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpProfile -Force | Out-Null
    $savedUp = $env:USERPROFILE
    $savedSecrets = $SecretsPath
    try {
        $env:USERPROFILE = $tmpProfile
        # do not pollute the real store: point secrets.json into the sandbox
        $script:SecretsPath = Join-Path $tmpProfile 'secrets.json'
        $prof = [pscustomobject]@{
            id = [guid]::NewGuid().ToString(); name = 'selftest'
            baseUrl = 'https://test.example.com/'; apiKey = (Protect-String 'sk-test-123')
            authMode = 'both'; updatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        $profiles = @($script:Store.profiles) + $prof
        Set-Prop $script:Store 'profiles' $profiles
        Save-Store
        $path = Apply-ToClaudeCli $prof
        $doc = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($doc.env.ANTHROPIC_BASE_URL -ne 'https://test.example.com') { throw 'baseUrl mismatch' }
        if ($doc.env.ANTHROPIC_API_KEY -ne 'sk-test-123') { throw 'apiKey mismatch' }
        if ($doc.env.ANTHROPIC_AUTH_TOKEN -ne 'sk-test-123') { throw 'authToken mismatch' }
        # reload from disk and verify DPAPI ciphertext roundtrip
        Load-Store
        $reloaded = @($script:Store.profiles | Where-Object { $_.id -eq $prof.id })[0]
        if ((Unprotect-String $reloaded.apiKey) -ne 'sk-test-123') { throw 'DPAPI reload mismatch' }
        # system import with injected env (deterministic): must appear as profile
        [void](Import-System $true @{ ANTHROPIC_API_KEY = 'sk-test-123'; ANTHROPIC_AUTH_TOKEN = 'sk-test-123'; ANTHROPIC_BASE_URL = 'https://test.example.com' })
        $sys = @($script:Store.profiles | Where-Object { Test-SystemProfile $_ })
        if ($sys.Count -lt 1) { throw 'system import missing' }
        if ((Unprotect-String ([string]$sys[0].apiKey)) -ne 'sk-test-123') { throw 'system import key mismatch' }
        # priority (the reported bug): settings.json was just written with
        # sk-test-123 by Apply; a STALE env key must not shadow it on import
        [void](Import-System $true @{ ANTHROPIC_API_KEY = 'sk-old-env'; ANTHROPIC_AUTH_TOKEN = 'sk-old-env'; ANTHROPIC_BASE_URL = 'https://env.example.com' })
        $sysP = @($script:Store.profiles | Where-Object { Test-SystemProfile $_ })[0]
        if ((Unprotect-String ([string]$sysP.apiKey)) -ne 'sk-test-123') { throw 'stale env shadowed settings.json on import' }
        if ([string]$sysP.baseUrl -ne 'https://test.example.com') { throw 'stale env baseUrl shadowed settings.json' }
        # legacy migration (the reported bug): strip the flag to simulate an
        # old store, re-import must find it by name, dedup, re-stamp, and the
        # language switch must rename it - no Russian leftover in NAME
        $profiles2 = @($script:Store.profiles)
        foreach ($p in $profiles2) { if (Test-SystemProfile $p) { Remove-Prop $p 'system'; break } }
        Set-Prop $script:Store 'profiles' $profiles2
        Save-Store
        [void](Import-System $true @{ ANTHROPIC_API_KEY = 'sk-test-123'; ANTHROPIC_AUTH_TOKEN = 'sk-test-123'; ANTHROPIC_BASE_URL = 'https://test.example.com' })
        $sysCount = @($script:Store.profiles | Where-Object { Test-SystemProfile $_ }).Count
        if ($sysCount -ne 1) { throw ('legacy dedup failed, count=' + $sysCount) }
        # import button behavior (the reported bug): after "New" cleared
        # the form, a second import must still select + refill the fields
        $script:CurrentId = $null
        $txtName.Text = ''; $txtBase.Text = ''; $txtKey.Text = ''
        # NOTE: must pass the same EnvOverride - without it the function
        # reads the REAL machine env (user's actual ANTHROPIC_* keys) and
        # legitimately overwrites the sandbox profile (first run of this
        # assert caught exactly that)
        $sysEnv = @{ ANTHROPIC_API_KEY = 'sk-test-123'; ANTHROPIC_AUTH_TOKEN = 'sk-test-123'; ANTHROPIC_BASE_URL = 'https://test.example.com' }
        $again = Import-System $true $sysEnv
        if (-not $again) { throw 'second import returned false' }
        Refresh-List
        if (-not (Select-SystemInList)) { throw 'system profile not selectable' }
        if ($txtKey.Text -ne 'sk-test-123') { throw 'import did not refill key field' }
        if ($txtName.Text -ne (T 'sys_name')) { throw 'import did not refill name field' }
        # language switch: texts must change and persist
        Set-Lang 'en'
        if ((T 'btn_save') -ne 'Save') { throw 'lang switch failed' }
        $sysEn = @($script:Store.profiles | Where-Object { Test-SystemProfile $_ })[0]
        if ([string]$sysEn.name -ne 'System') { throw ('legacy system profile not renamed on lang switch: ' + [string]$sysEn.name) }
        Load-Store
        if ($script:Store.settings.lang -ne 'en') { throw 'lang not persisted' }
        Set-Lang 'ru'
        # theme switch: palette must change and persist
        Set-Theme 'dark'
        if ($script:surface.R -ne 42) { throw 'dark palette not applied' }
        Load-Store
        if ($script:Store.settings.theme -ne 'dark') { throw 'theme not persisted' }
        Set-Theme 'light'
        # apply must follow the SCREEN, not the stale store (the reported
        # bug: opus picked in the dropdown, Apply wrote the old deepseek)
        $sysP2 = @($script:Store.profiles | Where-Object { Test-SystemProfile $_ })[0]
        Load-IntoFields $sysP2
        Select-ModelOrAdd 'test-model-screen'
        $profA = Save-FromFields
        if (-not $profA) { throw 'Save-FromFields returned null' }
        if ([string]$profA.model -ne 'test-model-screen') { throw 'save did not capture the screen model' }
        $null = Apply-ToClaudeCli $profA
        $docM = [IO.File]::ReadAllText((Join-Path $env:USERPROFILE '.claude\settings.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($docM.env.ANTHROPIC_MODEL -ne 'test-model-screen') { throw 'apply ignored the model selected on screen' }
        # the system flag must survive an edit-save of the system profile
        $sysAfter = @($script:Store.profiles | Where-Object { Test-SystemProfile $_ })
        if ($sysAfter.Count -ne 1) { throw ('system flag lost on save, count=' + $sysAfter.Count) }
        # log tail must be readable for the viewer window
        if (-not (Get-LogTail 20)) { throw 'log tail empty' }
        # layout: no vertical overlaps between stacked elements (the
        # reported bug: labels ran into the profile block / each other)
        Do-Layout
        $pairs = @(
            @($lblDot, $lblProfiles), @($lblProfiles, $lvWell),
            @($lvWell, $lblName), @($lblName, $pnlName),
            @($pnlName, $lblBase), @($pnlBase, $lblKey),
            @($lblKey, $pnlKey), @($pnlKey, $lblModel),
            @($lblModel, $cmbModel), @($cmbModel, $pnlProgress),
            @($pnlProgress, $lblMode),
            @($lblMode, $segApi), @($segApi, $btnNew),
            @($btnNew, $btnApply), @($btnApply, $lblStatus)
        )
        foreach ($pr in $pairs) {
            if ($pr[0].Bottom -gt $pr[1].Top) {
                throw ('layout overlap: ' + $pr[0].Name + ' bottom=' + $pr[0].Bottom + ' > ' + $pr[1].Name + ' top=' + $pr[1].Top)
            }
        }
        if ($lblStatus.Bottom -gt $form.ClientSize.Height) { throw 'status clipped by window' }
        # icon row must fit horizontally
        if (($btnLangRu.Left -lt ($lblTitle.Right + 4)) -or ($btnClose.Right -gt ($form.ClientSize.Width - 8))) { throw 'icon row misplaced' }
        # sub label must sit fully below the icon row (reported overlap)
        if ($lblDot.Top -lt $btnClose.Bottom) { throw 'sub label overlaps icon row' }
        Write-Log 'info' 'selftest ok'
        Write-Host 'SELFTEST OK'
        exit 0
    } catch {
        Write-Log 'error' ('selftest FAILED: ' + $_.Exception.Message)
        Write-Host ('SELFTEST FAILED: ' + $_.Exception.Message)
        exit 1
    } finally {
        $env:USERPROFILE = $savedUp
        $script:SecretsPath = $savedSecrets
        Remove-Item -LiteralPath $tmpProfile -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Smoke) {
    # smoke: everything above executed without throwing -> validate DPAPI roundtrip
    $probe = Protect-String 'clodkey-smoke'
    if ((Unprotect-String $probe) -ne 'clodkey-smoke') { Write-Log 'error' 'smoke: DPAPI roundtrip FAILED'; exit 1 }
    Write-Log 'info' 'smoke ok'
    $tray.Visible = $false
    $tray.Dispose()
    $form.Dispose()
    exit 0
}

if ($Shot) {
    # render evidence: show the flyout WITHOUT animation, pump the
    # message loop, capture to png, exit. Step logs make any future
    # hang pinpointable from clodkey.log alone.
    Write-Log 'info' 'shot: begin'
    $pt = Position-Flyout
    $form.Location = New-Object Drawing.Point($pt.X, $pt.Y)
    $form.Opacity = 1.0
    $form.Show()
    Write-Log 'info' 'shot: shown'
    $deadline = (Get-Date).AddMilliseconds(800)
    while ((Get-Date) -lt $deadline) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
    Write-Log 'info' ('shot: pumped bounds=' + $form.Bounds.ToString() + ' visible=' + $form.Visible)
    # DrawToBitmap renders the control tree directly - immune to
    # occlusion, DPI offset and off-screen placement that made the
    # earlier CopyFromScreen evidence capture come out blank.
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $rect = New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)
    $form.DrawToBitmap($bmp, $rect)
    $png = Join-Path $LogDir 'shot.png'
    $bmp.Save($png, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Log 'info' ('shot saved: ' + $png)
    $tray.Visible = $false
    $tray.Dispose()
    $form.Dispose()
    exit 0
}

# first run with zero profiles: show the flyout so the user can add a key
if (@($script:Store.profiles).Count -eq 0) { Show-Main }

# main loop: Application::Run() WITHOUT a form argument - Run($form) would
# auto-show the window, breaking "start hidden to tray" (GOLD invariant).
# Exit is explicit: Exit-App -> Application::Exit().
[System.Windows.Forms.Application]::Run()

$tray.Dispose()
try { $script:Mutex.ReleaseMutex() } catch { }
try { $script:Mutex.Dispose() } catch { }
Write-Log 'info' 'exit'
