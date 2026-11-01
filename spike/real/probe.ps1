# How long does a bare Jwno take to reach the config on this machine? (No REPL, manages nothing.)
param([string]$Work = "C:\Users\cuzic\xtile-realtest", [int]$Wait = 100)
$ErrorActionPreference = "Continue"
$o = Join-Path $Work "probe"
New-Item -ItemType Directory -Force -Path $o | Out-Null
$po = Join-Path $o "probe.log"; if (Test-Path $po) { Remove-Item $po -Force }
$jl = Join-Path $o "jwno.log"; if (Test-Path $jl) { Remove-Item $jl -Force }
if (Get-Process jwno -ErrorAction SilentlyContinue) { "refusing: a Jwno is already running"; exit 3 }
$env:PROBE_OUT = $po
$t0 = Get-Date
$p = Start-Process -FilePath (Join-Path $Work "jwno.exe") -PassThru -ArgumentList @("--config", (Join-Path $Work "repo\spike\real\probe-min.janet"), "--log-file", $jl, "--log-level", "debug", "--no-console")
$ok = $false
while (((Get-Date) - $t0).TotalSeconds -lt $Wait) {
  if ((Test-Path $po) -and (Select-String -Path $po -Pattern "config-end" -Quiet)) { $ok = $true; break }
  if ($p.HasExited) { break }
  Start-Sleep -Milliseconds 250
}
$dt = ((Get-Date) - $t0).TotalSeconds
"config reached: $ok after {0:N1}s (jwno exited early: {1})" -f $dt, $p.HasExited
if (Test-Path $po) { Get-Content $po }
Start-Sleep 3
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
"--- last lines of jwno.log (timestamps only matter)"
if (Test-Path $jl) { Get-Content $jl -Tail 6 | ForEach-Object { if ($_.Length -gt 170) { $_.Substring(0, 170) } else { $_ } } }
"desktops: " + $(try { [int]((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops').VirtualDesktopIDs.Length / 16) } catch { 1 })
