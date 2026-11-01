# Real-machine run of the contract tests (ADR 0010 / 0006), on a FRESH virtual desktop so the user's own
# windows are never managed. Safety net:
#   * the user's windows (position, size, maximised, minimised) are recorded before and compared after;
#   * only processes started during the run are killed (the notepads this script's tests launch);
#   * the virtual desktops created here are closed again, found by an anchor window of the original desktop;
#   * the mouse pointer is put back.
# Output: <Out>\progress.log, contract-results.json, safety.json, summary.txt
param([Parameter(Mandatory)][string]$Jwno, [Parameter(Mandatory)][string]$RepoRoot, [string]$Out = "C:\Users\cuzic\xtile-realtest\out")
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
Get-ChildItem $Out -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
$prog = Join-Path $Out "progress.log"
function P($m) { ("{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $m) | Add-Content -Path $prog -Encoding utf8 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
[StructLayout(LayoutKind.Sequential)] public struct RECT2 { public int L, T, R, B; }
public static class R {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT2 r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static string Title(long h) { var t = new StringBuilder(200); GetWindowText((IntPtr)h, t, 200); return t.ToString(); }
  public static string Class(long h) { var c = new StringBuilder(100); GetClassName((IntPtr)h, c, 100); return c.ToString(); }
  [ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IVdm { [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr h, out bool b); }
  public static bool OnCurrent(IntPtr h) {
    try { var v = (IVdm)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A")));
      bool b; v.IsWindowOnCurrentVirtualDesktop(h, out b); return b; } catch { return true; } }
  public static List<long> TopLevel() {
    var l = new List<long>();
    EnumWindows((h, _) => { if (IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && (GetWindowLong(h, -20) & 0x80) == 0) l.Add(h.ToInt64()); return true; }, IntPtr.Zero);
    return l; }
}
"@
function Chord([byte]$vk) {
  foreach ($k in 0x5B, 0x11, $vk) { [R]::keybd_event($k, 0, 0, [UIntPtr]::Zero) }
  foreach ($k in $vk, 0x11, 0x5B) { [R]::keybd_event($k, 0, 2, [UIntPtr]::Zero) }
}
function DesktopCount() {
  $p = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops' -ErrorAction SilentlyContinue
  if ($p -and $p.VirtualDesktopIDs) { [int]($p.VirtualDesktopIDs.Length / 16) } else { 1 }
}
function Snapshot() {
  $o = @{}
  foreach ($h in [R]::TopLevel()) {
    $r = New-Object RECT2; [void][R]::GetWindowRect([IntPtr]$h, [ref]$r)
    $o["$h"] = "{0},{1},{2},{3} zoomed={4} iconic={5}" -f $r.L, $r.T, $r.R, $r.B, [R]::IsZoomed([IntPtr]$h), [R]::IsIconic([IntPtr]$h)
  }
  $o
}

P "start; jwno=$Jwno repo=$RepoRoot"
if (-not (Test-Path $Jwno)) { P "FATAL: jwno.exe not found"; exit 2 }
$cursor0 = [System.Windows.Forms.Cursor]::Position
$notepads0 = @(Get-Process notepad -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$jwno0 = @(Get-Process jwno -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
if ($jwno0.Count -gt 0) { P "FATAL: a Jwno is already running (pid $($jwno0 -join ',')); refusing to start a second one"; exit 3 }
$anchor = [R]::GetForegroundWindow()
if ($anchor -eq [IntPtr]::Zero -or -not [R]::OnCurrent($anchor)) {
  $anchor = ([R]::TopLevel() | Where-Object { [R]::OnCurrent([IntPtr]$_) } | Select-Object -First 1)
  $anchor = [IntPtr]$anchor
}
$n0 = DesktopCount
$before = Snapshot
$before | ConvertTo-Json | Out-File -Encoding utf8 (Join-Path $Out "windows-before.json")
P "anchor window=$($anchor.ToInt64()) desktops=$n0 user windows=$($before.Count) notepads already running=$($notepads0.Count)"

$exit = 1
try {
  Chord 0x44   # Win+Ctrl+D: a new, empty virtual desktop; everything below happens there
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ([R]::OnCurrent($anchor) -and $sw.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 100 }
  if ([R]::OnCurrent($anchor)) { P "FATAL: could not switch to a new desktop; not touching anything"; throw "no new desktop" }
  Start-Sleep 2
  P "on a fresh desktop (desktops now $(DesktopCount)); running the contract tests"
  $env:CONTRACT_OUT = Join-Path $Out "contract.log"
  $pw = "C:\Program Files\PowerShell\7\pwsh.exe"
  $cfg = Join-Path $RepoRoot "spike\contract-config.janet"
  & $pw -NoProfile -File (Join-Path $RepoRoot "spike\run-contract.ps1") -Jwno $Jwno -RepoRoot $RepoRoot -Config $cfg -Out $Out -ReplPort 19999 *>&1 | Add-Content -Path (Join-Path $Out "contract-console.log") -Encoding utf8
  $exit = $LASTEXITCODE
  P "contract script finished, exit=$exit"
} catch {
  P "ERROR: $($_.Exception.Message)"
} finally {
  P "cleanup"
  # 1. Jwno: graceful, then forced
  $js = @(Get-Process jwno -ErrorAction SilentlyContinue)
  if ($js.Count -gt 0) {
    & $Jwno --repl "127.0.0.1:19999" -x quit 2>&1 | Out-Null
    foreach ($j in $js) { [void]$j.WaitForExit(20000) }
    Get-Process jwno -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
  # 2. close the windows this run created: new since the snapshot, class Notepad, untitled and empty. WM_CLOSE, never
  #    Stop-Process: the packaged Notepad has ONE process for all its windows, the user's included.
  for ($round = 0; $round -lt 3; $round++) {
    foreach ($h in [R]::TopLevel()) {
      if (-not $before.ContainsKey("$h") -and [R]::Class($h) -eq "Notepad" -and ([R]::Title($h) -like "タイトルなし*" -or [R]::Title($h) -like "Untitled*")) {
        [void][R]::PostMessage([IntPtr]$h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
      }
    }
    Start-Sleep 2
  }
  # anything else that is new on the temporary desktop is not ours to decide about: then the desktop is NOT closed,
  # because closing it would move that window to the user's desktop
  $unexpected = @([R]::TopLevel() | Where-Object { -not $before.ContainsKey("$_") -and [R]::OnCurrent([IntPtr]$_) })
  if ($unexpected.Count -gt 0) { P ("cleanup: $($unexpected.Count) unexpected new window(s) remain on the temporary desktop; leaving the desktop open: " + ($unexpected -join ",")) }
  # 3. close the desktops this run created (they are the last ones), never the anchor's
  $n1 = DesktopCount
  if ($n1 -gt $n0 -and $unexpected.Count -eq 0) {
    for ($i = 0; $i -lt $n1 + 1; $i++) { Chord 0x27; Start-Sleep -Milliseconds 400 }   # go to the last desktop
    for ($i = 0; $i -lt ($n1 - $n0); $i++) {
      if ([R]::OnCurrent($anchor)) { P "cleanup: reached the anchor's desktop; stopping"; break }
      Chord 0x73 # F4 with Win+Ctrl: close the current desktop (ours: empty now)
      Start-Sleep -Milliseconds 900
    }
  }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not [R]::OnCurrent($anchor) -and $sw.ElapsedMilliseconds -lt 6000) { Chord 0x25; Start-Sleep -Milliseconds 500 }
  P "back on the original desktop: $([R]::OnCurrent($anchor)); desktops now $(DesktopCount) (were $n0)"
  [System.Windows.Forms.Cursor]::Position = $cursor0
  # 4. did anything of the user's change?
  $after = Snapshot
  $diff = @()
  foreach ($k in $before.Keys) {
    if (-not $after.ContainsKey($k)) { $diff += "gone: $k" }
    elseif ($after[$k] -ne $before[$k]) { $diff += "changed: $k  $($before[$k])  ->  $($after[$k])" }
  }
  $diff | ConvertTo-Json | Out-File -Encoding utf8 (Join-Path $Out "safety.json")
  P ("safety: " + $(if ($diff.Count -eq 0) { "none of the user's $($before.Count) windows changed" } else { "$($diff.Count) of the user's windows differ: " + ($diff -join " | ") }))
  $res = Join-Path $Out "contract-results.json"
  $summary = if (Test-Path $res) {
    $r = Get-Content $res -Raw | ConvertFrom-Json
    "PASS=" + @($r | Where-Object status -eq 'PASS').Count + " FAIL=" + @($r | Where-Object status -eq 'FAIL').Count + " INFO=" + @($r | Where-Object status -eq 'INFO').Count
  } else { "no results file" }
  "$summary; contract exit=$exit; desktops $n0 -> $(DesktopCount); user windows changed: $($diff.Count)" | Out-File -Encoding utf8 (Join-Path $Out "summary.txt")
  P "done: $summary"
}
