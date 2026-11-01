# Emergency stop for the real-machine run: quit Jwno (which brings parked windows back), kill the test notepads
# that this run started, put nothing else right. It never closes a virtual desktop.
param([string]$Jwno = "C:\Users\cuzic\xtile-realtest\jwno.exe", [string]$Out = "C:\Users\cuzic\xtile-realtest\out")
Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq "" -and $_.CommandLine -like "*run-real.ps1*" } | Stop-Process -Force -ErrorAction SilentlyContinue
if (Get-Process jwno -ErrorAction SilentlyContinue) {
  if (Test-Path $Jwno) { & $Jwno -x quit 2>&1 | Out-Null }
  Start-Sleep 5
  Get-Process jwno -ErrorAction SilentlyContinue | Stop-Process -Force
}
"aborted at " + (Get-Date -Format "HH:mm:ss") | Add-Content (Join-Path $Out "progress.log")
