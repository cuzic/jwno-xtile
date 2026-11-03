# Contract tests for the xtile adapter on a REAL Jwno (ADR 0010, stage 2).  Hosted Windows Server only:
# a pass here is not a pass on a user's Windows 10/11 desktop.
# Every check records PASS / FAIL / INFO with the evidence; FAIL makes the script exit 1.
param([string]$Jwno, [string]$RepoRoot, [string]$Config, [string]$Out = "spike-out",
      # clipwire's own server listens on 9999 on the real machine: Jwno's REPL must not collide with it
      [int]$ReplPort = 9999)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$log = Join-Path $Out "contract.log"
$env:CONTRACT_OUT = $log
$results = New-Object System.Collections.ArrayList

Add-Type -AssemblyName System.Windows.Forms
$script:scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
public static class C {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  public static System.Collections.Generic.List<long> TopLevel() {
    var l = new System.Collections.Generic.List<long>();
    EnumWindows((h, _) => { if (IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && (GetWindowLong(h, -20) & 0x80) == 0) l.Add(h.ToInt64()); return true; }, IntPtr.Zero);
    return l; }
  public static string ClassOf(long h) { var c = new System.Text.StringBuilder(100); GetClassName((IntPtr)h, c, 100); return c.ToString(); }
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int sz);
}
"@

function Now { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 }
function Check($id, $status, $what, $detail) {
  [void]$results.Add([pscustomobject]@{ id = $id; status = $status; what = $what; detail = "$detail" })
  Write-Host ("[{0}] {1}  {2}  -- {3}" -f $status, $id, $what, $detail)
}
function Chord([byte]$vk) {
  foreach ($k in 0x5B, 0x11, $vk) { [C]::keybd_event($k, 0, 0, [UIntPtr]::Zero) }
  foreach ($k in $vk, 0x11, 0x5B) { [C]::keybd_event($k, 0, 2, [UIntPtr]::Zero) }
}
function Focus($h) {
  [C]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [C]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  # Attach to the foreground window's input queue first: that is the documented way past the foreground lock.
  [uint32]$pid0 = 0
  $t1 = [C]::GetWindowThreadProcessId([C]::GetForegroundWindow(), [ref]$pid0); $t2 = [C]::GetCurrentThreadId()
  $att = ($t1 -ne 0 -and $t1 -ne $t2) -and [C]::AttachThreadInput($t2, $t1, $true)
  [void][C]::BringWindowToTop($h)
  $script:lastSet = [C]::SetForegroundWindow($h)
  if ($att) { [void][C]::AttachThreadInput($t2, $t1, $false) }
}
function FgInfo() {
  [uint32]$p = 0; [void][C]::GetWindowThreadProcessId([C]::GetForegroundWindow(), [ref]$p)
  $n = (Get-Process -Id $p -ErrorAction SilentlyContinue).ProcessName
  "setfg=$($script:lastSet) fg-process=$n(pid $p) elevated=$([bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
}
function Frame($h) {
  $e = New-Object RECT
  [void][C]::DwmGetWindowAttribute($h, 9, [ref]$e, 16)
  @($e.L, $e.T, ($e.R - $e.L), ($e.B - $e.T))
}
# SetCursorPos only moves the cursor: it does not produce the mouse-move input a modal move loop waits
# for (a drag moved the window by a few pixels, or not at all). Absolute mouse_event does.
function MouseTo($x, $y) {
  $ax = [int]($x * 65535 / [math]::Max(1, $script:scr.Width - 1)); $ay = [int]($y * 65535 / [math]::Max(1, $script:scr.Height - 1))
  [C]::mouse_event(0x8001, $ax, $ay, 0, [UIntPtr]::Zero)   # MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE
}
function MouseDown() { [C]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) }
function MouseUp() { [C]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) }
function TitleBarPoint($h) { $f = Frame $h; @(($f[0] + [int]($f[2] / 2)), ($f[1] + 14)) }
function ClickTitleBar($h) {
  $pt = TitleBarPoint $h
  MouseTo $pt[0] $pt[1]; Start-Sleep -Milliseconds 300
  MouseDown; Start-Sleep -Milliseconds 250; MouseUp; Start-Sleep -Milliseconds 300
}
function DragTitleBar($h, $dx, $dy) {
  $pt = TitleBarPoint $h
  MouseTo $pt[0] $pt[1]; Start-Sleep -Milliseconds 300
  MouseDown; Start-Sleep -Milliseconds 300
  # first cross the drag threshold with small, slow steps (a synthetic drag sometimes ends without moving anything)
  foreach ($k in 1, 2, 3, 4) { MouseTo ($pt[0] + 3 * $k * [math]::Sign($dx)) ($pt[1] + 3 * $k * [math]::Sign($dy)); Start-Sleep -Milliseconds 120 }
  for ($i = 1; $i -le 30; $i++) { MouseTo ($pt[0] + [int]($dx * $i / 30)) ($pt[1] + [int]($dy * $i / 30)); Start-Sleep -Milliseconds 60 }
  Start-Sleep -Milliseconds 200; MouseUp; Start-Sleep -Milliseconds 300
}
function FocusConfirmed($h, $id) {
  for ($try = 0; $try -lt 4; $try++) {
    # SetForegroundWindow is sometimes refused on the hosted runner (foreground lock); a real click on the
    # title bar always gives the window the foreground, so use it from the third try on.
    if ($try -ge 2) { ClickTitleBar $h } else { Focus $h }
    if (WaitFor { (State).os_focus -eq $id } 3) { return $true }
  }
  return $false
}
function StartJwno() {
  $jargs = @("--mod-path", $RepoRoot, "--config", $Config, "--log-file", (Join-Path $Out "contract-jwno.log"),
             "--log-level", "debug", "--no-console", "--repl", "127.0.0.1:$ReplPort")
  $before = Count ' started'
  $p = Start-Process -FilePath $Jwno -ArgumentList $jargs -PassThru
  [void](WaitFor { (Count ' started') -gt $before } 25)
  $p
}
function Parked($id) { $f = Frame ([IntPtr]::new([int64]$id)); $f[0] -lt -30000 }
function SameFrame($id, $rect) {
  $f = Frame ([IntPtr]::new([int64]$id)); $d = 0
  if (-not $rect) { return $false }
  for ($k = 0; $k -lt 4; $k++) { $d = [math]::Max($d, [math]::Abs($f[$k] - $rect[$k])) }
  $d -le 1
}
# The packaged Notepad of Windows 11 hosts every window in ONE process, and the process we start exits at once:
# its MainWindowHandle is 0 and killing it would kill the user's own Notepad. So a window is found by what is NEW on
# screen, and closed with WM_CLOSE (the windows here are empty, so nothing is asked).
function Launch() {
  $known = New-Object 'System.Collections.Generic.HashSet[long]'
  foreach ($h in [C]::TopLevel()) { [void]$known.Add($h) }
  $null = Start-Process notepad
  $hwnd = 0
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline -and -not $hwnd) {
    $new = @([C]::TopLevel() | Where-Object { -not $known.Contains($_) -and ([C]::ClassOf($_) -eq 'Notepad') })
    if ($new.Count -ge 1) { $hwnd = $new[0] } else { Start-Sleep -Milliseconds 200 }
  }
  Start-Sleep 2
  $o = [pscustomobject]@{ MainWindowHandle = [IntPtr]$hwnd; Hwnd = $hwnd }
  $o | Add-Member -MemberType ScriptProperty -Name HasExited -Value { -not [C]::IsWindow($this.MainWindowHandle) }
  $o
}
function CloseWin($p) { if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { [void][C]::PostMessage($p.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) } }
function Id($p) { $p.MainWindowHandle.ToInt64() }
function LogLines() { if (Test-Path $log) { @(Get-Content $log) } else { @() } }
function State() {
  $l = LogLines | Where-Object { $_ -match ' STATE ' } | Select-Object -Last 1
  if ($l) { try { ($l -replace '^\S+ STATE ', '') | ConvertFrom-Json } catch { $null } }
}
function WaitFor([scriptblock]$pred, [int]$sec = 10) {
  $until = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $until) { if (& $pred) { return $true }; Start-Sleep -Milliseconds 300 }
  return [bool](& $pred)
}
function Has($id) { $s = State; [bool]($s -and ($s.windows | Where-Object { $_.id -eq $id })) }
function Win($id) { $s = State; if ($s) { $s.windows | Where-Object { $_.id -eq $id } | Select-Object -First 1 } }
function Cmd($c) { (& $Jwno --repl "127.0.0.1:$ReplPort" -x $c 2>&1 | Out-String).Trim() }
function Count($pattern) { @(LogLines | Where-Object { $_ -match $pattern }).Count }

