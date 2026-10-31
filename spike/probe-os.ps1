# OS-level probe (ADR 0004/0006/0009). Records facts as JSON; never aborts on a failed step,
# because a failure is itself the result ("unverified on Windows" -> verified-as-failing on the runner).
param([string]$Out = "spike-out")
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$r = [ordered]@{}
function Step($name, [scriptblock]$f) {
  try { $r[$name] = & $f } catch { $r[$name] = "ERROR: $($_.Exception.Message)" }
  Write-Host ("[{0}] {1}" -f $name, ($r[$name] | ConvertTo-Json -Compress -Depth 4))
}

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System; using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVirtualDesktopManager {
  [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr h, out bool b);
  [PreserveSig] int GetWindowDesktopId(IntPtr h, out Guid g);
  [PreserveSig] int MoveWindowToDesktop(IntPtr h, ref Guid g);
}
public static class W {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int sz);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  public static IVirtualDesktopManager Vdm() {
    return (IVirtualDesktopManager)Activator.CreateInstance(
      Type.GetTypeFromCLSID(new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A")));
  }
}
"@

Step "session" {
  [ordered]@{
    user_interactive = [Environment]::UserInteractive
    session_id = (Get-Process -Id $PID).SessionId
    os = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber)
    screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.ToString()
    screens = [System.Windows.Forms.Screen]::AllScreens.Count
    fg_at_start = [W]::GetForegroundWindow().ToInt64()
    explorer_running = [bool](Get-Process explorer -ErrorAction SilentlyContinue)
  }
}

$a = $null; $b = $null
Step "start_notepad_a" {
  $script:a = Start-Process notepad -PassThru; Start-Sleep 3
  $script:a.Refresh()
  [ordered]@{ pid = $script:a.Id; main_hwnd = $script:a.MainWindowHandle.ToInt64(); title = $script:a.MainWindowTitle }
}
Step "foreground_after_a" { [W]::GetForegroundWindow().ToInt64() }
Step "set_foreground_a" {
  $ok = [W]::SetForegroundWindow($script:a.MainWindowHandle); Start-Sleep 1
  [ordered]@{ returned = $ok; fg = [W]::GetForegroundWindow().ToInt64(); is_a = ([W]::GetForegroundWindow() -eq $script:a.MainWindowHandle) }
}
Step "start_notepad_b" {
  $script:b = Start-Process notepad -PassThru; Start-Sleep 3
  $script:b.Refresh()
  [ordered]@{ pid = $script:b.Id; main_hwnd = $script:b.MainWindowHandle.ToInt64()
              fg = [W]::GetForegroundWindow().ToInt64()
              b_took_focus = ([W]::GetForegroundWindow() -eq $script:b.MainWindowHandle) }
}
Step "set_foreground_back_to_a" {
  $ok = [W]::SetForegroundWindow($script:a.MainWindowHandle); Start-Sleep 1
  [ordered]@{ returned = $ok; is_a = ([W]::GetForegroundWindow() -eq $script:a.MainWindowHandle) }
}
Step "dwm_frame_a" {
  $h = $script:a.MainWindowHandle
  $wr = New-Object RECT; $fr = New-Object RECT
  [void][W]::GetWindowRect($h, [ref]$wr)
  $hr = [W]::DwmGetWindowAttribute($h, 9, [ref]$fr, [Runtime.InteropServices.Marshal]::SizeOf([type][RECT]))
  [ordered]@{ window_rect = "$($wr.L),$($wr.T),$($wr.R),$($wr.B)"; extended_frame = "$($fr.L),$($fr.T),$($fr.R),$($fr.B)"; hr = $hr
              margins_lrtb = @(($fr.L-$wr.L), ($fr.T-$wr.T), ($wr.R-$fr.R), ($wr.B-$fr.B)) }
}
Step "vdm_public_com" {
  $v = [W]::Vdm(); $on = $false; $g = [Guid]::Empty
  $h1 = $v.IsWindowOnCurrentVirtualDesktop($script:a.MainWindowHandle, [ref]$on)
  $h2 = $v.GetWindowDesktopId($script:a.MainWindowHandle, [ref]$g)
  [ordered]@{ is_on_current_hr = $h1; on_current = $on; desktop_id_hr = $h2; desktop_id = $g.ToString() }
}
function Desktops {
  $k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops"
  $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
  [ordered]@{ key_exists = [bool]$p; ids_bytes = if ($p -and $p.VirtualDesktopIDs) { $p.VirtualDesktopIDs.Length } else { 0 }
              current_bytes = if ($p -and $p.CurrentVirtualDesktop) { $p.CurrentVirtualDesktop.Length } else { 0 } }
}
Step "vd_registry_before" { Desktops }
Step "vd_create_win_ctrl_d" {
  # Win+Ctrl+D creates and switches to a new virtual desktop (Win 10/11). Best effort.
  foreach ($k in 0x5B, 0x11, 0x44) { [W]::keybd_event($k, 0, 0, [UIntPtr]::Zero) }
  foreach ($k in 0x44, 0x11, 0x5B) { [W]::keybd_event($k, 0, 2, [UIntPtr]::Zero) }
  Start-Sleep 2
  $v = [W]::Vdm(); $on = $true
  $h = $v.IsWindowOnCurrentVirtualDesktop($script:a.MainWindowHandle, [ref]$on)
  [ordered]@{ registry_after = (Desktops); a_still_on_current = $on; hr = $h }
}
Step "cleanup" {
  foreach ($p in @($script:a, $script:b)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
  "done"
}
$r | ConvertTo-Json -Depth 6 | Out-File -Encoding utf8 (Join-Path $Out "os.json")
