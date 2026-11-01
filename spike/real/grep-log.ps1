# Read-only: lines of our own logs matching the regex in spike\real\grep-pattern.txt.
param([string]$Work = "C:\Users\cuzic\xtile-realtest")
$o = Join-Path $Work "out"
$pat = (Get-Content (Join-Path $Work "repo\spike\real\grep-pattern.txt") -Raw).Trim()
"pattern: $pat"
foreach ($f in "contract-jwno.log", "contract.log") {
  $p = Join-Path $o $f
  "===== $f"
  if (Test-Path $p) {
    Get-Content $p | Select-String -Pattern $pat  | Select-Object -First 40 | ForEach-Object { 
      $t = $_.Line; if ($t.Length -gt 400) { $t.Substring(0, 400) } else { $t } }
  }
}
