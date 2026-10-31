# Focus / retile / removal scenario against a running Jwno (ADR 0004 items 2,3,5,6; ADR 0005).
# Writes spike-out/{hooks.log,actions.log,timeline.txt,rects.txt}. Each step is best-effort.
param([string]$Jwno, [string]$Config, [string]$Out = "spike-out")
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$env:SPIKE_LOG = Join-Path $Out "hooks.log"
$act = Join-Path $Out "actions.log"
$rects = Join-Path $Out "rects.txt"

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVdm { [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr h, out bool b); }
public static class F {
  public static string OnCurrent(IntPtr h) {
    try {
      var v = (IVdm)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A")));
      bool on; int hr = v.IsWindowOnCurrentVirtualDesktop(h, out on);
      return "hr=" + hr + " on_current=" + on;
    } catch (Exception e) { return "ERROR " + e.Message; }
  }
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int sz);
}
"@

function Now { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 }
function Ptr($h) { "<pointer 0x{0:X12}>" -f $h.ToInt64() }
function Act($msg) { ("{0:F3} ACTION {1}" -f (Now), $msg) | Add-Content -Path $act -Encoding utf8 }
function Rect($label, $h) {
  $w = New-Object RECT; $e = New-Object RECT
  [void][F]::GetWindowRect($h, [ref]$w)
  [void][F]::DwmGetWindowAttribute($h, 9, [ref]$e, 16)
  ("{0:F3} {1} window=({2},{3},{4},{5}) frame=({6},{7},{8},{9})" -f (Now), $label, $w.L, $w.T, $w.R, $w.B, $e.L, $e.T, $e.R, $e.B) |
    Add-Content -Path $rects -Encoding utf8
}
function Focus($h, $label, [bool]$alt, [int]$settle = 400) {
  # A synthetic Alt press makes this process "the one that received the last input",
  # which is the usual way around the foreground lock.
  if ($alt) { [F]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [F]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero) }
  $ok = [F]::SetForegroundWindow($h)
  Start-Sleep -Milliseconds $settle
  $fg = [F]::GetForegroundWindow()
  Act ("focus {0} alt={1} returned={2} fg_is_target={3} fg={4}" -f $label, $alt, $ok, ($fg -eq $h), (Ptr $fg))
}
function Chord([byte]$vk, $label) {
  # Win+Ctrl+<key>: D = new desktop, Left/Right = switch
  foreach ($k in 0x5B, 0x11, $vk) { [F]::keybd_event($k, 0, 0, [UIntPtr]::Zero) }
  foreach ($k in $vk, 0x11, 0x5B) { [F]::keybd_event($k, 0, 2, [UIntPtr]::Zero) }
  Act "chord $label"
}
function Where($label, $h) {
  Act ("where {0}: fg={1} target_on_current_desktop=[{2}]" -f $label, (Ptr ([F]::GetForegroundWindow())), [F]::OnCurrent($h))
}
function Launch($label) {
  $p = Start-Process notepad -PassThru; Start-Sleep 3; $p.Refresh()
  Act ("launched {0} pid={1} hwnd={2} fg_is_it={3}" -f $label, $p.Id, (Ptr $p.MainWindowHandle), ([F]::GetForegroundWindow() -eq $p.MainWindowHandle))
  $p
}

$jargs = @("--config", $Config, "--log-file", (Join-Path $Out "jwno-own.log"), "--log-level", "debug", "--no-console", "--repl", "127.0.0.1:9999")
$j = Start-Process -FilePath $Jwno -ArgumentList $jargs -PassThru
Start-Sleep 12
Act "jwno started alive=$(-not $j.HasExited)"
if ($j.HasExited) { Write-Host "Jwno exited early"; return }

# S1 windows
$A = Launch "A"; $B = Launch "B"; $C = Launch "C"
$hA = $A.MainWindowHandle; $hB = $B.MainWindowHandle; $hC = $C.MainWindowHandle
Rect "A after-create" $hA; Rect "B after-create" $hB; Rect "C after-create" $hC

