# Contract tests for the xtile adapter on a REAL Jwno (ADR 0010, stage 2).  Hosted Windows Server only:
# a pass here is not a pass on a user's Windows 10/11 desktop.
# Every check records PASS / FAIL / INFO with the evidence; FAIL makes the script exit 1.
param([string]$Jwno, [string]$RepoRoot, [string]$Config, [string]$Out = "spike-out")
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
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
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
  [void][C]::SetForegroundWindow($h)
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
  for ($i = 1; $i -le 20; $i++) { MouseTo ($pt[0] + [int]($dx * $i / 20)) ($pt[1] + [int]($dy * $i / 20)); Start-Sleep -Milliseconds 40 }
  Start-Sleep -Milliseconds 200; MouseUp; Start-Sleep -Milliseconds 300
}
function FocusConfirmed($h, $id) {
  for ($try = 0; $try -lt 4; $try++) {
    Focus $h
    if (WaitFor { (State).os_focus -eq $id } 3) { return $true }
  }
  return $false
}
function Launch() { $p = Start-Process notepad -PassThru; Start-Sleep 3; $p.Refresh(); $p }
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
function Cmd($c) { (& $Jwno -x $c 2>&1 | Out-String).Trim() }
function Count($pattern) { @(LogLines | Where-Object { $_ -match $pattern }).Count }

# ---- 0. a window that exists BEFORE Jwno starts ----
$N0 = Launch; $i0 = Id $N0

