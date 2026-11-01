# Read-only: lines of our own logs that match the regex in spike\real\grep-pattern.txt (a window handle, a keyword).
param([string]$Work = "C:\Users\cuzic\xtile-realtest")
$o = Join-Path $Work "out"
$pat = (Get-Content (Join-Path $Work "repo\spike\real\grep-pattern.txt") -Raw).Trim()
"pattern: $pat"
foreach ($f in "contract-jwno.log", "contract.log") {
  $p = Join-Path $o $f
  "===== $f"
  if (Test-Path $p) {
    Get-Content $p | Where-Object { $_ $_ -notmatch "msg-wndproc|^\S+ \S+ \[debug\] (hwnd|msg|wparam|lparam) =" } |
      Select-String -Pattern $pat | Select-Object -First 12 | ForEach-Object { $t = $_.Line; if ($t.Length -gt 400) { $t.Substring(0, 400) } else { $t } }
  }
}
