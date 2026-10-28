# First-time-user test in Windows Sandbox: a clean Windows with no Git, Node.js, Python, winget or
# GPU driver. Maps this repo in (read-only) and an output folder (writable), runs inside.ps1 when the
# sandbox signs in, streams its log, and stops the sandbox. Screenshots land in the output folder.
#
#   powershell -ExecutionPolicy Bypass -File tests\sandbox\run-sandbox.ps1 [-Local] [-SkipPcCheck] [-KeepOpen]
#
# While it runs, tests\sandbox\peek-sandbox.ps1 shows what is happening inside (processes, windows,
# the setup windows' logs). Uses the Windows Sandbox command line (wsb, Windows 11 24H2 with the
# Windows Sandbox app) to start and stop it. Needs the Windows Sandbox feature (once, as
# administrator, then restart):
#   Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
param(
    # Each run gets its own folder.
    [string]$Out = (Join-Path $env:TEMP ('strata-launcher-sandbox\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    # Skip Strata's own PC check (it installs Python inside the sandbox).
    [switch]$SkipPcCheck,
    # Install this repository's copy instead of the one-line web install (before a push).
    [switch]$Local,
    # Leave the sandbox running at the end, to look around (stop it with: wsb stop --id <id>).
    [switch]$KeepOpen,
    [int]$TimeoutMinutes = 60
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$wsb = (Get-Command wsb -ErrorAction SilentlyContinue).Source
if (-not $wsb) { $wsb = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wsb.exe' }
if (-not (Test-Path -LiteralPath $wsb)) {
    throw 'The Windows Sandbox command line (wsb) is missing: enable Windows Sandbox (as administrator: Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All, then restart) and update the Windows Sandbox app from the Microsoft Store.'
}
$running = (& $wsb list --raw | Out-String | ConvertFrom-Json).WindowsSandboxEnvironments
if (@($running).Count) { throw "A Windows Sandbox is already running (only one at a time): wsb stop --id $(@($running)[0])" }

New-Item -ItemType Directory -Path $Out -Force | Out-Null
$flags = (@(if ($SkipPcCheck) { '-SkipPcCheck' }) + @(if ($Local) { '-Local' })) -join ' '
$config = @"
<Configuration>
  <vGPU>Disable</vGPU>
  <Networking>Enable</Networking>
  <MemoryInMB>8192</MemoryInMB>
  <MappedFolders>
    <MappedFolder><HostFolder>$repo</HostFolder><SandboxFolder>C:\strata-launcher-src</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$Out</HostFolder><SandboxFolder>C:\out</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\strata-launcher-src\tests\sandbox\inside.ps1 $flags</Command>
  </LogonCommand>
</Configuration>
"@
Write-Host "Starting Windows Sandbox (results in $Out)..."
$started = & $wsb start --config ($config -replace "`r?`n\s*", '') --raw | Out-String
$id = [regex]::Match($started, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Value
if (-not $id) { throw "wsb start did not return a sandbox id: $started" }
Set-Content -LiteralPath (Join-Path $Out 'sandbox-id.txt') -Value $id
Write-Host "Sandbox $id; signing in (the test starts at sign-in)..."
Start-Process -FilePath $wsb -ArgumentList "connect --id $id" -WindowStyle Minimized

$log = Join-Path $Out 'log.txt'
$done = Join-Path $Out 'done.txt'
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$seen = 0
try {
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $done)) {
        Start-Sleep -Seconds 5
        if (-not (Test-Path -LiteralPath $log)) { continue }
        # the sandbox may be writing it this moment: read it shared, and skip a turn when it is locked
        try {
            $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
            try { $lines = @((New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() -split "`r?`n" | Where-Object { $_ }) } finally { $fs.Dispose() }
        } catch { continue }
        if ($lines.Count -gt $seen) { $lines[$seen..($lines.Count - 1)] | ForEach-Object { Write-Host "  sandbox: $_" }; $seen = $lines.Count }
    }
    Start-Sleep -Seconds 2
    Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Select-Object -Skip $seen | ForEach-Object { Write-Host "  sandbox: $_" }
    if (-not (Test-Path -LiteralPath $done)) {
        Write-Host "TIMEOUT after $TimeoutMinutes minutes. What is happening inside:"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'peek-sandbox.ps1') -Out $Out
        $KeepOpen = $true
        exit 2
    }
    $result = (Get-Content -LiteralPath $done -Raw).Trim()
    Write-Host "Result: $result   (log, screenshots: $Out)"
    if ($result -ne 'PASS') { exit 1 }
} finally {
    if ($KeepOpen) { Write-Host "Left running: wsb stop --id $id" }
    else { & $wsb stop --id $id 2>$null | Out-Null }
}
