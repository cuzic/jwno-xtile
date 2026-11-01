# Starts the real-machine run in the background (so the exec call returns), after updating the repo.
param([string]$Work = "C:\Users\cuzic\xtile-realtest")
$repo = Join-Path $Work "repo"
git -C $repo fetch -q origin main; git -C $repo reset -q --hard origin/main
"repo: " + (git -C $repo log -1 --oneline)
$pw = "C:\Program Files\PowerShell\7\pwsh.exe"
$p = Start-Process -FilePath $pw -WindowStyle Hidden -PassThru -ArgumentList @("-NoProfile", "-File", (Join-Path $repo "spike\real\run-real.ps1"), "-Jwno", (Join-Path $Work "jwno.exe"), "-RepoRoot", $repo, "-Out", (Join-Path $Work "out"))
"started pid $($p.Id)"
