# Test the logic of strata-launcher.ps1 without starting its UI:
# pull the real function bodies out of the files with the AST, then drive them with stubs.
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
    if ($Got -eq $Want) { "  ok   $What = $Got" }
    else { $script:fails++; "  FAIL $What : got $Got, want $Want" }
}

# ---------------------------------------------------------------- strata-launcher.ps1
$gui = Join-Path (Split-Path -Parent $PSScriptRoot) 'strata-launcher.ps1'
Invoke-Expression (Get-FunctionText $gui @('Get-ArgValue', 'Get-CtxOverride', 'Get-RowContext',
    'Get-RopeScale', 'Set-ArgValue', 'Remove-Arg', 'Set-ContextArgs'))
$TrainedContext = 262144
function Clean-Path([string]$Text) { $Text }
Write-Host '--- Get-RowContext (GUI)'
$cfgRow = [pscustomobject]@{ Port = 8080; Cfg = [pscustomobject]@{ args = @('--max-context', '131072', '--kv', 'int8') } }
$ui = [pscustomobject]@{ CtxBox = [pscustomobject]@{ Text = '(config)' } }
$script:health = @{}
$script:health[8080] = [pscustomobject]@{ Context = 131072 }
Assert-Is (Get-RowContext $cfgRow) 131072 'running server wins'
$script:health[8080] = [pscustomobject]@{ Context = 0 }
Assert-Is (Get-RowContext $cfgRow) 131072 'lazy server (max_context 0) -> the config'
$ui = [pscustomobject]@{ CtxBox = [pscustomobject]@{ Text = '65536' } }
Assert-Is (Get-RowContext $cfgRow) 65536 'the launch override beats the config when nothing runs'
$script:health[8080] = [pscustomobject]@{ Context = 131072 }
Assert-Is (Get-RowContext $cfgRow) 131072 '...but never the running server'
$ui = [pscustomobject]@{ CtxBox = [pscustomobject]@{ Text = '(config)' } }
$noCfg = [pscustomobject]@{ Port = 8081; Cfg = [pscustomobject]@{ args = @('--kv', 'int8') } }
Assert-Is (Get-RowContext $noCfg) 0 'nothing known -> 0 (Open VS Code refuses instead of guessing)'
$ui = [pscustomobject]@{ CtxBox = [pscustomobject]@{ Text = '524288  (yarn x2, experimental)' } }
Assert-Is (Get-RowContext $noCfg) 524288 'a labelled step reads as its number'

Write-Host '--- Set-ContextArgs (GUI): rope scaling follows the context'
function New-Args([string[]]$a) { $l = New-Object System.Collections.Generic.List[string]; foreach ($x in $a) { $l.Add($x) }; , $l }
$l = New-Args @('--max-context', '131072', '--kv', 'int8'); Set-ContextArgs $l 262144
Assert-Is ($l -join ' ') '--max-context 262144 --kv int8' '256K: inside the trained window, no rope flags'
$l = New-Args @('--max-context', '131072'); Set-ContextArgs $l 524288
Assert-Is ($l -join ' ') '--max-context 524288 --rope-scaling yarn --rope-scale 2' '512K: yarn x2 added'
$l = New-Args @('--max-context', '131072'); Set-ContextArgs $l 393216
Assert-Is ($l -join ' ') '--max-context 393216 --rope-scaling yarn --rope-scale 1.5' '384K: yarn x1.5'
$l = New-Args @('--max-context', '1048576', '--rope-scaling', 'yarn', '--rope-scale', '4', '--kv', 'int8'); Set-ContextArgs $l 262144
Assert-Is ($l -join ' ') '--max-context 262144 --kv int8' 'a 1M yarn config cut to 256K loses its scaling'
$l = New-Args @('--max-context', '131072', '--rope-scaling', 'linear', '--rope-scale', '1.2'); Set-ContextArgs $l 524288
Assert-Is ($l -join ' ') '--max-context 524288 --rope-scaling linear --rope-scale 2' 'an explicit method is kept, a too-small factor raised'
$l = New-Args @('--rope-scaling', 'yarn', '--rope-scale', '4'); Set-ContextArgs $l 524288
Assert-Is ($l -join ' ') '--rope-scaling yarn --rope-scale 4 --max-context 524288' 'a larger factor than needed is kept'

