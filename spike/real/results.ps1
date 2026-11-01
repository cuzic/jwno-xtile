# Compact, plain-text results (no window titles, only the checks' own evidence).
param([string]$Work = "C:\Users\cuzic\xtile-realtest")
$o = Join-Path $Work "out"
$res = Join-Path $o "contract-results.json"
if (Test-Path $res) { Get-Content $res -Raw | ConvertFrom-Json | ForEach-Object { "{0} {1} | {2} | {3}" -f $_.status, $_.id, $_.what, $_.detail } } else { "no results file" }
if (Test-Path "$o\safety.json") { "--- safety.json"; Get-Content "$o\safety.json" -Raw }
