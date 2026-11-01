# SPIKE for ADR 0006 D-7b: can a window made on Jwno's UI thread hold the OS focus, swallow keys,
# stay alive under Alt+F4, and stay responsive, without the adapter's message pump? Measurements only.
param([string]$Jwno, [string]$RepoRoot, [string]$Config, [string]$Out = "spike-out", [int]$ReplPort = 9999)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$log = Join-Path $Out "sink.log"
Remove-Item $log -ErrorAction SilentlyContinue
$env:SINK_OUT = $log
$results = New-Object System.Collections.ArrayList
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class S {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
"@
function Check($id, $status, $what, $detail) {
  [void]$results.Add([pscustomobject]@{ id = $id; status = $status; what = $what; detail = "$detail" })
  Write-Host ("[{0}] {1}  {2}  -- {3}" -f $status, $id, $what, $detail)
}
function LogLines { if (Test-Path $log) { Get-Content $log } else { @() } }
function Count($p) { @(LogLines | Where-Object { $_ -match $p }).Count }
function WaitFor([scriptblock]$pred, [int]$sec = 10) {
  $until = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $until) { if (& $pred) { return $true }; Start-Sleep -Milliseconds 250 }
  return [bool](& $pred)
}
function Key([byte]$vk) { [S]::keybd_event($vk, 0, 0, [UIntPtr]::Zero); [S]::keybd_event($vk, 0, 2, [UIntPtr]::Zero) }
function Cmd($c) { (& $Jwno --repl "127.0.0.1:$ReplPort" -x $c 2>&1 | Out-String).Trim() }

$jargs = @("--mod-path", $RepoRoot, "--config", $Config, "--log-file", (Join-Path $Out "sink-jwno.log"),
           "--log-level", "debug", "--no-console", "--repl", "127.0.0.1:$ReplPort")
