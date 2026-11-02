# MANUAL (or screenshot-driven, with -ShotDir) check for ADR 0011 stage 0: does ITaskbarList::DeleteTab take a window's button off the taskbar, and does it stay off?
# It makes ONE small window titled "XTILE-TB-SPIKE" (a WinForms form) and runs the steps below with pauses, so a person can
# watch the taskbar. No Jwno, no other window is touched. The window is closed at the end. Takes about 80 seconds.
# Steps: 0 s window appears (the button should be there) -> 15 s DeleteTab (button gone?) -> 30 s window activated ->
# 40 s title changed -> 50 s flashed -> 65 s AddTab (button back?) -> 80 s closed.
param([int]$Gap = 15, [string]$ShotDir = "")
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
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
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool FlashWindow(IntPtr h, bool inv);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@
[void][W]::SetProcessDPIAware()      # physical pixels: the picture of the taskbar must not be cut off at 125-200 % scaling
$tb = [ITaskbarList][Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]"56FDF344-FD6D-11d0-958A-006097C9A090"))
try { Write-Host ("HrInit = " + $tb.HrInit()) } catch { Write-Host ("HrInit threw " + $_.Exception.GetType().Name + " 0x" + ("{0:X8}" -f $_.Exception.HResult)) }
$f = New-Object System.Windows.Forms.Form
$f.Text = "XTILE-TB-SPIKE"; $f.Width = 320; $f.Height = 110; $f.StartPosition = "CenterScreen"; $f.ShowInTaskbar = $true
$label = New-Object System.Windows.Forms.Label; $label.Dock = "Fill"; $label.TextAlign = "MiddleCenter"; $label.Text = "watch the taskbar"; $f.Controls.Add($label)
$f.Show(); $f.Activate()
$h = $f.Handle
$t0 = Get-Date
# a picture of the taskbar strip after each step (bottom of the primary screen: the part outside the working area)
function Shot($name) {
  if (-not $ShotDir) { return }
  New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
  $scr = [System.Windows.Forms.Screen]::PrimaryScreen
  $b = $scr.Bounds; $wa = $scr.WorkingArea
  $h = [Math]::Max($b.Bottom - $wa.Bottom, 0) + 24; if ($h -lt 100) { $h = 100 }     # the taskbar plus a margin above it
  $w = [Math]::Min($b.Width, 1000); $x = $b.Left + [int](($b.Width - $w) / 2)
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x, $b.Bottom - $h, 0, 0, (New-Object System.Drawing.Size($w, $h)))
  $bmp.Save((Join-Path $ShotDir "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
function Step($sec, $text, [scriptblock]$act) {
  while (((Get-Date) - $t0).TotalSeconds -lt $sec) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
  $label.Text = $text
  $r = try { & $act } catch { "THREW " + $_.Exception.GetType().Name + " 0x" + ("{0:X8}" -f $_.Exception.HResult) }
  $until = (Get-Date).AddMilliseconds(1500)
  while ((Get-Date) -lt $until) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }   # let the shell react
  Shot ($text.Substring(0, 1) + "-" + ($text -replace '[^A-Za-z]', '').Substring(0, [Math]::Min(12, ($text -replace '[^A-Za-z]', '').Length)))
  Write-Host ("[{0,5:N1}s] {1} {2}" -f ((Get-Date) - $t0).TotalSeconds, $text, $r)
}
Step 0  "1. button should be on the taskbar now" { "" }
Step $Gap "2. DeleteTab: the button should disappear" { "hr=" + $tb.DeleteTab($h) }
Step (2*$Gap) "3. window activated: still gone?" { $f.Activate(); [void][W]::SetForegroundWindow($h); "" }
Step (3*$Gap) "4. title changed: still gone?" { $f.Text = "XTILE-TB-SPIKE renamed"; "" }
Step (4*$Gap) "5. flashed: still gone?" { [void][W]::FlashWindow($h, $true); "" }
Step (5*$Gap) "6. AddTab: the button should come back" { "hr=" + $tb.AddTab($h) }
Step (6*$Gap) "7. closing" { $f.Close(); "" }
