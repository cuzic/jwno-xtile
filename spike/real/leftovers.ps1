# Read-only: are there top-level windows now that did not exist before the run? (They would be ours: empty Notepads.)
# Titles and process names are listed ONLY for windows that are new since windows-before.json.
param([string]$Work = "C:\Users\cuzic\xtile-realtest")
$o = Join-Path $Work "out"
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
public static class L {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IVdm { [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr h, out bool b); }
  public static bool OnCurrent(IntPtr h) { try { var v = (IVdm)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A"))); bool b; v.IsWindowOnCurrentVirtualDesktop(h, out b); return b; } catch { return true; } }
  public static List<long> TopLevel() { var l = new List<long>(); EnumWindows((h, _) => { if (IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && (GetWindowLong(h, -20) & 0x80) == 0) l.Add(h.ToInt64()); return true; }, IntPtr.Zero); return l; }
  public static string Info(long h) { var t = new StringBuilder(200); GetWindowText((IntPtr)h, t, 200); var c = new StringBuilder(100); GetClassName((IntPtr)h, c, 100); uint pid; GetWindowThreadProcessId((IntPtr)h, out pid); return "pid=" + pid + " class=" + c + " title=\"" + t + "\""; }
}
"@
$before = @{}
$bf = Join-Path $o "windows-before.json"
if (Test-Path $bf) { (Get-Content $bf -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $before[$_.Name] = $true } }
"windows before the run: $($before.Count)"
$new = @([L]::TopLevel() | Where-Object { -not $before.ContainsKey("$_") })
"top-level windows now that were not there before: $($new.Count)"
foreach ($h in $new) { "  hwnd=$h on-current-desktop=$([L]::OnCurrent([IntPtr]$h)) $([L]::Info($h))" }
"notepad processes: " + ((Get-Process notepad -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) -join ",")
"jwno running: " + [bool](Get-Process jwno -ErrorAction SilentlyContinue)
