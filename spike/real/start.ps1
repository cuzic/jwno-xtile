# Starts the real-machine run in the background (so the exec call returns), after updating the repo.
param([string]$Work = "$env:USERPROFILE\xtile-realtest", [string]$Spike = "contract")
$repo = Join-Path $Work "repo"
if (Test-Path (Join-Path $repo ".git")) { git -C $repo fetch -q origin main; git -C $repo reset -q --hard origin/main; "repo: " + (git -C $repo log -1 --oneline) } else { "repo: no git, using the zip copy" }
$pw = "C:\Program Files\PowerShell\7\pwsh.exe"
$p = Start-Process -FilePath $pw -WindowStyle Hidden -PassThru -ArgumentList @("-NoProfile", "-File", (Join-Path $repo "spike\real\run-real.ps1"), "-Jwno", (Join-Path $Work "jwno.exe"), "-RepoRoot", $repo, "-Out", (Join-Path $Work "out"), "-Spike", $Spike)
"started pid $($p.Id)"
