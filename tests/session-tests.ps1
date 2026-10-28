# Test the session-file helpers of strata-launcher.ps1 without its UI: the functions are pulled out of
# the script with the AST and driven with stubs; no server, no file outside %TEMP% is touched.
$ErrorActionPreference = 'Stop'

function Get-FunctionText([string]$Path, [string[]]$Names) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "parse errors in $Path" }
    $out = ''
    foreach ($n in $Names) {
        $fd = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true) |
            Select-Object -First 1
        if (-not $fd) { throw "function $n not found in $Path" }
        $out += $fd.Extent.Text + "`n"
    }
    return $out
}

$fails = 0
function Assert-Is($Got, $Want, [string]$What) {
    if ("$Got" -eq "$Want") { "  ok   $What = $Got" }
    else { $script:fails++; "  FAIL $What : got $Got, want $Want" }
}

$gui = Join-Path (Split-Path -Parent $PSScriptRoot) 'strata-launcher.ps1'
Invoke-Expression (Get-FunctionText $gui @('Get-SessionDir', 'Get-LatestSessionName', 'Test-SessionName', 'Get-ServerLauncher'))
function Get-Root { 'M:\strata' }

Write-Host '--- Test-SessionName: what the engine accepts as a session file name'
foreach ($ok in 'chat1.bin', 'strata-nvfp4-latest.bin', 'a_b-c.2') { Assert-Is (Test-SessionName $ok) $true "accepts $ok" }
foreach ($bad in '..\x.bin', 'D:\x.bin', 'sub/x.bin', '.hidden', 'x.bin.', 'NUL', 'con.bin', 'COM1', 'a:stream', 'has space.bin', '') {
    Assert-Is (Test-SessionName $bad) $false "refuses '$bad'"
}

Write-Host '--- Get-SessionDir / Get-LatestSessionName'
$row = [pscustomobject]@{ File = 'strata-nvfp4-nvfp4-nvidia.json'; Cfg = [pscustomobject]@{ slot_save_path = 'D:\ai\Strata-data\sessions'; cwd = 'M:\strata' } }
Assert-Is (Get-SessionDir $row) 'D:\ai\Strata-data\sessions' 'an absolute folder is used as it is'
$row.Cfg.slot_save_path = 'sessions'
Assert-Is (Get-SessionDir $row) 'M:\strata\sessions' 'a relative folder is the config''s cwd, as the server resolves it'
$row.Cfg = [pscustomobject]@{ slot_save_path = 'sessions' }
Assert-Is (Get-SessionDir $row) 'M:\strata\sessions' '...or the Strata folder without a cwd'
$row.Cfg = [pscustomobject]@{ args = @() }
Assert-Is ([string](Get-SessionDir $row)) '' 'no slot_save_path: sessions are off'
Assert-Is (Get-LatestSessionName $row) 'strata-nvfp4-nvfp4-nvidia-latest.bin' 'the Hibernate/Resume file is named after the config'

Write-Host '--- Get-ServerLauncher: stop the whole launch chain, never more'
# a fake chain: cmd (run-x.bat) -> venv python -> real python; and an unrelated cmd above it
function Get-CimInstance {
    @(
        [pscustomobject]@{ ProcessId = 10; ParentProcessId = 1; Name = 'cmd.exe'; CommandLine = 'cmd.exe /k dir' }
        [pscustomobject]@{ ProcessId = 20; ParentProcessId = 10; Name = 'cmd.exe'; CommandLine = 'cmd /c run-orca-iq3_xxs.bat' }
        [pscustomobject]@{ ProcessId = 30; ParentProcessId = 20; Name = 'python.exe'; CommandLine = 'python.exe serve\server.py --config a.json' }
        [pscustomobject]@{ ProcessId = 40; ParentProcessId = 30; Name = 'python.exe'; CommandLine = 'python.exe serve\server.py --config a.json' }
        [pscustomobject]@{ ProcessId = 50; ParentProcessId = 10; Name = 'python.exe'; CommandLine = 'python.exe other.py' }
    )
}
Assert-Is (Get-ServerLauncher 40) 20 'the listener climbs to the run-*.bat window, not the shell above it'
Assert-Is (Get-ServerLauncher 50) 50 'a process outside a Strata chain is left as it is'
Assert-Is (Get-ServerLauncher 999) 999 'an unknown process id stays itself'

if ($fails) { "`n$fails FAILED"; exit 1 }
"`nall good"
