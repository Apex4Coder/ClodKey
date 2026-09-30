# G22 gate: zero console windows owned by ClodKeyProxy processes.
# Run after deploy. Exit 1 if any ConsoleWindowClass/CASCADIA window
# belongs to our process tree. ASCII only.
#
# Adapted from the v1 gate: the process match is now ClodKeyProxy.ps1
# (it was ClodKey.ps1 before the rename), and the wscript host that
# launches it through run-hidden.vbs is included, because a console
# window can only ever appear on that path.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Write-Output '--- our procs ---'
$ours = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'ClodKeyProxy\.ps1' })
foreach ($x in $ours) { Write-Output ('pid=' + $x.ProcessId + ' name=' + $x.Name + ' session=' + $x.SessionId + ' parent=' + $x.ParentProcessId) }
Write-Output '--- console windows owned by ours (G22) ---'
$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;
public static class WinEnum {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    public static List<string> Find(List<uint> pids) {
        var res = new List<string>();
        EnumWindows((h,l)=>{
            uint pid; GetWindowThreadProcessId(h, out pid);
            if(pids.Contains(pid)){
                var sb=new StringBuilder(256); GetClassName(h,sb,256);
                string cn=sb.ToString();
                if(cn=="ConsoleWindowClass"||cn.Contains("CASCADIA")||cn=="PseudoConsoleWindow")
                    res.Add(pid+" "+cn+" visible="+IsWindowVisible(h));
            }
            return true;
        }, IntPtr.Zero);
        return res;
    }
}
'@
Add-Type -TypeDefinition $src
$pids = [System.Collections.Generic.List[uint32]]::new()
foreach ($o in $ours) { $pids.Add([uint32]$o.ProcessId) }
$found = [WinEnum]::Find($pids)
if ($found.Count -eq 0) { Write-Output 'G22 GREEN: zero console windows'; exit 0 }
foreach ($f in $found) { Write-Output ('CONSOLE WINDOW: ' + $f) }
exit 1
