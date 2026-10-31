# Starts the built jwno.exe with the probe config, opens two Notepad windows, moves focus around, collects logs.
param([string]$Jwno, [string]$Config, [string]$Out = "spike-out")
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$env:SPIKE_LOG = (Join-Path (Resolve-Path $Out) "hooks.log")
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class F { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
                        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); }
"@
$log = Join-Path $Out "jwno-own.log"
$j = Start-Process -FilePath $Jwno -ArgumentList @("--config", $Config, "--log-file", $log, "--log-level", "debug", "--no-console") -PassThru
Start-Sleep 12
"jwno alive after start: $(-not $j.HasExited)" | Tee-Object -FilePath (Join-Path $Out "run.txt") -Append
if (-not $j.HasExited) {
  $a = Start-Process notepad -PassThru; Start-Sleep 4
  $b = Start-Process notepad -PassThru; Start-Sleep 4
  $a.Refresh(); $b.Refresh()
  "notepad a hwnd=$($a.MainWindowHandle) b hwnd=$($b.MainWindowHandle)" | Tee-Object -FilePath (Join-Path $Out "run.txt") -Append
  $ok = [F]::SetForegroundWindow($a.MainWindowHandle); Start-Sleep 2
  "SetForegroundWindow(a) returned $ok; fg is a: $([F]::GetForegroundWindow() -eq $a.MainWindowHandle)" | Tee-Object -FilePath (Join-Path $Out "run.txt") -Append
  Stop-Process -Id $b.Id -Force; Start-Sleep 3
  Stop-Process -Id $a.Id -Force; Start-Sleep 3
  "jwno alive at end: $(-not $j.HasExited)" | Tee-Object -FilePath (Join-Path $Out "run.txt") -Append
  if (-not $j.HasExited) { Stop-Process -Id $j.Id -Force }
}
foreach ($f in "hooks.log", "jwno-own.log") {
  $p = Join-Path $Out $f
  Write-Host "===== $f ====="
  if (Test-Path $p) { Get-Content $p -Tail 200 } else { Write-Host "(missing)" }
}
