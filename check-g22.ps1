# G22 gate: zero console windows owned by ClodKey processes.
# Run after deploy. Exit 1 if any ConsoleWindowClass/CASCADIA window
# belongs to our process tree. ASCII only.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Write-Output '--- our procs ---'
$ours = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'ClodKey\.ps1' })
foreach ($x in $ours) { Write-Output ('pid=' + $x.ProcessId + ' session=' + $x.SessionId + ' parent=' + $x.ParentProcessId) }
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