# ---- 0. a window that exists BEFORE Jwno starts ----
$N0 = Launch; $i0 = Id $N0
# Packaged apps (Windows 11 Notepad) show up in the UI Automation tree a little after their window exists; Jwno's start-up scan
# only sees what is there (real run 3: N0 was missed). Give it time, so CT-3 measures the adapter and not that lag.
Start-Sleep -Seconds 2
# The window that has the focus when Jwno starts is the only one Jwno itself manages (real run 3). N0 must NOT be it.
$NB = Launch

$jargs = @("--mod-path", $RepoRoot, "--config", $Config, "--log-file", (Join-Path $Out "contract-jwno.log"),
           "--log-level", "debug", "--no-console", "--repl", "127.0.0.1:$ReplPort")
$j = Start-Process -FilePath $Jwno -ArgumentList $jargs -PassThru
$started = WaitFor { (Count ' started') -gt 0 -or (Count 'import-error|install-error|start-error') -gt 0 } 25
$imports = @(LogLines | Where-Object { $_ -match 'import-error|install-error|start-error' })
Check "CT-1" ($(if ($started -and $imports.Count -eq 0 -and (Count ' installed') -gt 0) { "PASS" } else { "FAIL" })) `
  "the adapter loads into Jwno (module path resolution, install, start)" ($imports -join " | ")
if ($j.HasExited -or $imports.Count -gt 0 -or -not $started) {
  Write-Host "adapter did not start; skipping the rest"
} else {
  $binds = @(LogLines | Where-Object { $_ -match 'could not bind|binding rejected' })
  Check "CT-1b" ($(if ($binds.Count -eq 0) { "PASS" } else { "FAIL" })) "every default key binding is accepted by Jwno's key parser" ($binds -join " | ")
  $inst = (LogLines | Where-Object { $_ -match ' installed ' } | Select-Object -First 1)
  Check "CT-2" ($(if ($inst -match 'true') { "PASS" } else { "FAIL" })) "self-diagnosis: both focus wrappers are in place (A active)" $inst

  # ---- C7 / ids: existing + new windows, ids == hwnd (GA_ROOT) ----
  Check "CT-3" ($(if (WaitFor { Has $i0 } 12) { "PASS" } else { "FAIL" })) "a window that existed before Jwno started reaches the core, with id == its hwnd" "hwnd=$i0"
  CloseWin $NB
    $N1 = Launch; $N2 = Launch; $i1 = Id $N1; $i2 = Id $N2
  $ok = (WaitFor { (Has $i1) -and (Has $i2) } 12)
  Check "CT-4" ($(if ($ok) { "PASS" } else { "FAIL" })) "new windows reach the core as :window-seen, tag 1" ("ids=$i0,$i1,$i2 state=" + ((State).windows | ConvertTo-Json -Compress))
  Start-Sleep 3

  # ---- place: the real window ends up where the core says (DWM visible frame) ----
  $s = State; $worst = 0; $diffs = @()
  foreach ($w in $s.windows) {
    if ($w.rect) {
      $hwnd = [IntPtr]::new([int64]$w.id)
      $f = Frame $hwnd
      $d = 0; for ($k = 0; $k -lt 4; $k++) { $d = [math]::Max($d, [math]::Abs($f[$k] - $w.rect[$k])) }
      $worst = [math]::Max($worst, $d)
      $diffs += ("{0}: core=[{1}] actual=[{2}]" -f $w.id, ($w.rect -join ","), ($f -join ","))
    }
  }
  $tiled = @($s.windows | Where-Object { $_.rect }).Count
  if ($tiled -eq 0) { $worst = 999; $diffs = @("no window is tiled: " + ($s.windows | ConvertTo-Json -Compress)) }
  Check "CT-5" ($(if ($worst -le 1) { "PASS" } else { "FAIL" })) "place puts each window's visible frame on the core's rect (worst diff $worst px)" ($diffs -join " | ")
  $mm = Count 'place mismatch'
  Check "CT-5b" "INFO" "read-back mismatches logged by the adapter during the placements above" "count=$mm"

  # ---- swp-flags: Jwno's own retile no longer moves pinned windows ----
  $before = @{}; foreach ($w in $s.windows) { if ($w.rect) { $before[$w.id] = (Frame ([IntPtr]::new([int64]$w.id))) -join "," } }
  $r = Cmd "retile"
  Start-Sleep 2
  $moved = @(); foreach ($k in $before.Keys) { $now = (Frame ([IntPtr]::new([int64]$k))) -join ","; if ($now -ne $before[$k]) { $moved += "$k $($before[$k]) -> $now" } }
  Check "CT-6" ($(if ($moved.Count -eq 0) { "PASS" } else { "FAIL" })) "Jwno's :retile does not move windows pinned with :swp-flags" (($moved -join " | ") + " [client: $r]")

  # a manual move survives Jwno's retile, and the core's :refresh brings it back
  $h0 = $N0.MainWindowHandle
  $h1 = $N1.MainWindowHandle
  $h2 = $N2.MainWindowHandle
  $want = (Win $i2).rect
  if (-not $want) { Check "CT-6x" "FAIL" "the window used for the move/refresh checks is tiled" ((Win $i2) | ConvertTo-Json -Compress) }
  # The adapter now also puts back windows that moved without a drag (D9), within the 2s poll -- but it
  # never compares while a mouse button is down. Hold one (inside a notepad) so the poll cannot
  # interleave, and this check measures only what Jwno's own retile does.
  # hold the button inside a notepad (a harmless click in its text area), whatever the screen size is
  $hp = TitleBarPoint $h0; MouseTo $hp[0] ($hp[1] + 120); Start-Sleep -Milliseconds 300; MouseDown
  [void][C]::SetWindowPos($h2, [IntPtr]::Zero, 30, 30, 400, 300, 0x0004)
  Start-Sleep -Milliseconds 400; [void](Cmd "retile"); Start-Sleep -Milliseconds 800
  $f = Frame $h2
  MouseUp
  Check "CT-6b" ($(if ($f[2] -le 420 -and $f[3] -le 320) { "PASS" } else { "FAIL" })) "after a programmatic move, Jwno's retile leaves the window where it was put (the poll is held off by a pressed button)" ("frame=" + ($f -join ","))
  # the button is up now: the next poll's placement comparison puts the window back (ADR 0010 D9)
  $backed = WaitFor {
    $f = Frame $h2; $d = 0
    if ($want) { for ($k = 0; $k -lt 4; $k++) { $d = [math]::Max($d, [math]::Abs($f[$k] - $want[$k])) } } else { $d = 999 }
    $d -le 1 } 8
  Check "CT-6c" ($(if ($want -and $backed) { "PASS" } else { "FAIL" })) "with no button down, the poll puts a window that was moved programmatically back at the core's rect" ("frame=" + ((Frame $h2) -join ",") + " want=" + ($want -join ","))

  # A throwaway window, so that whatever this does to the layout cannot leak into the checks after it.
  $N6 = Launch; $i6 = Id $N6; $h6 = $N6.MainWindowHandle
  [void](WaitFor { Has $i6 } 10)
  Start-Sleep 2
  $pre = Win $i6
  Check "CT-7pre" ($(if ($pre -and $pre.floating -eq $false) { "PASS" } else { "FAIL" })) "precondition: the window we are about to maximise is a tile" ($pre | ConvertTo-Json -Compress)
  [void][C]::ShowWindow($h6, 3)
  $okf = WaitFor { (Win $i6).floating -eq $true } 8
  $z = [C]::IsZoomed($h6)
  Check "CT-7a" ($(if ($okf -and $z) { "PASS" } else { "FAIL" })) "a window the user maximised becomes floating within the poll, and stays maximised" "floating=$okf zoomed=$z"
  [void](Cmd "retile"); Start-Sleep 2
  Check "CT-7b" "INFO" "Jwno's :retile on that floating, maximised window (its transform always un-maximises)" ("zoomed after retile=" + [C]::IsZoomed($h6))
  [void][C]::ShowWindow($h6, 9); Start-Sleep 1
  if (FocusConfirmed $h6 $i6) {
    [void](Cmd ":xtile :toggle-float")
    $back = WaitFor { (Win $i6).floating -eq $false } 6
    Start-Sleep 2
    $f = Frame $h6; $want = (Win $i6).rect
    $d = 0; if ($want) { for ($k = 0; $k -lt 4; $k++) { $d = [math]::Max($d, [math]::Abs($f[$k] - $want[$k])) } } else { $d = 999 }
    Check "CT-7c" ($(if ($back -and $d -le 1) { "PASS" } else { "FAIL" })) "toggle-float puts it back into the tiling at the core's rect" ("floating=" + (Win $i6).floating + " frame=" + ($f -join ",") + " want=" + ($want -join ","))
  } else {
    Check "CT-7c" "FAIL" "toggle-float puts it back into the tiling (precondition: focus reached the window)" ("os_focus=" + (State).os_focus + " want=$i6")
  }
  CloseWin $N6
  Check "CT-7d" ($(if (WaitFor { -not (Has $i6) } 10) { "PASS" } else { "FAIL" })) "the throwaway window leaves the core when it is closed" "id=$i6"
  Start-Sleep 3

  # ---- the user's mouse: a title-bar click floats nothing, a drag floats the tile where it was dropped ----
  $h0 = $N0.MainWindowHandle
  $w0 = (Win $i0).rect
  ClickTitleBar $h0
  Start-Sleep 3
  Check "CT-17a" ($(if ((Win $i0).floating -eq $false) { "PASS" } else { "FAIL" })) "pressing a title bar and letting go without moving floats nothing" ("floating=" + (Win $i0).floating)
  $before = Frame $h1
  $drags0 = Count ("window-dragged id=" + $i1)
  $attempts = 0; $okd = $false; $moved = $false
  while ($attempts -lt 3 -and -not $okd) {
    $attempts++
    DragTitleBar $h1 -200 160
    $okd = WaitFor { (Win $i1).floating -eq $true } 5
  }
  Start-Sleep 2
  $after = Frame $h1
  # The synthetic drag moves the window by far less than the cursor travelled (and sometimes not at all), so the
  # question is not "how far" but "did it end up somewhere else, and does it stay there".
  $moved = ([math]::Abs($after[0] - $before[0]) -gt 4) -or ([math]::Abs($after[1] - $before[1]) -gt 4)
  Start-Sleep 3
  $later = Frame $h1
  $stays = (($later -join ",") -eq ($after -join ","))
  Check "CT-17b" ($(if ($okd) { "PASS" } else { "FAIL" })) "dragging a tile floats it" ("floating=$okd after $attempts attempt(s)")
  Check "CT-17c" ($(if ($moved -and $stays) { "PASS" } else { "FAIL" })) "... and it stays where it was dropped (is not pulled back, even after a poll)" ("frame before=" + ($before -join ",") + " after=" + ($after -join ",") + " 3s later=" + ($later -join ","))
  $nd = (Count ("window-dragged id=" + $i1)) - $drags0
  Check "CT-17d" ($(if ($nd -eq $attempts) { "PASS" } else { "FAIL" })) "exactly one window-dragged reaches the core per drag (none while dragging)" "events=$nd attempts=$attempts"
  $s = State; $worst = 0; $diffs = @()
  foreach ($w in $s.windows) { if ($w.rect -and -not $w.floating) {
    $f = Frame ([IntPtr]::new([int64]$w.id)); $d = 0
    for ($k = 0; $k -lt 4; $k++) { $d = [math]::Max($d, [math]::Abs($f[$k] - $w.rect[$k])) }
    $worst = [math]::Max($worst, $d); $diffs += ("{0}: core=[{1}] actual=[{2}]" -f $w.id, ($w.rect -join ","), ($f -join ",")) } }
  Check "CT-17e" ($(if ($worst -le 1 -and $diffs.Count -gt 0) { "PASS" } else { "FAIL" })) "the remaining tiles were re-tiled around it (worst diff $worst px)" ($diffs -join " | ")
  if (FocusConfirmed $h1 $i1) {
    [void](Cmd ":xtile :toggle-float")
    $back = WaitFor { (Win $i1).floating -eq $false } 6
    Start-Sleep 2
    $f = Frame $h1; $want = (Win $i1).rect
    $d = 0; if ($want) { for ($k = 0; $k -lt 4; $k++) { $d = [math]::Max($d, [math]::Abs($f[$k] - $want[$k])) } } else { $d = 999 }
    Check "CT-17f" ($(if ($back -and $d -le 1) { "PASS" } else { "FAIL" })) "toggle-float returns the dragged window to the tiling" ("frame=" + ($f -join ",") + " want=" + ($want -join ","))
  } else {
    Check "CT-17f" "FAIL" "toggle-float returns the dragged window to the tiling (precondition: focus reached the window)" ("os_focus=" + (State).os_focus + " want=$i1")
  }

  # ---- polling: minimize / restore reach the core ----
  $h1 = $N1.MainWindowHandle
  [void][C]::ShowWindow($h1, 6)
  Check "CT-8" ($(if (WaitFor { -not (Has $i1) } 10) { "PASS" } else { "FAIL" })) "a minimized window leaves the core within the poll interval" "id=$i1"
  [void][C]::ShowWindow($h1, 9)
  Check "CT-8b" ($(if (WaitFor { Has $i1 } 10) { "PASS" } else { "FAIL" })) "a restored window returns to the core" "id=$i1"
  Start-Sleep 3

  # ---- focus: observation and the adapter's :focus ----
  Focus $h2
  Check "CT-9" ($(if (WaitFor { (State).os_focus -eq $i2 } 6) { "PASS" } else { "FAIL" })) "the OS focus reaches the core with the same id (GA_ROOT-normalised)" ("os_focus=" + (State).os_focus + " want=$i2 " + (FgInfo))
  $leaf0 = Count 'leaf-set-focus-to-hwnd'
  [void](Cmd ":xtile :focus-next"); Start-Sleep 2
  $fg = [C]::GetForegroundWindow().ToInt64()
  Check "CT-10" ($(if ($fg -ne $i2 -and (Has $fg)) { "PASS" } else { "FAIL" })) "a core command (focus-next) moves the real focus through the adapter's :focus" "fg=$fg was=$i2"
  Check "CT-10b" ($(if ((Count 'leaf-set-focus-to-hwnd') -gt $leaf0) { "PASS" } else { "FAIL" })) "... and it goes through Jwno's window :set-focus (not suppressed)" "leaf calls $leaf0 -> $(Count 'leaf-set-focus-to-hwnd')"
  $fgBefore = [C]::GetForegroundWindow().ToInt64()
  $r = Cmd ":enum-window-in-frame :next"; Start-Sleep 2
  Check "CT-11" "INFO" "a Jwno built-in focus command still works while A is active" ("fg $fgBefore -> " + [C]::GetForegroundWindow().ToInt64() + " [client: $r]")

  # ---- workspaces (ADR 0006): goto parks the old workspace, send moves a window ----
  Start-Sleep 2
  $s = State
  $tiles = @{}; foreach ($w in $s.windows) { if ($w.rect -and -not $w.floating) { $tiles[$w.id] = $w.rect } }
  Check "CT-20pre" ($(if ($tiles.Count -ge 3) { "PASS" } else { "FAIL" })) "precondition: three tiled windows on workspace 1" ($tiles.Keys -join ",")
  [void](Cmd ":xtile :goto 2")
  Check "CT-20a" ($(if (WaitFor { (Parked $i0) -and (Parked $i1) -and (Parked $i2) } 8) { "PASS" } else { "FAIL" })) "goto 2 parks all of workspace 1 off-screen (they stay windows, in the taskbar)" ("current=" + (State).current + " frames: " + ((@($i0,$i1,$i2) | ForEach-Object { (Frame ([IntPtr]::new([int64]$_))) -join "," }) -join " | "))
  Check "CT-20b" ($(if (WaitFor { (State).current -eq "2" } 4) { "PASS" } else { "FAIL" })) "... and the core is on workspace 2" ("current=" + (State).current)
  $N7 = Launch; $i7 = Id $N7; $h7 = $N7.MainWindowHandle
  $okn = WaitFor { (Has $i7) } 10
  Start-Sleep 2
  Check "CT-20c" ($(if ($okn -and (SameFrame $i7 (Win $i7).rect) -and (Win $i7).rect) { "PASS" } else { "FAIL" })) "a window opened on workspace 2 is tiled there, on screen" ("win=" + ((Win $i7) | ConvertTo-Json -Compress) + " frame=" + ((Frame $h7) -join ","))
  Check "CT-20d" ($(if ((Parked $i0) -and (Parked $i1) -and (Parked $i2)) { "PASS" } else { "FAIL" })) "workspace 1's windows are still parked after the poll (the poll must not drag them back)" ""
  [void](Cmd ":xtile :goto 1")
  $back = WaitFor { (SameFrame $i0 ($tiles[$i0])) -and (SameFrame $i1 ($tiles[$i1])) -and (SameFrame $i2 ($tiles[$i2])) } 8
  Check "CT-20e" ($(if ($back) { "PASS" } else { "FAIL" })) "goto 1 brings workspace 1 back to exactly the tiles it had" ((@($i0,$i1,$i2) | ForEach-Object { (Frame ([IntPtr]::new([int64]$_))) -join "," }) -join " | ")
  Check "CT-20f" ($(if (Parked $i7) { "PASS" } else { "FAIL" })) "... and workspace 2's window is parked" ("frame=" + ((Frame $h7) -join ","))
  # send: the focused window moves to workspace 2
  if (FocusConfirmed $h1 $i1) {
    [void](Cmd ":xtile :send 2")
    $okp = WaitFor { (Parked $i1) -and ((Win $i1).tag -eq "2") } 8
    Start-Sleep 2
    $rest = @($i0, $i2) | Where-Object { Win $_ }
    $fine = ($rest.Count -eq 2) -and (SameFrame $i0 (Win $i0).rect) -and (SameFrame $i2 (Win $i2).rect)
    Check "CT-21a" ($(if ($okp) { "PASS" } else { "FAIL" })) "send 2 moves the focused window to workspace 2 and parks it" ("win=" + ((Win $i1) | ConvertTo-Json -Compress))
    Check "CT-21b" ($(if ($fine) { "PASS" } else { "FAIL" })) "... the remaining windows re-tile to fill the screen" ((@($i0,$i2) | ForEach-Object { (Frame ([IntPtr]::new([int64]$_))) -join "," }) -join " | ")
    [void](Cmd ":xtile :goto 2")
    $both = WaitFor { (-not (Parked $i1)) -and (-not (Parked $i7)) -and (Parked $i0) -and (Parked $i2) } 8
    Start-Sleep 2
    Check "CT-21c" ($(if ($both -and (SameFrame $i1 (Win $i1).rect) -and (SameFrame $i7 (Win $i7).rect)) { "PASS" } else { "FAIL" })) "workspace 2 now shows the window that was sent and the one opened there, tiled" ("n1=" + ((Frame $h1) -join ",") + " n7=" + ((Frame $h7) -join ","))
    [void](Cmd ":xtile :goto 1")
    [void](WaitFor { -not (Parked $i0) } 8)
    Start-Sleep 2
  } else {
    Check "CT-21a" "FAIL" "send 2 (precondition: focus reached the window)" ("os_focus=" + (State).os_focus)
  }

  # ---- an empty workspace holds the OS focus in the sink window, not in a parked window (ADR 0006 D-7) ----
  [void](Cmd ":xtile :goto 5")
  $sunk = WaitFor { [C]::ClassOf([C]::GetForegroundWindow().ToInt64()) -eq "xtile-sink" } 8
  Check "CT-23a" ($(if ($sunk) { "PASS" } else { "FAIL" })) "goto an empty workspace puts the OS focus in the sink window (not in a parked window)" ("foreground class=" + [C]::ClassOf([C]::GetForegroundWindow().ToInt64()) + " " + (FgInfo))
  $sinkOk = (Count 'did not get the foreground') -eq 0
  Check "CT-23b" ($(if ($sinkOk) { "PASS" } else { "INFO" })) "... without the foreground lock refusing the sink" ((LogLines | Where-Object { $_ -match 'did not get the foreground' } | Select-Object -First 1) -join "")
  [void](Cmd ":xtile :goto 1")
  $back1 = WaitFor { -not (Parked $i0) } 8
  Check "CT-23c" ($(if ($back1) { "PASS" } else { "FAIL" })) "goto 1 brings the windows back after the sink was used" ("frame=" + ((Frame ([IntPtr]::new([int64]$i0))) -join ","))
  Start-Sleep 2

  # ---- the taskbar button of a parked window (ADR 0011 stage 0): the calls go through and report S_OK ----
  if ($env:XTILE_NO_HIDE_TAB) {
    Check "CT-24" "INFO" "skipped: run with the default options (no :hide-taskbar-button)" ""
  } else {
  [void](Cmd ":xtile :goto 6")
  Start-Sleep 3
  $tdel = @(LogLines | Where-Object { $_ -match 'taskbar-delete hwnd=.* -> 0' })
  $tfail = @(LogLines | Where-Object { $_ -match 'taskbar-delete hwnd=.* -> (nil|-)' })
  $vis = (@($i0, $i1, $i2) | ForEach-Object { "id=$_ visible=" + [C]::IsWindowVisible([IntPtr]::new([int64]$_)) + " iconic=" + [C]::IsIconic([IntPtr]::new([int64]$_)) }) -join " | "
  Check "CT-24v" "INFO" "state of the parked windows with :hide-taskbar-button (Jwno purges a window that is not visible)" ($vis + " | purges in the Jwno log: " + @(Get-Content (Join-Path $Out "contract-jwno.log") -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Purged [1-9]' }).Count)
  Check "CT-24a" ($(if ($tdel.Count -gt 0) { "PASS" } else { "FAIL" })) "a parked window's taskbar button is taken away through ITaskbarList (DeleteTab returned S_OK)" ("ok=" + $tdel.Count + " failed=" + $tfail.Count)
  [void](Cmd ":xtile :goto 1")
  [void](WaitFor { -not (Parked $i0) } 8)
  $tadd = @(LogLines | Where-Object { $_ -match 'taskbar-add hwnd=.* -> 0' })
  Check "CT-24b" ($(if ($tadd.Count -gt 0) { "PASS" } else { "FAIL" })) "... and given back when the window returns (AddTab returned S_OK)" ("ok=" + $tadd.Count)
  }
  Start-Sleep 2

  # ---- gap and padding (ADR 0013): the visible frame follows the spaced layout, and 0 puts everything back ----
  [void](Cmd ":xtile :set-gap 12"); [void](Cmd ":xtile :set-padding 20")
  Start-Sleep 3
  $sg = State
  $worstG = 0; $diffsG = @()
  foreach ($wn in @($sg.windows | Where-Object { $_.rect -and -not $_.floating })) {
    $fr = Frame ([IntPtr]::new([int64]$wn.id))
    $dd = 0; for ($k = 0; $k -lt 4; $k++) { $dd = [math]::Max($dd, [math]::Abs($fr[$k] - $wn.rect[$k])) }
    $worstG = [math]::Max($worstG, $dd)
    $diffsG += ("{0}: core=[{1}] actual=[{2}]" -f $wn.id, ($wn.rect -join ","), ($fr -join ","))
  }
  Check "CT-25a" ($(if ($worstG -le 1 -and $diffsG.Count -gt 0) { "PASS" } else { "FAIL" })) "with gap 12 and padding 20 each tile's visible frame is on the core's spaced rect (worst diff $worstG px)" ($diffsG -join " | ")
  [void](Cmd ":xtile :set-gap 0"); [void](Cmd ":xtile :set-padding 0")
  Start-Sleep 3
  $sg0 = State
  $worst0 = 0
  foreach ($wn in @($sg0.windows | Where-Object { $_.rect -and -not $_.floating })) {
    $fr = Frame ([IntPtr]::new([int64]$wn.id))
    for ($k = 0; $k -lt 4; $k++) { $worst0 = [math]::Max($worst0, [math]::Abs($fr[$k] - $wn.rect[$k])) }
  }
  Check "CT-25b" ($(if ($worst0 -le 1) { "PASS" } else { "FAIL" })) "gap and padding 0 put the tiles back flush (worst diff $worst0 px)" ""

  # ---- virtual desktops (ADR 0006 D-4): only the current Windows desktop is managed ----
  Focus $h2; Start-Sleep 1
  Chord 0x44   # Win+Ctrl+D: new desktop 2, switch to it
  $gone = WaitFor { -not (Has $i0) -and -not (Has $i2) } 8
  Check "CT-12a" ($(if ($gone) { "PASS" } else { "FAIL" })) "on a new Windows desktop the previous desktop's windows are no longer managed" ("ids in core: " + (((State).windows | ForEach-Object { $_.id }) -join ","))
  # OV-H1: workspace 2's windows (i1, i7) are parked with their taskbar buttons deleted; Windows cannot say which desktop they
  # are on, yet they must not be taken for windows of THIS desktop
  Start-Sleep 3
  Check "CT-12a2" ($(if (-not (Has $i1) -and -not (Has $i7)) { "PASS" } else { "FAIL" })) "parked windows (taskbar button deleted) of desktop 1 are not managed on desktop 2" ("ids in core: " + (((State).windows | ForEach-Object { $_.id }) -join ","))
  $N3 = Launch; $i3 = Id $N3
  $ok = WaitFor { (Has $i3) } 10
  Check "CT-12b" ($(if ($ok) { "PASS" } else { "FAIL" })) "a window opened on that desktop is managed" ("win=" + ((Win $i3) | ConvertTo-Json -Compress))
  $leaf1 = Count 'leaf-set-focus-to-hwnd'; $supp1 = Count 'suppressed Jwno'; $pf1 = Count 'port-focus'
  Chord 0x25   # Win+Ctrl+Left: back to desktop 1
  $ok = WaitFor { (Has $i0) -and (Has $i2) -and (-not (Has $i3)) } 10
  Check "CT-12c" ($(if ($ok) { "PASS" } else { "FAIL" })) "back on desktop 1 its windows are managed again, desktop 2's is not" ("ids in core: " + (((State).windows | ForEach-Object { $_.id }) -join ","))
  Check "CT-12c2" ($(if ((Has $i1) -and (Has $i7)) { "PASS" } else { "INFO" })) "... and the windows parked on workspace 2 are managed again" ("ids in core: " + (((State).windows | ForEach-Object { $_.id }) -join ","))
  Start-Sleep 2
  $leaf2 = Count 'leaf-set-focus-to-hwnd'; $supp2 = Count 'suppressed Jwno'; $pf2 = Count 'port-focus'
  $own = $leaf2 - $leaf1 - ($pf2 - $pf1)
  Check "CT-13a" ($(if ($own -le 0) { "PASS" } else { "FAIL" })) "A: Jwno does not refocus after the desktop switch (leaf focus calls not explained by the adapter's own :focus)" "leaf $leaf1 -> $leaf2, adapter :focus $pf1 -> $pf2 (new windows may legitimately take focus)"
  # Jwno calls wm :set-focus only when its own desktop-name event arrives AND the desktop differs from its last-vd.
# On the real PC (run 5) the event for the new desktop never arrived, so there was nothing to swallow (0): fine.
# What must never happen is more than one swallow per switch, or a refocus that was not swallowed (CT-13a).
Check "CT-13b" ($(if (($supp2 - $supp1) -le 1) { "PASS" } else { "FAIL" })) "A: at most one wm :set-focus was swallowed by that switch (0 when Jwno saw no desktop-name event)" "suppressed $supp1 -> $supp2"
  $okt = WaitFor { (Has $i0) -and (Has $i2) -and (Win $i0).rect -and (SameFrame $i0 (Win $i0).rect) } 8
  Check "CT-14" ($(if ($okt) { "PASS" } else { "FAIL" })) "the windows of desktop 1 are tiled again after the round trip" ("n0=" + ((Frame $h0) -join ",") + " core=" + ((Win $i0).rect -join ","))
  $before = Frame $h0
  DragTitleBar $h0 -150 120
  Check "CT-17g" ($(if (WaitFor { (Win $i0).floating -eq $true } 6) { "PASS" } else { "FAIL" })) "after a virtual-desktop round trip the move hook still works" ("floating=" + (Win $i0).floating)
  Check "CT-16" ($(if ((Count 'skipped a window') -eq 0) { "PASS" } else { "FAIL" })) "the poll never drops a window because reading its facts failed" ((LogLines | Where-Object { $_ -match 'skipped a window' } | Select-Object -First 2) -join " | ")
  Check "CT-15" "INFO" "foreground after returning (the OS's own choice, since Jwno's refocus is suppressed)" ("fg=" + [C]::GetForegroundWindow().ToInt64() + " ids=$i0,$i1,$i2,$i3")
}


if (-not $j.HasExited -and $started) {
  # ---- ADR 0006 H1: nothing is left off-screen behind us ----
  [void](Cmd ":xtile :goto 2")
  [void](WaitFor { (Parked $i0) } 8)
  $wasParked = (Parked $i0)
  $qout = Cmd "quit"
  [void]$j.WaitForExit(30000)
  Start-Sleep 2
  Check "CT-22a" ($(if ($wasParked -and -not (Parked $i0) -and -not (Parked $i2)) { "PASS" } else { "FAIL" })) "quitting Jwno brings every parked window back on screen" ("parked before=$wasParked n0=" + ((Frame $h0) -join ",") + " n2=" + ((Frame $h2) -join ",") + " [client: $qout]")
  Check "CT-22a2" ($(if ($j.HasExited) { "PASS" } else { "FAIL" })) "... and Jwno exits" ("exited=" + $j.HasExited)
  if (-not $j.HasExited) { Stop-Process -Id $j.Id -Force; Start-Sleep 2 }
  # a crash: park again under a fresh Jwno, kill it without a chance to clean up, start another
  $j = StartJwno
  [void](WaitFor { (Has $i0) } 12)
  [void](Cmd ":xtile :goto 2")
  [void](WaitFor { (Parked $i0) } 8)
  $stuck = $false
  Stop-Process -Id $j.Id -Force; Start-Sleep 2
  $stuck = (Parked $i0)
  Check "CT-22b" "INFO" "a killed Jwno leaves the parked windows off-screen (the failure mode that recovery exists for)" "parked after kill=$stuck"
  $j = StartJwno
  $rec = WaitFor { -not (Parked $i0) } 12
  Check "CT-22c" ($(if ($stuck -and $rec) { "PASS" } else { "FAIL" })) "starting Jwno again recovers windows a previous run left off-screen" ("n0=" + ((Frame $h0) -join ",") + " stuck=$stuck")
}
foreach ($p in @($N0, $N1, $N2, $N3, $N6, $N7)) { if ($p -and -not $p.HasExited) { CloseWin $p } }
if (-not $j.HasExited) { Stop-Process -Id $j.Id -Force }

$results | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 (Join-Path $Out "contract-results.json")
Write-Host "===== contract summary ====="
$results | Format-Table id, status, what -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$fail = @($results | Where-Object { $_.status -eq "FAIL" }).Count
Write-Host ("PASS={0} FAIL={1} INFO={2}" -f @($results | Where-Object { $_.status -eq "PASS" }).Count, $fail, @($results | Where-Object { $_.status -eq "INFO" }).Count)
Write-Host "===== last STATE lines ====="
LogLines | Where-Object { $_ -match ' STATE ' } | Select-Object -Last 4 | Write-Host
Write-Host "===== contract log (without STATE lines) ====="
LogLines | Where-Object { $_ -notmatch ' STATE ' } | Where-Object { $_ -notmatch "jw32-has|leaf-set" } | Select-Object -Last 120 | Write-Host
if ($fail -gt 0) { exit 1 }