$j = Start-Process -FilePath $Jwno -ArgumentList $jargs -PassThru
$created = WaitFor { (Count 'sink-created') -gt 0 -or (Count 'sink-class-failed|sink-create-failed|create-error') -gt 0 } 25
$line = (LogLines | Where-Object { $_ -match 'sink-created' } | Select-Object -First 1)
Check "SK-1" ($(if ($line) { "PASS" } else { "FAIL" })) "a window can be created on Jwno's UI thread through a custom message" ((LogLines | Where-Object { $_ -match 'sink-|msg-registered|create' }) -join " | ")
if ($line -and $line -match 'sink-created (\d+)') {
  $h = [IntPtr][int64]$Matches[1]
  $ex = [S]::GetWindowLong($h, -20)
  Check "SK-1b" "INFO" "the sink's extended style (0x80 = TOOLWINDOW: not in Alt-Tab or the taskbar)" ("0x{0:X}" -f $ex)

  # SK-2: responds to messages from another process (the UI thread pumps them), no adapter involved
  $r = [IntPtr]::Zero
  $t0 = Get-Date
  $ok = [S]::SendMessageTimeout($h, 0, [IntPtr]::Zero, [IntPtr]::Zero, 2, 2000, [ref]$r)
  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  Check "SK-2" ($(if ($ok -ne [IntPtr]::Zero) { "PASS" } else { "FAIL" })) "the sink answers a message from another process (Jwno has no message pump of the adapter here)" "answered=$($ok -ne [IntPtr]::Zero) in ${ms}ms; IsHungAppWindow=$([S]::IsHungAppWindow($h))"

  # SK-3: it can be brought to the front
  $out = Cmd "(sink-front)"
  $got = WaitFor { [S]::GetForegroundWindow() -eq $h } 3
  Check "SK-3" ($(if ($got) { "PASS" } else { "FAIL" })) "Jwno's own process can make the sink the foreground window" ("repl=$out; log: " + ((LogLines | Where-Object { $_ -match 'sink-front' }) -join " | "))
  if (-not $got) {
    # what the adapter would have to do: the same AttachThreadInput trick as the harness
    [uint32]$p0 = 0
    $t1 = [S]::GetWindowThreadProcessId([S]::GetForegroundWindow(), [ref]$p0); $t2 = [S]::GetCurrentThreadId()
    $att = [S]::AttachThreadInput($t2, $t1, $true); [void][S]::SetForegroundWindow($h); if ($att) { [void][S]::AttachThreadInput($t2, $t1, $false) }
    Check "SK-3b" "INFO" "the sink can be fronted from the harness thread with AttachThreadInput (not what the adapter does)" ([S]::GetForegroundWindow() -eq $h)
  }

  if ([S]::GetForegroundWindow() -eq $h) {
    # SK-4: keys arrive at the sink and nowhere else (we can only see the sink side)
    $k0 = Count 'sink-key'
    foreach ($vk in 0x41, 0x0D, 0x2E, 0x71, 0x20) { Key $vk; Start-Sleep -Milliseconds 80 }   # A, Enter, Delete, F2, Space
    Start-Sleep -Milliseconds 500
    $k1 = Count 'sink-key'
    Check "SK-4" ($(if ($k1 - $k0 -ge 5) { "PASS" } else { "FAIL" })) "keys typed while the sink is in front reach the sink (and are dropped there)" "sink saw $($k1 - $k0) key messages; foreground still the sink: $([S]::GetForegroundWindow() -eq $h)"

    # SK-5: Alt+F4 does not close it
    [S]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); Key 0x73; [S]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 800
    Check "SK-5" ($(if ([S]::IsWindow($h)) { "PASS" } else { "FAIL" })) "Alt+F4 does not destroy the sink" ("alive=$([S]::IsWindow($h)); log: " + ((LogLines | Where-Object { $_ -match 'close-dropped|destroyed' }) -join " | "))

    # SK-6: Jwno's own key binding still fires while the sink is in front
    $f0 = Count 'hotkey-fired'
    [S]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [S]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero)
    Key 0x7A
    [S]::keybd_event(0x10, 0, 2, [UIntPtr]::Zero); [S]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    $fired = WaitFor { (Count 'hotkey-fired') -gt $f0 } 3
    Check "SK-6" ($(if ($fired) { "PASS" } else { "FAIL" })) "a Jwno key binding (Alt+Shift+F11) still fires while the sink is in front (the way out of an empty workspace)" "fired=$fired"

    # SK-7: what Jwno's focus-changed hook says about the sink
    Check "SK-7" "INFO" "what Jwno's :focus-changed reports (hwnd values; the sink is $($Matches[1]))" ((LogLines | Where-Object { $_ -match 'jwno-focus-changed' } | Select-Object -Last 3) -join " | ")
  }
  $null = Cmd "(sink-destroy)"
  Start-Sleep -Milliseconds 500
  Check "SK-8" ($(if (-not [S]::IsWindow($h)) { "PASS" } else { "FAIL" })) "the sink can be destroyed again (and so rebuilt)" "alive=$([S]::IsWindow($h))"
}
Check "SK-9" "INFO" "NOT measured here: Japanese IME behaviour, Narrator, DPI, the real-hardware lock on SetForegroundWindow from a timer" ""
$null = Cmd "(:quit)"
Start-Sleep 1
if (-not $j.HasExited) { Stop-Process -Id $j.Id -Force -ErrorAction SilentlyContinue }
$results | ConvertTo-Json | Out-File -Encoding utf8 (Join-Path $Out "sink-results.json")
$fail = @($results | Where-Object { $_.status -eq "FAIL" }).Count
Write-Host ("SINK PASS={0} FAIL={1} INFO={2}" -f @($results | Where-Object { $_.status -eq "PASS" }).Count, $fail, @($results | Where-Object { $_.status -eq "INFO" }).Count)
exit ([int]($fail -gt 0))
