# Prints the taskbar pictures of the last "taskbar-shots" run as base64 (name, then the data), so they can be rebuilt elsewhere.
param([string]$Work = "C:\Users\cuzic\xtile-realtest")
$d = Join-Path $Work "out\shots"
if (-not (Test-Path $d)) { "no shots"; exit }
Get-ChildItem $d -Filter *.png | Sort-Object Name | ForEach-Object {
  "SHOT $($_.Name) $($_.Length)"
  [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))
  "ENDSHOT"
}
