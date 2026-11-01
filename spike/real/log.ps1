param([string]$Work = "C:\Users\cuzic\xtile-realtest", [int]$Tail = 25)
$o = Join-Path $Work "out"
if (Test-Path "$o\progress.log") { "--- progress.log"; Get-Content "$o\progress.log" -Tail $Tail } else { "no progress.log yet" }
if (Test-Path "$o\summary.txt") { "--- summary.txt"; Get-Content "$o\summary.txt" }
