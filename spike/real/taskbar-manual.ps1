# MANUAL check for ADR 0011 stage 0: does ITaskbarList::DeleteTab take a window's button off the taskbar, and does it stay off?
# It makes ONE small window titled "XTILE-TB-SPIKE" (a WinForms form) and runs the steps below with pauses, so a person can
# watch the taskbar. No Jwno, no other window is touched. The window is closed at the end. Takes about 80 seconds.
# Steps: 0 s window appears (the button should be there) -> 15 s DeleteTab (button gone?) -> 30 s window activated ->
# 40 s title changed -> 50 s flashed -> 65 s AddTab (button back?) -> 80 s closed.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
[ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090")] public class TaskbarListClass { }
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("56FDF342-FD6D-11d0-958A-006097C9A090")]
public interface ITaskbarList {
  [PreserveSig] int HrInit();
  [PreserveSig] int AddTab(IntPtr hwnd);
  [PreserveSig] int DeleteTab(IntPtr hwnd);
  [PreserveSig] int ActivateTab(IntPtr hwnd);
  [PreserveSig] int SetActiveAlt(IntPtr hwnd);
}
public static class W {
  [DllImport("user32.dll")] public static extern bool FlashWindow(IntPtr h, bool inv);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
$tb = [ITaskbarList](New-Object TaskbarListClass)
Write-Host ("HrInit = " + $tb.HrInit())
$f = New-Object System.Windows.Forms.Form
$f.Text = "XTILE-TB-SPIKE"; $f.Width = 320; $f.Height = 110; $f.StartPosition = "CenterScreen"; $f.ShowInTaskbar = $true
$label = New-Object System.Windows.Forms.Label; $label.Dock = "Fill"; $label.TextAlign = "MiddleCenter"; $label.Text = "watch the taskbar"; $f.Controls.Add($label)
$f.Show(); $f.Activate()
$h = $f.Handle
$t0 = Get-Date
function Step($sec, $text, [scriptblock]$act) {
  while (((Get-Date) - $t0).TotalSeconds -lt $sec) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
  $label.Text = $text
  $r = & $act
  Write-Host ("[{0,5:N1}s] {1} {2}" -f ((Get-Date) - $t0).TotalSeconds, $text, $r)
}
Step 0  "1. button should be on the taskbar now" { "" }
Step 15 "2. DeleteTab: the button should disappear" { "hr=" + $tb.DeleteTab($h) }
Step 30 "3. window activated: still gone?" { $f.Activate(); [void][W]::SetForegroundWindow($h); "" }
Step 40 "4. title changed: still gone?" { $f.Text = "XTILE-TB-SPIKE renamed"; "" }
Step 50 "5. flashed: still gone?" { [void][W]::FlashWindow($h, $true); "" }
Step 65 "6. AddTab: the button should come back" { "hr=" + $tb.AddTab($h) }
Step 80 "7. closing" { $f.Close(); "" }
