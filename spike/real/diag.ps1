# Read-only: why did the run not start? (no window titles, only our own logs)
param([string]$Work = "C:\Users\cuzic\xtile-realtest")
$o = Join-Path $Work "out"
foreach ($f in "contract.log", "contract-console.log", "contract-jwno.log") {
  $p = Join-Path $o $f
  "===== $f"
  if (Test-Path $p) { Get-Content $p -Tail 25 | ForEach-Object { if ($_.Length -gt 240) { $_.Substring(0, 240) } else { $_ } } } else { "(missing)" }
}
"===== jwno.exe"
(Get-Item (Join-Path $Work "jwno.exe") -ErrorAction SilentlyContinue | Select-Object Length, LastWriteTime | Out-String).Trim()
"===== running jwno: " + (@(Get-Process jwno -ErrorAction SilentlyContinue).Count)
