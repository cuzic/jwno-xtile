# Evidence for ADR 0006 (how workspaces are implemented). OS level only -- no Jwno.
#  P1  can MoveWindowToDesktop (public COM) move ANOTHER process's window?   -> option 1 :send
#  P2  does switching desktops by Win+Ctrl+Arrow survive a held Alt / Shift?  -> option 1 :goto
#  P3  is hopping between several desktops reliable, and how fast?            -> option 1 :goto
#  P4  what can this process do to hide ANOTHER process's window?             -> option 2
# Hosted Windows Server 2022 only: not a Windows 10/11 desktop.
param([string]$Out = "spike-out")
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$res = [ordered]@{}
function Step($name, [scriptblock]$f) {
  try { $res[$name] = & $f } catch { $res[$name] = "ERROR: $($_.Exception.Message)" }
  Write-Host ("[{0}] {1}" -f $name, ($res[$name] | ConvertTo-Json -Compress -Depth 5))
}

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
[ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVdm2 {
  [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr h, out bool b);
  [PreserveSig] int GetWindowDesktopId(IntPtr h, out Guid g);
  [PreserveSig] int MoveWindowToDesktop(IntPtr h, ref Guid g);
}
public static class P {
  static IVdm2 v() { return (IVdm2)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A"))); }
  public static string DesktopOf(IntPtr h) { Guid g; int hr = v().GetWindowDesktopId(h, out g); return hr == 0 ? g.ToString("D").ToUpper() : ("hr=0x" + hr.ToString("X")); }
  public static bool OnCurrent(IntPtr h) { bool b; v().IsWindowOnCurrentVirtualDesktop(h, out b); return b; }
  public static string Move(IntPtr h, string guid) { Guid g = new Guid(guid); int hr = v().MoveWindowToDesktop(h, ref g); return "hr=0x" + hr.ToString("X8"); }
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int sz);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@

function Key([byte]$k, [bool]$down) { [P]::keybd_event($k, 0, $(if ($down) { 0 } else { 2 }), [UIntPtr]::Zero) }
function Chord([byte]$vk, [byte[]]$held = @()) {
  foreach ($h in $held) { Key $h $true }
  foreach ($k in 0x5B, 0x11, $vk) { Key $k $true }
  foreach ($k in $vk, 0x11, 0x5B) { Key $k $false }
  foreach ($h in $held) { Key $h $false }
}
function Launch() { $p = Start-Process notepad -PassThru; Start-Sleep 3; $p.Refresh(); $p }
function WaitOn($h, [int]$ms = 4000) {   # ms until the window is on the current desktop, or -1
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) { if ([P]::OnCurrent($h)) { return $sw.ElapsedMilliseconds }; Start-Sleep -Milliseconds 25 }
  -1
}
function WaitOff($h, [int]$ms = 4000) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) { if (-not [P]::OnCurrent($h)) { return $sw.ElapsedMilliseconds }; Start-Sleep -Milliseconds 25 }
  -1
}

$A = Launch; $hA = $A.MainWindowHandle
$g1 = [P]::DesktopOf($hA)
Step "setup" { [ordered]@{ desktop1 = $g1; windowA = $hA.ToInt64() } }

Chord 0x44; Start-Sleep 2            # Win+Ctrl+D: desktop 2
$B = Launch; $hB = $B.MainWindowHandle
$g2 = [P]::DesktopOf($hB)
Step "desktop2" { [ordered]@{ desktop2 = $g2; windowB = $hB.ToInt64(); a_on_current = [P]::OnCurrent($hA); b_on_current = [P]::OnCurrent($hB) } }

# ---- P1: MoveWindowToDesktop on a window of ANOTHER process ----
Step "P1_move_A_to_desktop2" {
  $r = [P]::Move($hA, $g2); Start-Sleep 1
  [ordered]@{ result = $r; A_now_on = [P]::DesktopOf($hA); moved = ([P]::DesktopOf($hA) -eq $g2) }
}
Step "P1_move_B_to_desktop1" {
  $r = [P]::Move($hB, $g1); Start-Sleep 1
  [ordered]@{ result = $r; B_now_on = [P]::DesktopOf($hB); moved = ([P]::DesktopOf($hB) -eq $g1) }
}

