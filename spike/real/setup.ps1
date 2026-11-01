# Real-machine setup: put the CI-built jwno.exe (sent by Taildrop) in a work directory, check its hash, and get the repo.
param([string]$Work = "C:\Users\cuzic\xtile-realtest")
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$exe = Join-Path $Work "jwno.exe"
$cands = @("$env:USERPROFILE\Downloads", "$env:LOCALAPPDATA\Tailscale\files", "$env:USERPROFILE\Desktop") |
  Where-Object { Test-Path $_ } |
  ForEach-Object { Get-ChildItem $_ -Filter "xtile-jwno*" -ErrorAction SilentlyContinue }
"candidates: " + (($cands | ForEach-Object { $_.FullName }) -join "; ")
$e = $cands | Where-Object { $_.Name -like "xtile-jwno-0.9.16*.exe" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$s = $cands | Where-Object { $_.Name -like "xtile-jwno.sha256*" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$l = $cands | Where-Object { $_.Name -like "xtile-jwno-LICENSE*" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $e -or -not $s) { "FAIL: the Taildrop files were not found (exe=$($e.FullName) sha=$($s.FullName))"; exit 2 }
$want = ((Get-Content $s.FullName -Raw).Trim() -split '\s+')[0].ToUpper()
$have = (Get-FileHash $e.FullName -Algorithm SHA256).Hash.ToUpper()
"sha256 expected=$want"; "sha256 actual  =$have"
if ($want -ne $have) { "FAIL: hash mismatch; not using this file"; exit 3 }
Copy-Item $e.FullName $exe -Force
if ($l) { Copy-Item $l.FullName (Join-Path $Work "JWNO-LICENSE") -Force }
"OK: $exe ($((Get-Item $exe).Length) bytes)"
$repo = Join-Path $Work "repo"
if (Test-Path (Join-Path $repo ".git")) { git -C $repo fetch -q origin main; git -C $repo reset -q --hard origin/main } else { git clone -q https://github.com/cuzic/jwno-xtile.git $repo }
"repo: " + (git -C $repo log -1 --oneline)
