Option Explicit
' ============================================================
' run-hidden.vbs - launch with ZERO console windows (visible or
' hidden). ASCII only. wscript.exe exists on every Windows, needs
' no execution policy and has zero dependencies.
'
' EMPIRICAL (this machine, Win11): WMI CreateFlags=DETACHED_PROCESS(8)
' kills powershell.exe before the first script line (works for node,
' not for powershell). CreateFlags=CREATE_NO_WINDOW(16) runs fine in
' the interactive session; powershell still allocates a console but
' its window is never shown, and ClodKey.ps1 calls FreeConsole() at
' startup - conhost then DESTROYS that hidden window because no
' attached process remains. Net result: zero console windows, and
' the self-hide fallback never has to run.
' Shell.Run style 0 is NOT used: it still allocates a console window.
' ============================================================
Const CREATE_NO_WINDOW = 16
Const SW_HIDE = 0

Dim shell, fso, here, ps, locator, svc, cfg, proc, pid, rc, args
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
shell.CurrentDirectory = here

' PowerShell 5.1 ships with Windows; System32 path is fixed
ps = fso.BuildPath(shell.ExpandEnvironmentStrings("%WINDIR%"), _
     "System32\WindowsPowerShell\v1.0\powershell.exe")
If Not fso.FileExists(ps) Then
    ' fallback: PATH lookup
    ps = "powershell.exe"
End If

' -STA is mandatory for WinForms.
' NO -WindowStyle Hidden here: that flag allocates a HIDDEN console
' window (invisible but present). With DETACHED_PROCESS below there is
' no console at all, so nothing must ask for one. Zero windows,
' visible or hidden - this is the hard requirement.
args = Chr(34) & ps & Chr(34) & _
       " -NoProfile -STA -ExecutionPolicy Bypass" & _
       " -File " & Chr(34) & fso.BuildPath(here, "ClodKey.ps1") & Chr(34) & _
       " -Minimized"

Set locator = CreateObject("WbemScripting.SWbemLocator")
Set svc = locator.ConnectServer(".", "root\cimv2")
Set cfg = svc.Get("Win32_ProcessStartup").SpawnInstance_
cfg.CreateFlags = CREATE_NO_WINDOW
cfg.ShowWindow = SW_HIDE
Set proc = svc.Get("Win32_Process")
rc = proc.Create(args, here, cfg, pid)
WScript.Quit rc