# S2 foreground lock, with and without the Alt trick
Focus $hA "A" $false
Focus $hA "A" $true
Focus $hC "C" $true
Focus $hB "B" $true
Focus $hA "A" $true
# S3 duplicate: already foreground
Focus $hA "A(again)" $true
# S4 rapid alternation (notification coalescing / ordering)
Act "rapid B,A,B,A with 30ms settle"
Focus $hB "B(rapid)" $true 30; Focus $hA "A(rapid)" $true 30; Focus $hB "B(rapid)" $true 30; Focus $hA "A(rapid)" $true 400

# S5 manual move, then Jwno's retile
[void][F]::SetWindowPos($hA, [IntPtr]::Zero, 20, 20, 400, 300, 0x0004)
Start-Sleep 2; Rect "A after-manual-move" $hA
Act "retile via REPL client"
$x = & $Jwno -x "retile" 2>&1 | Out-String
Act ("retile client output: {0}" -f $x.Trim())
Start-Sleep 2; Rect "A after-retile" $hA; Rect "B after-retile" $hB; Rect "C after-retile" $hC

# S6 removal of a background window: force-kill B, wait with NO focus change, then make a REAL focus change
Act "kill B (Stop-Process); no focus change for 5s"
Stop-Process -Id $B.Id -Force; Start-Sleep 5
Act "real focus change A -> C"
Focus $hC "C(after-kill)" $true 2000
# S7 removal of the foreground window: close C while it is in front; focus falls to something else by itself
Act "close C gracefully while it is the foreground window"
[void]$C.CloseMainWindow(); Start-Sleep 5
Act ("after close: fg={0} (A is {1})" -f (Ptr ([F]::GetForegroundWindow())), (Ptr $hA))

# ---- ADR 0004 item 5: Jwno's own focus moves vs ours ----
Act "== S8 relaunch two windows =="
$B2 = Launch "B2"; $C2 = Launch "C2"
$hB2 = $B2.MainWindowHandle; $hC2 = $C2.MainWindowHandle
Focus $hB2 "B2" $true 1000

Act "== S9 desktop round trip; focus was B2 =="
Chord 0x44 "Win+Ctrl+D (new desktop, switch to it)"; Start-Sleep 3
Where "on new desktop" $hB2
Chord 0x25 "Win+Ctrl+Left (back to desktop 1)"; Start-Sleep 3
Where "back on desktop 1 (was B2 focused before?)" $hB2

foreach ($delay in 0, 150, 600) {
  Act ("== S10 race: switch away/back, our :focus(C2) {0}ms after the switch-back ==" -f $delay)
  Focus $hB2 "B2(reset)" $true 800
  Chord 0x27 "Win+Ctrl+Right (to desktop 2)"; Start-Sleep 2
  Chord 0x25 "Win+Ctrl+Left (to desktop 1)"
  if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
  Focus $hC2 ("C2(our focus +{0}ms)" -f $delay) $true 100
  Start-Sleep 3
  Where ("final after +{0}ms race (we wanted C2)" -f $delay) $hC2
}

Act "== S11 our :focus on a window of ANOTHER desktop =="
Focus $hB2 "B2(reset)" $true 800
Chord 0x27 "Win+Ctrl+Right (to desktop 2)"; Start-Sleep 2
Where "on desktop 2, before" $hB2
Focus $hB2 "B2 from desktop 2 (alt)" $true 1500
Where "on desktop 2, after focusing B2 (desktop 1 window)" $hB2
Chord 0x25 "Win+Ctrl+Left (ensure desktop 1)"; Start-Sleep 2
Where "end" $hB2

foreach ($p in @($B2, $C2)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
Act ("jwno alive at end={0}" -f (-not $j.HasExited))
if (-not $j.HasExited) { Stop-Process -Id $j.Id -Force }
foreach ($p in @($A)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }

# one timeline from both clocks (same epoch seconds)
$lines = @()
if (Test-Path $env:SPIKE_LOG) { $lines += Get-Content $env:SPIKE_LOG }
if (Test-Path $act) { $lines += Get-Content $act }
if (Test-Path $rects) { $lines += Get-Content $rects }
$lines | Where-Object { $_ -match '^\d+\.\d+ ' } | Sort-Object -Stable { [double]($_ -split ' ', 2)[0] } |
  Out-File -Encoding utf8 (Join-Path $Out "timeline.txt")
Write-Host "===== timeline ====="
Get-Content (Join-Path $Out "timeline.txt")