Write-Host '--- Get-EffectiveConfig (GUI): MTP drafting and depth overrides'
Invoke-Expression (Get-FunctionText $gui @('Get-EffectiveConfig'))
$TempDir = Join-Path $env:TEMP ('strata-launcher-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $TempDir 'data\mtp\rt') | Out-Null
Set-Content -LiteralPath (Join-Path $TempDir 'data\mtp\rt\experts.bin') -Value 'x'
function New-Ui([string]$Mtp = '(config)', [string]$Spec = '(config)') {
    [pscustomobject]@{ CtxBox = [pscustomobject]@{ Text = '(config)' }; ExtraBox = [pscustomobject]@{ Text = '' }
        VramBox = [pscustomobject]@{ Text = '' }; FitChk = [pscustomobject]@{ IsChecked = $false }
        MtpBox = [pscustomobject]@{ SelectedItem = $Mtp }; SpecBox = [pscustomobject]@{ SelectedItem = $Spec }
        DataBox = [pscustomobject]@{ Text = (Join-Path $TempDir 'data') } }
}
function Get-RunArgs($Row) { (Get-Content -LiteralPath (Get-EffectiveConfig $Row) -Raw | ConvertFrom-Json).args -join ' ' }
# the configs live elsewhere: the launcher writes its changed copy to $TempDir under the config's name
New-Item -ItemType Directory -Path (Join-Path $TempDir 'src') | Out-Null
$withMtp = Join-Path $TempDir 'src\strata-with.json'
'{"exe":"x","args":["--native","m.gguf","--spec","4","--mtp","D:\\data\\mtp\\rt","--batch","2","--batch-mtp","--kv","int8"]}' | Set-Content -LiteralPath $withMtp -Encoding ascii
$without = Join-Path $TempDir 'src\strata-without.json'
'{"exe":"x","args":["--native","m.gguf","--kv","int8"]}' | Set-Content -LiteralPath $without -Encoding ascii
$rowWith = [pscustomobject]@{ Path = $withMtp; File = 'strata-with.json' }
$rowWithout = [pscustomobject]@{ Path = $without; File = 'strata-without.json' }
try {
    $ui = New-Ui; Assert-Is (Get-EffectiveConfig $rowWith) $withMtp 'no override: the config itself, no copy'
    $ui = New-Ui 'off (prompt lookup only)'
    Assert-Is (Get-RunArgs $rowWith) '--native m.gguf --spec 4 --batch 2 --kv int8' 'off: --mtp and --batch-mtp go, --spec and what followed --batch-mtp stay'
    $ui = New-Ui '(config)' '6'
    Assert-Is (Get-RunArgs $rowWith) '--native m.gguf --spec 6 --mtp D:\data\mtp\rt --batch 2 --batch-mtp --kv int8' 'depth 6 replaces --spec 4'
    $ui = New-Ui 'on'
    Assert-Is (Get-RunArgs $rowWith) '--native m.gguf --spec 4 --mtp D:\data\mtp\rt --batch 2 --batch-mtp --kv int8' 'on with --mtp already there: unchanged'
    Assert-Is (Get-RunArgs $rowWithout) "--native m.gguf --kv int8 --mtp $(Join-Path $TempDir 'data\mtp\rt') --spec 4" 'on for a config without it: the shared draft layer and setup''s depth'
    $ui = New-Ui 'on' '2'
    Assert-Is (Get-RunArgs $rowWithout) "--native m.gguf --kv int8 --mtp $(Join-Path $TempDir 'data\mtp\rt') --spec 2" 'on with depth 2'
    $ui = New-Ui 'on'; $ui.DataBox.Text = Join-Path $TempDir 'empty'
    $msg = try { [void](Get-EffectiveConfig $rowWithout); 'no error' } catch { $_.Exception.Message }
    Assert-Is ($msg -like 'MTP on: no draft layer in*') $true 'on without a downloaded draft layer says so'
} finally { Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- PC tab: RAM, PCIe links, drives
Invoke-Expression (Get-FunctionText $gui @('Get-RamRating', 'Get-PcWarnings', 'Get-PcSummary', 'Get-PcShort', 'Read-BenchPc'))
Write-Host '--- PC facts and warnings'
Assert-Is (Get-RamRating 'F5-6000J2836F48G') 6000 'G.Skill part number rating'
Assert-Is (Get-RamRating 'CMK64GX5M2B6000C30') 6000 'Corsair part number rating'
Assert-Is (Get-RamRating 'M323R4GA3DB0-CWM') 0 'no speed in the part number'
function New-Stick($Gb, $Run, $Jedec = 5600, $Part = 'F5-6000J2836F48G') { [pscustomobject]@{ Slot = 'A'; GB = $Gb; Part = $Part; Jedec = $Jedec; Running = $Run } }
function New-Drive($Name, $Loc, $Gen, $Width, $Letters, $Models, $Free = 500) {
    [pscustomobject]@{ Name = $Name; Gen = $Gen; Width = $Width; MaxGen = 5; MaxWidth = 4; Location = $Loc; Letters = $Letters; Models = $Models
        Free = @($Letters | ForEach-Object { [pscustomobject]@{ Letter = $_; FreeGB = $Free; Models = $Models } }) }
}
$gpu16 = [pscustomobject]@{ Name = 'RTX 5090'; Gen = 5; Width = 16; MaxGen = 5; MaxWidth = 16; Location = 'PCIROOT(0)#PCI(0101)#PCI(0000)' }
$gpu8 = [pscustomobject]@{ Name = 'RTX 5090'; Gen = 5; Width = 8; MaxGen = 5; MaxWidth = 16; Location = 'PCIROOT(0)#PCI(0101)#PCI(0000)' }
$fast = New-Drive '9100 PRO' 'PCIROOT(0)#PCI(0201)#PCI(0000)' 5 4 @('D') $true
$good = [pscustomobject]@{ Sticks = @((New-Stick 48 6000), (New-Stick 48 6000)); Gpus = @($gpu16); Drives = @($fast) }
Assert-Is @(Get-PcWarnings $good).Count 0 'a PC at its rated RAM speed and full link: no warnings'
Assert-Is (Get-PcShort $good) '2x48@6000, 5.0 x16' 'short form for the Results column'
Assert-Is (Get-PcSummary $good) 'RAM 2x48 GB @ 6000, GPU PCIe 5.0 x16, models on 9100 PRO (5.0 x4)' 'summary line'
# the day this was written: EXPO off (3600), four 48 GB sticks, the GPU at x8 with a drive in the shared M.2 slot
$shared = New-Drive '990 EVO Plus' 'PCIROOT(0)#PCI(0103)#PCI(0000)' 5 2 @('M') $false
$bad = [pscustomobject]@{ Sticks = @(1..4 | ForEach-Object { New-Stick 48 3600 }); Gpus = @($gpu8); Drives = @($fast, $shared) }
$w = @(Get-PcWarnings $bad)
Assert-Is ($w[0] -match 'EXPO' -and $w[0] -match 'four sticks') $true 'EXPO off is named, with the four-stick caution'
Assert-Is (@($w | Where-Object { $_ -match 'x8 of x16' -and $_ -match '990 EVO Plus \(M:\) is connected to the same CPU lanes' }).Count) 1 'x8 names the drive on the GPU''s lanes'
Assert-Is (Get-PcShort $bad) '4x48@3600, 5.0 x8/16' 'short form shows x8 of 16'
$fast4 = [pscustomobject]@{ Sticks = @(1..4 | ForEach-Object { New-Stick 48 6000 }); Gpus = @($gpu16); Drives = @($fast) }
Assert-Is (@(Get-PcWarnings $fast4) -match 'Four 48 GB sticks at 6000').Count 1 'four big sticks at 6000: test it'
$one = [pscustomobject]@{ Sticks = @(New-Stick 32 5600 5600 'X'); Gpus = @(); Drives = @() }
Assert-Is (@(Get-PcWarnings $one) -match 'single memory channel').Count 1 'one stick: one channel'
$slowJedec = [pscustomobject]@{ Sticks = @((New-Stick 16 4000 4800 'X'), (New-Stick 16 4000 4800 'X')); Gpus = @(); Drives = @() }
Assert-Is (@(Get-PcWarnings $slowJedec) -match 'below its standard 4800').Count 1 'below JEDEC with no rated part number'
$gen4 = [pscustomobject]@{ Sticks = @(); Gpus = @([pscustomobject]@{ Name = 'RTX 5090'; Gen = 4; Width = 16; MaxGen = 5; MaxWidth = 16; Location = '' }); Drives = @() }
Assert-Is (@(Get-PcWarnings $gen4) -match 'PCIe 4\.0, below its 5\.0').Count 1 'Gen4 in a Gen5 card'
$slowModels = [pscustomobject]@{ Sticks = @(); Gpus = @(); Drives = @((New-Drive 'old SSD' 'x' 3 4 @('E') $true 12)) }
$w = @(Get-PcWarnings $slowModels)
Assert-Is (@($w -match 'about 4 GB/s').Count) 1 'models on a PCIe 3.0 x4 drive'
Assert-Is (@($w -match 'E: has 12 GB free').Count) 1 'little room where the models are'
$otherFull = [pscustomobject]@{ Sticks = @(); Gpus = @(); Drives = @((New-Drive 'sys' 'x' 5 4 @('C') $false 5), $fast) }
Assert-Is @(Get-PcWarnings $otherFull).Count 0 'a full drive without models is not flagged'
# the commit limit: 94 GB of RAM with a 22 GB system-managed page file capped Q5's RAM budget; a fixed 64 GB one did not
$lowCommit = [pscustomobject]@{ RamGB = 94; CommitGB = 116; PageAuto = $true; PageFiles = @([pscustomobject]@{ Path = 'D:\pagefile.sys'; GB = 22 }); Sticks = @(); Gpus = @(); Drives = @() }
$w = @(Get-PcWarnings $lowCommit)
Assert-Is (@($w -match 'commit only 116 GB \(RAM \+ page file: 22 GB on D:, system managed\)').Count) 1 'a small page file is named with its drive'
Assert-Is (@($w -match 'at least 48 GB').Count) 1 'half the RAM, rounded up to 16 GB'
$okCommit = [pscustomobject]@{ RamGB = 94; CommitGB = 158; PageAuto = $false; PageFiles = @([pscustomobject]@{ Path = 'M:\pagefile.sys'; GB = 64 }); Sticks = @(); Gpus = @(); Drives = @() }
Assert-Is @(Get-PcWarnings $okCommit).Count 0 'a 64 GB page file beside 94 GB of RAM: no warning'
$noPage = [pscustomobject]@{ RamGB = 64; CommitGB = 64; PageAuto = $false; PageFiles = @(); Sticks = @(); Gpus = @(); Drives = @() }
Assert-Is (@(Get-PcWarnings $noPage) -match 'page file: none').Count 1 'no page file at all'
# Results: a folder the launcher benchmarked has launcher-pc.json; an older one falls back to strata_bench's own record
$tmp = Join-Path $env:TEMP "pc-test-$PID"; New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $old = [pscustomobject]@{ machine = [pscustomobject]@{ ram_gib = 189.6; gpu_detail = @([pscustomobject]@{ pcie = 'gen4 x8' }) } }
    Assert-Is (Read-BenchPc $tmp $old).Short '190 GiB, gen4 x8 (idle)' 'older run: strata_bench''s RAM size and idle link'
    '{"short":"2x48@6000, 5.0 x8/16","summary":"RAM 2x48 GB @ 6000"}' | Set-Content -LiteralPath (Join-Path $tmp 'launcher-pc.json') -Encoding ASCII
    Assert-Is (Read-BenchPc $tmp $old).Short '2x48@6000, 5.0 x8/16' 'launcher-pc.json wins'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- VS Code + Continue
Invoke-Expression (Get-FunctionText $gui @('Get-BaseUrl', 'Get-ContinueConfigText'))
Write-Host '--- Continue config and VSIX'
$crow = [pscustomobject]@{ Model = 'qwen3.8-flash-next-nvfp4-nvfp4'; Port = 8083 }
$ctext = Get-ContinueConfigText $crow 524288 'xhigh' 'low'
Assert-Is (@($ctext -split "`n" | Where-Object { $_ -match '^  - name: Strata qwen3\.8-flash-next-nvfp4-nvfp4 - (plan|act)' }).Count) 2 'a plan and an act entry'
Assert-Is ($ctext -match 'reasoning_effort: xhigh' -and $ctext -match 'reasoning_effort: low') $true 'each entry carries its thinking level'
Assert-Is ($ctext -match 'apiBase: http://127\.0\.0\.1:8083/v1' -and $ctext -match 'contextLength: 524288' -and $ctext -match 'capabilities: \[tool_use\]') $true 'endpoint, context and tool use'
Assert-Is ($ctext -match 'maxTokens: 131072') $true 'answer cap with room for a ~128K tool call'
Assert-Is ((Get-ContinueConfigText $crow 65536 '' 'low') -match 'maxTokens: 32768') $true 'half of a small context'
Assert-Is ((Get-ContinueConfigText $crow 1000 '' 'low') -match 'maxTokens: 4096') $true 'never under 4096'
Assert-Is (@((Get-ContinueConfigText $crow 524288 'xhigh' 'low') -split "`n" | Where-Object { $_ -match 'maxTokens' }).Count) 2 'plan and act only: autocomplete keeps its own'
Assert-Is ((Get-ContinueConfigText $crow 1000 '' 'low') -match '(?s)- plan\s*\n.*?\n  - name') $true 'no level: no thinking suffix and no requestOptions'
Assert-Is ($ctext -match '(?s)  - name: Strata qwen3\.8-flash-next-nvfp4-nvfp4 - autocomplete\s*\n.*roles: \[autocomplete\]') $true 'an autocomplete entry'
Assert-Is ($ctext -match 'useLegacyCompletionsEndpoint: false' -and $ctext -match 'enable_thinking: false' -and $ctext -match 'modelTimeout: 1000') $true 'Tab over chat, no thinking, a timeout that fits'
Assert-Is (@($ctext -split "`n" | Where-Object { $_ -match 'roles: \[autocomplete\]' }).Count) 1 'only the Tab entry autocompletes'
$itext = Get-ContinueConfigText $crow 524288 'xhigh' 'low' $true
Assert-Is (@($itext -split "`n" | Where-Object { $_ -match '^    capabilities: \[tool_use, image_input\]$' }).Count) 2 'a server that reads images: both chat entries take them'
Assert-Is ($ctext -match 'image_input') $false 'a server without images: none offered'
Assert-Is ($ctext -match '[^\x00-\x7F]') $false 'plain ASCII'

Write-Host '--- Open VS Code: which extension'
# A fake code.cmd: --list-extensions prints exts.txt, --install-extension adds a line, --uninstall-extension removes it.
Invoke-Expression (Get-FunctionText $gui @('Invoke-CodeCli', 'Get-InstalledExtensions', 'Start-VsCode'))
$ContinuousIds = @('b1tninja.continuous'); $OldForkIds = @('b1tninja.continued', 'b1tninja.continuing')
$cdir = Join-Path $env:TEMP "code-test-$PID"; New-Item -ItemType Directory -Force $cdir | Out-Null
try {
    $state = Join-Path $cdir 'exts.txt'; $calls = Join-Path $cdir 'calls.txt'
    $fake = Join-Path $cdir 'code.ps1'
    Set-Content -LiteralPath $fake -Value @'
param([Parameter(ValueFromRemainingArguments)]$a)
if ("$($a[0])" -notlike '--*') { exit }   # opening the folder runs in the background: it touches no file
$dir = Split-Path -Parent $PSCommandPath; $state = Join-Path $dir 'exts.txt'
Add-Content -LiteralPath (Join-Path $dir 'calls.txt') -Value ($a -join ' ')
$list = @(Get-Content -LiteralPath $state -ErrorAction SilentlyContinue | Where-Object { $_ })
switch ($a[0]) {
    '--list-extensions' { $list }
    '--install-extension' { Set-Content -LiteralPath $state -Value (@($list) + "$($a[1])@2.4.4") }
    '--uninstall-extension' { Set-Content -LiteralPath $state -Value @($list | Where-Object { $_ -notlike "$($a[1])@*" }) }
}
'@
    $code = Join-Path $cdir 'code.cmd'
    Set-Content -LiteralPath $code -Value "@powershell -NoProfile -ExecutionPolicy Bypass -File `"$fake`" %*"
    Add-Type -AssemblyName WindowsBase
  & {   # a child scope: the stubs below go away with it
    function Get-CodeCommand { $code }
    function Clean-Path($p) { $p }
    function QPath($p) { "`"$p`"" }
    function Get-RowContext($r) { 262144 }
    function Write-ContinueConfig($r, $i, $c) { $script:wroteFor = $i; 'cfg' }
    function Set-Status($t) { $script:lastStatus = $t }
    $ui = @{ FolderBox = @{ Text = $cdir } }
    $window = [pscustomobject]@{ Dispatcher = ([pscustomobject]@{} | Add-Member -PassThru -MemberType ScriptMethod -Name Invoke -Value { param($a, $b) }) }
    $vrow = [pscustomobject]@{ Model = 'm'; Port = 8083 }

    Set-Content -LiteralPath $state -Value ''
    Start-VsCode $vrow
    Assert-Is $script:wroteFor 'b1tninja.continuous' 'nothing installed: Continuous'
    Assert-Is ((Get-Content $state) -contains 'b1tninja.continuous@2.4.4') $true 'installed from the Marketplace by its ID'
    Assert-Is ($script:lastStatus -match 'with Continuous 2\.4\.4') $true 'the status names it'

    Set-Content -LiteralPath $calls -Value ''
    Start-VsCode $vrow
    Assert-Is (@(Get-Content $calls | Where-Object { $_ -match 'install-extension' }).Count) 0 'installed already: not installed again'

    Set-Content -LiteralPath $state -Value @('continue.continue@1.3.40', 'b1tninja.continued@1.3.40')
    $script:askedOldForks = $true   # the uninstall question is a dialog
    Start-VsCode $vrow
    Assert-Is $script:wroteFor 'b1tninja.continuous' 'upstream and the old fork installed: Continuous all the same'
    Assert-Is ((Get-Content $state) -contains 'continue.continue@1.3.40') $true 'upstream Continue is left alone'
  }
} finally {
    Start-Sleep -Milliseconds 500   # the fake code.cmd that "opened" the folder
    Remove-Item -LiteralPath $cdir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- Continuous CLI: is a newer release out'
Invoke-Expression (Get-FunctionText $gui @('Compare-Version'))
Assert-Is (Compare-Version '2.4.4' '2.4.4') 0 'same'
Assert-Is (Compare-Version '2.4.3' '2.4.4') -1 'older'
Assert-Is (Compare-Version '2.4.10' '2.4.9') 1 'by number, not text'
Assert-Is (Compare-Version '2.5' '2.4.9') 1 'fewer parts'
Assert-Is (Compare-Version '2.4' '2.4.0') 0 'a missing part is 0'

Write-Host '--- Continue global folder'
Invoke-Expression (Get-FunctionText $gui @('Get-ContinueGlobalDir', 'Get-ContinueConfigPath'))
$ContinuousIds = @('b1tninja.continuous')
$home0 = $env:USERPROFILE; $envs0 = $env:CONTINUOUS_GLOBAL_DIR, $env:CONTINUE_GLOBAL_DIR
$hdir = Join-Path $env:TEMP "home-test-$PID"; New-Item -ItemType Directory -Force $hdir | Out-Null
try {
    $env:USERPROFILE = $hdir; $env:CONTINUOUS_GLOBAL_DIR = ''; $env:CONTINUE_GLOBAL_DIR = ''
    $old = Join-Path $hdir '.continue'; $new = Join-Path $hdir '.continuous'
    Assert-Is (Get-ContinueGlobalDir 'b1tninja.continuous') $new 'Continuous, nothing yet: ~/.continuous'
    New-Item -ItemType Directory -Force $old | Out-Null
    Assert-Is (Get-ContinueGlobalDir 'b1tninja.continuous') $old 'Continuous before its first start: ~/.continue, which its copy carries over'
    Assert-Is (Get-ContinueGlobalDir 'continue.continue') $old 'upstream: ~/.continue'
    Assert-Is (Get-ContinueGlobalDir 'b1tninja.continued') $old 'the older fork: ~/.continue'
    New-Item -ItemType Directory -Force $new | Out-Null
    Assert-Is (Get-ContinueGlobalDir 'b1tninja.continuous') $new 'Continuous after its copy: ~/.continuous'
    Assert-Is (Get-ContinueGlobalDir 'continue.continue') $old 'upstream still ~/.continue'
    Assert-Is (Get-ContinueConfigPath 'b1tninja.continuous') (Join-Path $new 'configs\strata.yaml') 'the config file'
    Assert-Is (Get-ContinueConfigPath) (Join-Path $new 'configs\strata.yaml') 'no file yet: where Continuous would write it'
    New-Item -ItemType Directory -Force (Join-Path $old 'configs') | Out-Null
    Set-Content -LiteralPath (Join-Path $old 'configs\strata.yaml') -Value 'x'
    Assert-Is (Get-ContinueConfigPath) (Join-Path $old 'configs\strata.yaml') 'no id: the file written last'
    $env:CONTINUOUS_GLOBAL_DIR = 'X:\cg'
    Assert-Is (Get-ContinueGlobalDir 'b1tninja.continuous') 'X:\cg' 'CONTINUOUS_GLOBAL_DIR wins'
    Assert-Is (Get-ContinueGlobalDir 'continue.continue') $old 'and upstream does not read it'
    $env:CONTINUOUS_GLOBAL_DIR = ''; $env:CONTINUE_GLOBAL_DIR = 'X:\c'
    Assert-Is (Get-ContinueGlobalDir 'b1tninja.continuous') 'X:\c' 'Continuous still reads CONTINUE_GLOBAL_DIR'
    Assert-Is (Get-ContinueGlobalDir 'continue.continue') 'X:\c' 'as upstream does'
} finally {
    $env:USERPROFILE = $home0; $env:CONTINUOUS_GLOBAL_DIR, $env:CONTINUE_GLOBAL_DIR = $envs0
    Remove-Item -LiteralPath $hdir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- uncensored variant
Invoke-Expression (Get-FunctionText $gui @('Get-UncensorRefusal', 'New-UncensorVariant', 'Get-UncensorFiles'))
Write-Host '--- uncensored variant'
$m = 'D:\ai\Strata-data\models'
$gptq = [pscustomobject]@{ args = @('--pack', "$m\Maximilian228--Qwen3.8-Flash-Next-NVFP4-GPTQ-Strata\pack", '--native',
        "$m\Maximilian228--Qwen3.8-Flash-Next-NVFP4-GPTQ-Strata\qwen-nvfp4-gptq-dense.gguf", '--spec', '3',
        '--control-vector-scaled', 'data\experimental-speed-projection\x.gguf:1.0', '--control-vector-layer-range', '10', '30', '--kv', 'int8');
    model_name = 'qwen3.8-flash-next-nvfp4-nvfp4'; port = 8083; log = 'M:\strata\strata-nvfp4-nvfp4.log'; lib_dirs = @('C:\cu13') }
Assert-Is (Get-UncensorRefusal $gptq) '' 'the NVFP4 GPTQ pack it was made on is allowed'
foreach ($p in 'Maximilian228--Qwen3.8-Flash-Next-NVIDIA-NVFP4-Strata\pack', 'nvidia--Qwen3.8-Flash-Next-FP4-Local\prepared') {
    Assert-Is ((Get-UncensorRefusal ([pscustomobject]@{ args = @('--pack', "$m\$p") })) -match 'licence') $true "refused for NVIDIA's weights ($($p.Split('\')[0]))"
}
Assert-Is ((Get-UncensorRefusal ([pscustomobject]@{ args = @('--native', "$m\orca-iq3_xxs\Qwen3.8-Flash-Next-Uncensored-IQ3_XXS-00001-of-00002.gguf") })) -match 'already') $true 'Orca: uncensored already'
Assert-Is ((Get-UncensorRefusal ([pscustomobject]@{ args = @('--native', "$m\unsloth\Qwen3.8-Flash-Next-UD-Q5_K_XL.gguf") })) -match 'other weights') $true 'other weights refused'

$vec = 'D:\ai\Strata-data\uncensor\qwen-nvfp4-gptq-uncensored.gguf'
$v = New-UncensorVariant $gptq 'strata-nvfp4-nvfp4.json' $vec @(8083, 8084, 8086) $null
Assert-Is $v.File 'strata-nvfp4-nvfp4-uncensored.json' 'variant file name'
Assert-Is $v.Cfg.model_name 'qwen3.8-flash-next-nvfp4-nvfp4-uncensored' 'its own model_name'
Assert-Is $v.Cfg.port 8085 'the next port no config uses'
Assert-Is $v.Cfg.log 'M:\strata\strata-nvfp4-nvfp4-uncensored.log' 'its own log'
Assert-Is ($v.Cfg.args -join ' ') ("--pack $m\Maximilian228--Qwen3.8-Flash-Next-NVFP4-GPTQ-Strata\pack --native $m\Maximilian228--Qwen3.8-Flash-Next-NVFP4-GPTQ-Strata\qwen-nvfp4-gptq-dense.gguf --spec 3 --kv int8 " +
    "--control-vector-scaled ${vec}:1.0 --control-vector-layer-range 8 33 --cvec-mode project --cvec-dir per-layer") 'the old control vector replaced by this one'
Assert-Is $gptq.port 8083 'the original is not changed'
Assert-Is (@($gptq.args) -contains '--kv') $true 'the original args are kept'
Assert-Is (@($v.Cfg.lib_dirs).Count) 1 'one-item arrays stay arrays'
$again = New-UncensorVariant $v.Cfg $v.File $vec @(8083) ([pscustomobject]@{ port = 8086 })
Assert-Is "$($again.File) $($again.Cfg.model_name) $($again.Cfg.port)" 'strata-nvfp4-nvfp4-uncensored.json qwen3.8-flash-next-nvfp4-nvfp4-uncensored 8086' 'from a variant: the same variant, its port kept'
Assert-Is (@($again.Cfg.args | Where-Object { $_ -eq '--control-vector-scaled' }).Count) 1 'one vector, not two'

Invoke-Expression (Get-FunctionText $gui @('Get-VectorTag', 'Get-UncensorCatalogMark'))
Assert-Is (Get-VectorTag $v.Cfg) 'uncensored' 'the launch list tags the variant'
Assert-Is (Get-VectorTag ([pscustomobject]@{ args = @('--control-vector-scaled', 'M:\s\data\experimental-speed-projection\Qwen3.8-Flash-Next-experimental-speed-projection.gguf:1.0') })) 'uncensored' "Strata's speed projection is a refusal vector too"
Assert-Is (Get-VectorTag ([pscustomobject]@{ args = @('--control-vector', 'D:\v\verbosity.gguf') })) 'control vector' 'any other vector'
Assert-Is (Get-VectorTag ([pscustomobject]@{ args = @('--kv', 'int8') })) '' 'no vector, no tag'
$gplc = 'Qwen Community License 1.0 (Qwen3.8-Flash-Next''s): https://huggingface.co/Qwen/Qwen3.8-Flash-Next'
Assert-Is (Get-UncensorCatalogMark ([pscustomobject]@{ repo = 'Maximilian228/Qwen3.8-Flash-Next-NVFP4-GPTQ-Strata'; license = $gplc })) 'optional' 'Models tab: the GPTQ pack'
Assert-Is (Get-UncensorCatalogMark ([pscustomobject]@{ repo = 'Maximilian228/Qwen3.8-Flash-Next-NVIDIA-NVFP4-Strata'; license = 'NVIDIA Open Model License with Qwen terms' })) 'licence' "Models tab: NVIDIA's NVFP4"
Assert-Is (Get-UncensorCatalogMark ([pscustomobject]@{ repo = 'nvidia/Qwen3.8-Flash-Next-FP4-Local'; license = '' })) 'licence' 'Models tab: FP4-Local'
Assert-Is (Get-UncensorCatalogMark ([pscustomobject]@{ repo = $null; license = $null })) '' 'Models tab: other models blank'

Invoke-Expression (Get-FunctionText $gui @('Get-ArgValueCount', 'Split-ArgEntries'))
$se = Split-ArgEntries $v.Cfg.args
Assert-Is (($se | Where-Object { $_.Flag -eq '--control-vector-layer-range' }).Value) '8 33' 'the editor keeps both values of the layer range'
Assert-Is (($se | Where-Object { $_.Flag -eq '--kv' }).Value) 'int8' 'one-value flags as before'
Assert-Is $se.Count 8 'every flag is one entry'

$udir = Join-Path $env:TEMP "uncensor-test-$PID"; $src = Join-Path $udir 'src'; $dst = Join-Path $udir 'dst'
New-Item -ItemType Directory -Force $src | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $src 'a.gguf') -Value 'vector' -NoNewline -Encoding ascii
    Set-Content -LiteralPath (Join-Path $src 'b.md') -Value 'readme' -NoNewline -Encoding ascii
    $UncensorSource = ([Uri]$src).AbsoluteUri
    $UncensorFiles = [ordered]@{ 'a.gguf' = (Get-FileHash (Join-Path $src 'a.gguf')).Hash; 'b.md' = (Get-FileHash (Join-Path $src 'b.md')).Hash }
    Assert-Is (Get-UncensorFiles $dst) '' 'downloaded and checked'
    Assert-Is (Test-Path (Join-Path $dst 'a.gguf')) $true 'the vector is there'
    Set-Content -LiteralPath (Join-Path $dst 'b.md') -Value 'changed' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $src 'b.md') -Value 'tampered' -Encoding ascii
    Assert-Is ((Get-UncensorFiles $dst) -match 'does not match') $true 'a file that does not match its sum is refused'
    Assert-Is (Test-Path (Join-Path $dst 'b.md.part')) $false '... and deleted'
    Remove-Item -LiteralPath (Join-Path $src 'a.gguf')
    Assert-Is (@(Get-ChildItem $dst).Count) 2 'a matching file already there is not fetched again'
} finally { Remove-Item -LiteralPath $udir -Recurse -Force -ErrorAction SilentlyContinue }

if ($fails) { "`n$fails FAILED"; exit 1 }
"`nall good"