$jargs = @("--mod-path", $RepoRoot, "--config", $Config, "--log-file", (Join-Path $Out "contract-jwno.log"),
           "--log-level", "debug", "--no-console", "--repl", "127.0.0.1:9999")
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
  $h1 = $N1.MainWindowHandle
  $h2 = $N2.MainWindowHandle
  $want = (Win $i2).rect
  if (-not $want) { Check "CT-6x" "FAIL" "the window used for the move/refresh checks is tiled" ((Win $i2) | ConvertTo-Json -Compress) }
  # The adapter now also puts back windows that moved without a drag (D9), within the 2s poll -- but it
  # never compares while a mouse button is down. Hold one (on the taskbar's empty part) so the poll cannot
  # interleave, and this check measures only what Jwno's own retile does.
  MouseTo 1010 757; Start-Sleep -Milliseconds 300; MouseDown
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

  $pre = Win $i2
  Check "CT-7pre" ($(if ($pre -and $pre.floating -eq $false) { "PASS" } else { "FAIL" })) "precondition: the window we are about to maximise is still a tile" ($pre | ConvertTo-Json -Compress)
  # ---- maximize: the user's own action floats the tile (ADR 0010 D9 N3); it is not shrunk back ----
  [void][C]::ShowWindow($h2, 3)
  $okf = WaitFor { (Win $i2).floating -eq $true } 8
  $z = [C]::IsZoomed($h2)
  Check "CT-7a" ($(if ($okf -and $z) { "PASS" } else { "FAIL" })) "a window the user maximised becomes floating within the poll, and stays maximised" "floating=$okf zoomed=$z"
  [void](Cmd "retile"); Start-Sleep 2
  Check "CT-7b" "INFO" "Jwno's :retile on that floating, maximised window (its transform always un-maximises)" ("zoomed after retile=" + [C]::IsZoomed($h2))
  [void][C]::ShowWindow($h2, 9); Start-Sleep 1
  $foc = FocusConfirmed $h2 $i2
  if ($foc) {
    [void](Cmd ":xtile :toggle-float")
    $back = WaitFor { (Win $i2).floating -eq $false } 6
    Start-Sleep 2
    $f = Frame $h2; $want = (Win $i2).rect
    $d = 0; if ($want) { for ($k = 0; $k -lt 4; $k++) { $d = [math]::Max($d, [math]::Abs($f[$k] - $want[$k])) } } else { $d = 999 }
    Check "CT-7c" ($(if ($back -and $d -le 1) { "PASS" } else { "FAIL" })) "toggle-float puts it back into the tiling at the core's rect" ("floating=" + (Win $i2).floating + " frame=" + ($f -join ",") + " want=" + ($want -join ","))
  } else {
    Check "CT-7c" "FAIL" "toggle-float puts it back into the tiling (precondition: focus reached the window)" ("os_focus=" + (State).os_focus + " want=$i2")
  }

  # ---- the user's mouse: a title-bar click floats nothing, a drag floats the tile where it was dropped ----
  $h0 = $N0.MainWindowHandle
  $w0 = (Win $i0).rect
  ClickTitleBar $h0
  Start-Sleep 3
  Check "CT-17a" ($(if ((Win $i0).floating -eq $false) { "PASS" } else { "FAIL" })) "pressing a title bar and letting go without moving floats nothing" ("floating=" + (Win $i0).floating)
  $before = Frame $h1
  $drags0 = Count ("window-dragged id=" + $i1)
  DragTitleBar $h1 -200 160
  $okd = WaitFor { (Win $i1).floating -eq $true } 6
  Start-Sleep 2
  $after = Frame $h1
  $moved = ([math]::Abs($after[0] - $before[0]) -gt 40) -or ([math]::Abs($after[1] - $before[1]) -gt 40)
  Check "CT-17b" ($(if ($okd) { "PASS" } else { "FAIL" })) "dragging a tile floats it" ("floating=$okd")
  Check "CT-17c" ($(if ($moved) { "PASS" } else { "FAIL" })) "... and it stays where it was dropped (is not pulled back)" ("frame before=" + ($before -join ",") + " after=" + ($after -join ","))
  $nd = (Count ("window-dragged id=" + $i1)) - $drags0
  Check "CT-17d" ($(if ($nd -eq 1) { "PASS" } else { "FAIL" })) "exactly one window-dragged reaches the core for one drag (none while dragging)" "count=$nd"
  $s = State; $worst = 0; $diffs = @()
  foreach ($w in $s.windows) { if ($w.rect -and -not $w.floating) {
    $f = Frame ([IntPtr]::new([int64]$w.id)); $d = 0
    for ($k = 0; $k -lt 4; $k++) { $d = [math]::Max($d, [math]::Abs($f[$k] - $w.rect[$k])) }
    $worst = [math]::Max($worst, $d); $diffs += ("{0}: core=[{1}] actual=[{2}]" -f $w.id, ($w.rect -join ","), ($f -join ",")) } }
  Check "CT-17e" ($(if ($worst -le 1 -and $diffs.Count -gt 0) { "PASS" } else { "FAIL" })) "the remaining tiles were re-tiled around it (worst diff $worst px)" ($diffs -join " | ")
  [void](FocusConfirmed $h1 $i1)
  [void](Cmd ":xtile :toggle-float")
  $back = WaitFor { (Win $i1).floating -eq $false } 6
  Start-Sleep 2
  $f = Frame $h1; $want = (Win $i1).rect
  $d = 0; if ($want) { for ($k = 0; $k -lt 4; $k++) { $d = [math]::Max($d, [math]::Abs($f[$k] - $want[$k])) } } else { $d = 999 }
  Check "CT-17f" ($(if ($back -and $d -le 1) { "PASS" } else { "FAIL" })) "toggle-float returns the dragged window to the tiling" ("frame=" + ($f -join ",") + " want=" + ($want -join ","))

  # ---- polling: minimize / restore reach the core ----
  $h1 = $N1.MainWindowHandle
  [void][C]::ShowWindow($h1, 6)
  Check "CT-8" ($(if (WaitFor { -not (Has $i1) } 10) { "PASS" } else { "FAIL" })) "a minimized window leaves the core within the poll interval" "id=$i1"
  [void][C]::ShowWindow($h1, 9)
  Check "CT-8b" ($(if (WaitFor { Has $i1 } 10) { "PASS" } else { "FAIL" })) "a restored window returns to the core" "id=$i1"
  Start-Sleep 3

  # ---- focus: observation and the adapter's :focus ----
  Focus $h2
  Check "CT-9" ($(if (WaitFor { (State).os_focus -eq $i2 } 6) { "PASS" } else { "FAIL" })) "the OS focus reaches the core with the same id (GA_ROOT-normalised)" ("os_focus=" + (State).os_focus + " want=$i2")
  $leaf0 = Count 'leaf-set-focus-to-hwnd'
  [void](Cmd ":xtile :focus-next"); Start-Sleep 2
  $fg = [C]::GetForegroundWindow().ToInt64()
  Check "CT-10" ($(if ($fg -ne $i2 -and @($i0,$i1,$i2) -contains $fg) { "PASS" } else { "FAIL" })) "a core command (focus-next) moves the real focus through the adapter's :focus" "fg=$fg was=$i2"
  Check "CT-10b" ($(if ((Count 'leaf-set-focus-to-hwnd') -gt $leaf0) { "PASS" } else { "FAIL" })) "... and it goes through Jwno's window :set-focus (not suppressed)" "leaf calls $leaf0 -> $(Count 'leaf-set-focus-to-hwnd')"
  $fgBefore = [C]::GetForegroundWindow().ToInt64()
  $r = Cmd ":enum-window-in-frame :next"; Start-Sleep 2
  Check "CT-11" "INFO" "a Jwno built-in focus command still works while A is active" ("fg $fgBefore -> " + [C]::GetForegroundWindow().ToInt64() + " [client: $r]")

  # ---- virtual desktops: tags, current, and A ----
  Focus $h2; Start-Sleep 1
  Chord 0x44   # Win+Ctrl+D: new desktop 2, switch to it
  Check "CT-12a" ($(if (WaitFor { (State).current -eq "2" } 8) { "PASS" } else { "FAIL" })) "switching to a new desktop makes the core's current workspace 2" ("current=" + (State).current)
  $N3 = Launch; $i3 = Id $N3
  $ok = WaitFor { (Has $i3) -and ((Win $i3).tag -eq "2") } 10
  Check "CT-12b" ($(if ($ok) { "PASS" } else { "FAIL" })) "a window opened on desktop 2 is tagged 2" ("win=" + ((Win $i3) | ConvertTo-Json -Compress))
  $leaf1 = Count 'leaf-set-focus-to-hwnd'; $supp1 = Count 'suppressed Jwno'; $pf1 = Count 'port-focus'
  Chord 0x25   # Win+Ctrl+Left: back to desktop 1
  $ok = WaitFor { (State).current -eq "1" } 8
  Check "CT-12c" ($(if ($ok) { "PASS" } else { "FAIL" })) "switching back makes the core's current workspace 1" ("current=" + (State).current)
  Start-Sleep 2
  $leaf2 = Count 'leaf-set-focus-to-hwnd'; $supp2 = Count 'suppressed Jwno'; $pf2 = Count 'port-focus'
  $own = $leaf2 - $leaf1 - ($pf2 - $pf1)
  Check "CT-13a" ($(if ($own -le 0) { "PASS" } else { "FAIL" })) "A: Jwno does not refocus after the desktop switch (leaf focus calls not explained by the adapter's own :focus)" "leaf $leaf1 -> $leaf2, adapter :focus $pf1 -> $pf2 (new windows may legitimately take focus)"
  Check "CT-13b" ($(if (($supp2 - $supp1) -eq 1) { "PASS" } else { "FAIL" })) "A: exactly one wm :set-focus was swallowed by that switch" "suppressed $supp1 -> $supp2"
  $t1 = (Win $i1).tag; $t2 = (Win $i2).tag
  Check "CT-14" ($(if ($t1 -eq "1" -and $t2 -eq "1" -and (Has $i3) -and (Win $i3).tag -eq "2") { "PASS" } else { "FAIL" })) "the desktop round trip kept every window's workspace (and desktop 2's window is still known)" "tags: n1=$t1 n2=$t2 n3=$((Win $i3).tag)"
  $before = Frame $h0
  DragTitleBar $h0 -150 120
  Check "CT-17g" ($(if (WaitFor { (Win $i0).floating -eq $true } 6) { "PASS" } else { "FAIL" })) "after a virtual-desktop round trip the move hook still works" ("floating=" + (Win $i0).floating)
  Check "CT-16" ($(if ((Count 'skipped a window') -eq 0) { "PASS" } else { "FAIL" })) "the poll never drops a window because reading its facts failed" ((LogLines | Where-Object { $_ -match 'skipped a window' } | Select-Object -First 2) -join " | ")
  Check "CT-15" "INFO" "foreground after returning (the OS's own choice, since Jwno's refocus is suppressed)" ("fg=" + [C]::GetForegroundWindow().ToInt64() + " ids=$i0,$i1,$i2,$i3")
}

foreach ($p in @($N0, $N1, $N2, $N3)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
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
