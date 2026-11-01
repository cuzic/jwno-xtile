# Closes ONLY windows this test run left behind: not in windows-before.json, class Notepad, title "Untitled" (empty:
# closing it asks nothing). Refuses if there are more than 8 (something else is going on). WM_CLOSE, never Stop-Process:
# the packaged Notepad hosts all windows in ONE process, which may also host the user's own.
param([string]$Work = "C:\Users\cuzic\xtile-realtest")
$o = Join-Path $Work "out"
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
public static class X {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static List<long> TopLevel() { var l = new List<long>(); EnumWindows((h, _) => { if (IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && (GetWindowLong(h, -20) & 0x80) == 0) l.Add(h.ToInt64()); return true; }, IntPtr.Zero); return l; }
  public static string Title(long h) { var t = new StringBuilder(200); GetWindowText((IntPtr)h, t, 200); return t.ToString(); }
  public static string Class(long h) { var c = new StringBuilder(100); GetClassName((IntPtr)h, c, 100); return c.ToString(); }
}
"@
$before = @{}
$bf = Join-Path $o "windows-before.json"
if (-not (Test-Path $bf)) { "refusing: no windows-before.json"; exit 2 }
(Get-Content $bf -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $before[$_.Name] = $true }
$cand = @([X]::TopLevel() | Where-Object { -not $before.ContainsKey("$_") -and [X]::Class($_) -eq "Notepad" -and [X]::Title($_) -like "タイトルなし*" })
"candidates (new since the run started, class Notepad, untitled): $($cand.Count)"
if ($cand.Count -gt 8) { "refusing: more than 8"; exit 3 }
foreach ($h in $cand) { "closing $h"; [void][X]::PostMessage([IntPtr]$h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }   # WM_CLOSE
Start-Sleep 3
$left = @([X]::TopLevel() | Where-Object { -not $before.ContainsKey("$_") })
"windows still new since the run started: $($left.Count)"
foreach ($h in $left) { "  hwnd=$h class=$([X]::Class($h))" }
