# What is happening inside the running test sandbox right now: runs peek.ps1 in it (wsb exec, in the
# signed-in session) and prints the C:\out\peek.txt it writes.
#   powershell -ExecutionPolicy Bypass -File tests\sandbox\peek-sandbox.ps1 [-Out <the run's folder>]
param([string]$Out)
$wsb = (Get-Command wsb -ErrorAction SilentlyContinue).Source
if (-not $wsb) { $wsb = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wsb.exe' }
if (-not $Out) { $Out = Get-ChildItem (Join-Path $env:TEMP 'strata-launcher-sandbox') -Directory | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName }
$id = (Get-Content -LiteralPath (Join-Path $Out 'sandbox-id.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $id) { Write-Host "No sandbox id in $Out"; exit 1 }
$peek = Join-Path $Out 'peek.txt'
Remove-Item -LiteralPath $peek -ErrorAction SilentlyContinue
& $wsb exec --id $id -r ExistingLogin -c 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\strata-launcher-src\tests\sandbox\peek.ps1' | Out-Null
for ($i = 0; $i -lt 30 -and -not (Test-Path -LiteralPath $peek); $i++) { Start-Sleep -Milliseconds 500 }
if (Test-Path -LiteralPath $peek) { Get-Content -LiteralPath $peek } else { Write-Host 'peek.ps1 wrote nothing (is the sandbox signed in?)' }