# ---- P2: switching with a modifier held (our bindings are Alt+<n>; Alt is physically down) ----
Chord 0x25; Start-Sleep 2            # back to desktop 1 (known state)
$here = [P]::OnCurrent($hA)
$trial = @{}
foreach ($mod in @(@{n="none";k=@()}, @{n="alt";k=@(0x12)}, @{n="shift";k=@(0x10)}, @{n="alt+shift";k=@(0x12,0x10)})) {
  # go to the other desktop, then come back, each time with the modifier held
  Chord 0x27 ([byte[]]$mod.k); $to = WaitOff $hA 3000
  Start-Sleep -Milliseconds 800
  Chord 0x25 ([byte[]]$mod.k); $back = WaitOn $hA 3000
  Start-Sleep -Milliseconds 800
  $trial[$mod.n] = [ordered]@{ switched_away_ms = $to; switched_back_ms = $back }
}
Step "P2_modifier_held" { $trial }

# ---- P3: hopping between three desktops, 12 random hops ----
Chord 0x44; Start-Sleep 2            # desktop 3 (switched to it)
$C = Launch; $hC = $C.MainWindowHandle
$wins = @{ 1 = $hA; 2 = $hB; 3 = $hC }
# A moved? B moved? to be sure which windows live where, read their desktops
Step "P3_layout" { [ordered]@{ A = [P]::DesktopOf($hA); B = [P]::DesktopOf($hB); C = [P]::DesktopOf($hC); g1 = $g1; g2 = $g2 } }
$gmap = @{}
$gmap[1] = $g1; $gmap[2] = $g2; $gmap[3] = [P]::DesktopOf($hC)
function Probe($k) {   # which of 1..3 are we on, judged by IsWindowOnCurrentVirtualDesktop of a window known to live there
  foreach ($i in 1, 2, 3) {
    $w = @($hA, $hB, $hC) | Where-Object { [P]::DesktopOf($_) -eq $gmap[$i] } | Select-Object -First 1
    if ($w -and [P]::OnCurrent($w)) { return $i }
  }
  return 0
}
function GoTo($cur, $want) {
  $n = [math]::Abs($want - $cur)
  for ($i = 0; $i -lt $n; $i++) { Chord $(if ($want -gt $cur) { 0x27 } else { 0x25 }); Start-Sleep -Milliseconds 350 }
}
$cur = Probe 0
$ok = 0; $tries = 12; $rng = New-Object System.Random 7; $log = @(); $times = @()
for ($t = 0; $t -lt $tries; $t++) {
  $want = $rng.Next(1, 4)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  GoTo $cur $want
  $deadline = (Get-Date).AddSeconds(3)
  do { $now = Probe 0; if ($now -eq $want) { break }; Start-Sleep -Milliseconds 50 } while ((Get-Date) -lt $deadline)
  $times += $sw.ElapsedMilliseconds
  if ($now -eq $want) { $ok++ }
  $log += "$cur->$want got $now"
  $cur = $now
}
Step "P3_hops" { [ordered]@{ ok = $ok; of = $tries; log = $log; ms = $times } }

# ---- P4: hiding another process's window ----
Step "P4_sw_hide" {
  Chord 0x25; Start-Sleep 1; Chord 0x25; Start-Sleep 2   # desktop 1 (A's desktop)
  $r = [ordered]@{}
  $r.visible_before = [P]::IsWindowVisible($hA)
  [void][P]::ShowWindow($hA, 0); Start-Sleep -Milliseconds 500      # SW_HIDE
  $r.visible_after_hide = [P]::IsWindowVisible($hA)
  [void][P]::ShowWindow($hA, 5); Start-Sleep -Milliseconds 500      # SW_SHOW
  $r.visible_after_show = [P]::IsWindowVisible($hA)
  $r
}
Step "P4_cloak" {
  $v = 1; $hr = [P]::DwmSetWindowAttribute($hA, 13, [ref]$v, 4)    # DWMWA_CLOAK
  [ordered]@{ hr = ("0x" + $hr.ToString("X8")) }
}
Step "P4_offscreen" {
  $rc = New-Object P+RECT; [void][P]::GetWindowRect($hA, [ref]$rc)
  $before = "$($rc.L),$($rc.T)"
  [void][P]::SetWindowPos($hA, [IntPtr]::Zero, -32000, -32000, 0, 0, 0x0005)   # NOSIZE|NOZORDER
  Start-Sleep -Milliseconds 300
  [void][P]::GetWindowRect($hA, [ref]$rc)
  [ordered]@{ before = $before; after = "$($rc.L),$($rc.T)"; visible = [P]::IsWindowVisible($hA) }
}

foreach ($p in @($A, $B, $C)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
$res | ConvertTo-Json -Depth 6 | Out-File -Encoding utf8 (Join-Path $Out "workspaces.json")
