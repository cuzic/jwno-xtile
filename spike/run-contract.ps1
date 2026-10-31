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
  $h2 = $N2.MainWindowHandle
  $want = (Win $i2).rect
  [void][C]::SetWindowPos($h2, [IntPtr]::Zero, 30, 30, 400, 300, 0x0004)
  Start-Sleep 1; [void](Cmd "retile"); Start-Sleep 2
  $f = Frame $h2
  Check "CT-6b" ($(if ($f[2] -le 420 -and $f[3] -le 320) { "PASS" } else { "FAIL" })) "after a manual move, Jwno's retile leaves the window where the user put it" ("frame=" + ($f -join ","))
  [void](Cmd ":xtile :refresh"); Start-Sleep 2
  $f = Frame $h2
  $d = 0; for ($k = 0; $k -lt 4; $k++) { $d = [math]::Max($d, [math]::Abs($f[$k] - $want[$k])) }
  Check "CT-6c" ($(if ($d -le 1) { "PASS" } else { "FAIL" })) "the core's :refresh puts it back" ("frame=" + ($f -join ",") + " want=" + ($want -join ","))

  # ---- maximize: Jwno unmaximizes in its transform regardless of swp-flags (source) ----
  [void][C]::ShowWindow($h2, 3); Start-Sleep 1
  $z1 = [C]::IsZoomed($h2)
  [void](Cmd "retile"); Start-Sleep 2
  $z2 = [C]::IsZoomed($h2)
  Check "CT-7" "INFO" "maximized window and Jwno's :retile" "zoomed before=$z1 after=$z2 (source predicts: unmaximized)"
  [void](Cmd ":xtile :refresh"); Start-Sleep 2

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
  $leaf1 = Count 'leaf-set-focus-to-hwnd'; $supp1 = Count 'suppressed Jwno'
  Chord 0x25   # Win+Ctrl+Left: back to desktop 1
  $ok = WaitFor { (State).current -eq "1" } 8
  Check "CT-12c" ($(if ($ok) { "PASS" } else { "FAIL" })) "switching back makes the core's current workspace 1" ("current=" + (State).current)
  Start-Sleep 2
  $leaf2 = Count 'leaf-set-focus-to-hwnd'; $supp2 = Count 'suppressed Jwno'
  Check "CT-13a" ($(if ($leaf2 -eq $leaf1) { "PASS" } else { "FAIL" })) "A: Jwno does not refocus after the desktop switch" "leaf calls $leaf1 -> $leaf2"
  Check "CT-13b" ($(if (($supp2 - $supp1) -eq 1) { "PASS" } else { "FAIL" })) "A: exactly one wm :set-focus was swallowed by that switch" "suppressed $supp1 -> $supp2"
  $t1 = (Win $i1).tag; $t2 = (Win $i2).tag
  Check "CT-14" ($(if ($t1 -eq "1" -and $t2 -eq "1" -and (Has $i3) -and (Win $i3).tag -eq "2") { "PASS" } else { "FAIL" })) "the desktop round trip kept every window's workspace (and desktop 2's window is still known)" "tags: n1=$t1 n2=$t2 n3=$((Win $i3).tag)"
  Check "CT-15" "INFO" "foreground after returning (the OS's own choice, since Jwno's refocus is suppressed)" ("fg=" + [C]::GetForegroundWindow().ToInt64() + " ids=$i0,$i1,$i2,$i3")
}

foreach ($p in @($N0, $N1, $N2, $N3)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
if (-not $j.HasExited) { Stop-Process -Id $j.Id -Force }

$results | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 (Join-Path $Out "contract-results.json")
Write-Host "===== contract summary ====="
$results | Format-Table id, status, what -AutoSize -Wrap | Out-String -Width 200 | Write-Host
$fail = @($results | Where-Object { $_.status -eq "FAIL" }).Count
Write-Host ("PASS={0} FAIL={1} INFO={2}" -f @($results | Where-Object { $_.status -eq "PASS" }).Count, $fail, @($results | Where-Object { $_.status -eq "INFO" }).Count)
Write-Host "===== contract log (without STATE lines) ====="
LogLines | Where-Object { $_ -notmatch ' STATE ' } | Select-Object -Last 80 | Write-Host
if ($fail -gt 0) { exit 1 }
