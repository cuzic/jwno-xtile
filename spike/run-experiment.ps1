# Experiment (ADR 0009 open item): which mitigation makes a Core-style  [:goto] + [:focus C]  stick
# after Jwno's own post-desktop-switch refocus?
#   base  : switch back, then SetForegroundWindow(C) immediately
#   A     : same, but Jwno's :set-focus-to-hwnd is suppressed (probe-config reads $SPIKE_MODE)
#   B<ms> : switch back, wait <ms>, then SetForegroundWindow(C)
#   C     : like base; after 250ms, if the foreground is not C, re-issue SetForegroundWindow(C) once
# Per trial: success = C is foreground at the end of the window; also time to first reach C, and "flaps"
# (C lost again after being reached). Trials are interleaved round-robin to avoid time drift.
param([string]$Jwno, [string]$Config, [string]$Out = "spike-out", [int]$Trials = 10)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$env:SPIKE_LOG = Join-Path $Out "exp-hooks.log"
$modeFile = Join-Path $Out "mode.txt"; $env:SPIKE_MODE = $modeFile
"" | Set-Content $modeFile
$csv = Join-Path $Out "experiment.csv"
"variant,trial,success,reached_ms,flaps,reissues,jwno_refocus_calls,jwno_suppressed" | Set-Content $csv

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class F {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
}
"@
function Chord([byte]$vk) {
  foreach ($k in 0x5B, 0x11, $vk) { [F]::keybd_event($k, 0, 0, [UIntPtr]::Zero) }
  foreach ($k in $vk, 0x11, 0x5B) { [F]::keybd_event($k, 0, 2, [UIntPtr]::Zero) }
}
function FocusNow($h) {
  [F]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [F]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  [void][F]::SetForegroundWindow($h)
}
function Launch() { $p = Start-Process notepad -PassThru; Start-Sleep 3; $p.Refresh(); $p }

$script:S = $null; $script:sw = $null; $script:target = [IntPtr]::Zero
function Tick() {
  $isT = ([F]::GetForegroundWindow() -eq $script:target)
  if ($isT -and $script:S.reached -lt 0) { $script:S.reached = $script:sw.ElapsedMilliseconds }
  if ($script:S.reached -ge 0 -and $script:S.last -eq $true -and -not $isT) { $script:S.flaps++ }
  $script:S.last = $isT
}
function Pause([int]$untilMs) { while ($script:sw.ElapsedMilliseconds -lt $untilMs) { Tick; Start-Sleep -Milliseconds 15 } }

$j = Start-Process -FilePath $Jwno -ArgumentList @("--config", $Config, "--log-file", (Join-Path $Out "exp-jwno-own.log"), "--log-level", "quiet", "--no-console") -PassThru
Start-Sleep 12
if ($j.HasExited) { Write-Host "Jwno exited early"; return }
$B = Launch; $C = Launch
$hB = $B.MainWindowHandle; $hC = $C.MainWindowHandle
$script:target = $hC

$variants = @("base", "A", "B150", "B250", "B500", "C")
for ($t = 1; $t -le $Trials; $t++) {
  foreach ($v in $variants) {
    $(if ($v -eq "A") { "A" } else { "" }) | Set-Content $modeFile
    # reset: Jwno remembers B as desktop 1's current window; go to desktop 2 and wait
    FocusNow $hB; Start-Sleep -Milliseconds 700
    Chord 0x27; Start-Sleep -Milliseconds 2000
    $logBefore = if (Test-Path $env:SPIKE_LOG) { @(Get-Content $env:SPIKE_LOG).Count } else { 0 }
    $script:S = @{ reached = -1; flaps = 0; last = $null }; $reissues = 0
    $script:sw = [Diagnostics.Stopwatch]::StartNew()
    Chord 0x25                                   # the Core's [:goto "1"]
    switch -Regex ($v) {
      '^B(\d+)$' { Pause ([int]$Matches[1]); FocusNow $hC }
      '^C$'      { FocusNow $hC; Pause 250; Tick; if (-not $script:S.last) { FocusNow $hC; $reissues = 1 } }
      default    { FocusNow $hC }
    }
    Pause 2000
    $new = @(Get-Content $env:SPIKE_LOG | Select-Object -Skip $logBefore)
    $refocus = @($new | Where-Object { $_ -match ' jwno-set-focus-to-hwnd ' }).Count
    $supp = @($new | Where-Object { $_ -match ' jwno-set-focus-suppressed ' }).Count
    "{0},{1},{2},{3},{4},{5},{6},{7}" -f $v, $t, [int]($script:S.last -eq $true), $script:S.reached, $script:S.flaps, $reissues, $refocus, $supp |
      Add-Content $csv
  }
}
Chord 0x25; Start-Sleep 1
foreach ($p in @($B, $C)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
if (-not $j.HasExited) { Stop-Process -Id $j.Id -Force }

Write-Host "===== per-variant summary (n=$Trials) ====="
$rows = Import-Csv $csv
foreach ($v in $variants) {
  $r = @($rows | Where-Object { $_.variant -eq $v })
  $ok = @($r | Where-Object { $_.success -eq '1' }).Count
  $reach = @($r | Where-Object { [int]$_.reached_ms -ge 0 } | ForEach-Object { [int]$_.reached_ms } | Sort-Object)
  $med = if ($reach.Count) { $reach[[int][math]::Floor(($reach.Count - 1) / 2)] } else { -1 }
  $flaps = ($r | ForEach-Object { [int]$_.flaps } | Measure-Object -Sum).Sum
  $re = ($r | ForEach-Object { [int]$_.reissues } | Measure-Object -Sum).Sum
  "{0,-5} success {1}/{2}  median_reached_ms {3}  flaps {4}  reissues {5}" -f $v, $ok, $r.Count, $med, $flaps, $re | Tee-Object -FilePath (Join-Path $Out "experiment-summary.txt") -Append
}
Write-Host "===== csv ====="; Get-Content $csv
