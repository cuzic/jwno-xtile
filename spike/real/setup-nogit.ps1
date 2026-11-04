# Real-machine setup for a machine WITHOUT git (the GCP Windows VM): jwno.exe from Taildrop (hash checked), repo as a GitHub zip.
param([string]$Work = "$env:USERPROFILE\xtile-realtest")
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$dl = Join-Path $env:USERPROFILE "Downloads"
$e = Join-Path $dl "xtile-jwno-0.9.16.exe"; $s = Join-Path $dl "xtile-jwno.sha256.txt"
if (-not (Test-Path $e) -or -not (Test-Path $s)) { "FAIL: Taildrop files not in $dl"; exit 2 }
$want = ((Get-Content $s -Raw).Trim() -split '\s+')[0].ToUpper()
$have = (Get-FileHash $e -Algorithm SHA256).Hash.ToUpper()
"sha256 expected=$want"; "sha256 actual  =$have"
if ($want -ne $have) { "FAIL: hash mismatch"; exit 3 }
Copy-Item $e (Join-Path $Work "jwno.exe") -Force
$lic = Join-Path $dl "xtile-jwno-LICENSE.txt"; if (Test-Path $lic) { Copy-Item $lic (Join-Path $Work "JWNO-LICENSE") -Force }
$zip = Join-Path $Work "repo.zip"; $tmp = Join-Path $Work "repo-tmp"; $repo = Join-Path $Work "repo"
Invoke-WebRequest "https://github.com/cuzic/jwno-xtile/archive/refs/heads/main.zip" -OutFile $zip
Remove-Item $tmp, $repo -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip -DestinationPath $tmp -Force
Move-Item (Join-Path $tmp "jwno-xtile-main") $repo
Remove-Item $tmp -Recurse -Force
"OK: jwno.exe $((Get-Item (Join-Path $Work 'jwno.exe')).Length) bytes; repo files: $((Get-ChildItem $repo -Recurse -File).Count)"
