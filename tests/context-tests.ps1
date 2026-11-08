# Test the context logic of strata-launcher.ps1 / cline-strata.ps1 without starting either UI:
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

# ---------------------------------------------------------------- cline-strata.ps1
$launcher = Join-Path (Split-Path -Parent $PSScriptRoot) 'cline-strata.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw "launcher not found next to the GUI: $launcher" }
Invoke-Expression (Get-FunctionText $launcher @('Get-ClineContext'))
Invoke-Expression (Get-FunctionText $launcher @('Resolve-ClineContext'))
$ContextReserve = 4096
$ReservePercent = 10
$FallbackContext = 32768
Write-Host '--- Get-ClineContext (launcher)'
# Cline sent 131118-132455-token prompts against 126976 (a flat 4096 off 131072): the reserve is a share.
Assert-Is (Get-ClineContext 131072) 117964 '131072 - 10% (13108)'
Assert-Is (Get-ClineContext 262144) 235929 '262144 - 10%'
Assert-Is (Get-ClineContext 1048576) 943718 '1M - 10%'
Assert-Is (Get-ClineContext 8192) 4096 '8192: the 4096 floor beats 10%'
$ReservePercent = 5
Assert-Is (Get-ClineContext 131072) 124518 '5% headroom'
$ReservePercent = 2   # the default since Cline CLI 3 overcounts (compacted at 325,817 real of 471,859 told)
Assert-Is (Get-ClineContext 524288) 513802 '512K - 2% (the default)'
Assert-Is (Get-ClineContext 131072) 126976 '128K at 2%: the 4096 floor beats 2%'
$ReservePercent = 10
Assert-Is (Get-ClineContext 4096) 2048 '4096 -> half, not 0'
Assert-Is (Get-ClineContext 1024) 1024 'tiny context stays usable'
Assert-Is (Get-ClineContext 0) 0 'unknown stays 0'

# stub the health probe the extracted Resolve-ClineContext calls
$testHealth = $null
function Test-StrataHealth { [pscustomobject]@{ Context = $testHealth } }
Write-Host '--- Resolve-ClineContext (launcher)'
$testHealth = 131072; Assert-Is (Resolve-ClineContext 262144) 117964 'asked 262144 clamps to the server (the bug)'
$testHealth = 131072; Assert-Is (Resolve-ClineContext 0) 117964 'asked nothing -> the server answers'
$testHealth = 131072; Assert-Is (Resolve-ClineContext 65536) 58982 'a smaller ask is kept'
$testHealth = 0;      Assert-Is (Resolve-ClineContext 0) 28672 'server silent -> fallback, minus the reserve'
$testHealth = 0;      Assert-Is (Resolve-ClineContext 32768) 28672 'server silent, asked 32768'

# ---------------------------------------------------------------- strata-launcher.ps1
$gui = Join-Path (Split-Path -Parent $PSScriptRoot) 'strata-launcher.ps1'
Invoke-Expression (Get-FunctionText $gui @('Get-ArgValue', 'Get-CtxOverride', 'Get-RowContext', 'Get-ClineContext',
    'Get-RopeScale', 'Set-ArgValue', 'Remove-Arg', 'Set-ContextArgs'))
$ClineContextReserve = 4096
$ClineReservePercent = 10
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
Assert-Is (Get-RowContext $noCfg) 0 'nothing known -> 0 (Open Cline refuses instead of guessing)'
Assert-Is (Get-ClineContext 131072) 117964 'GUI reserve matches the launcher'
# the two scripts' defaults stay in step
$guiDefault = [regex]::Match((Get-Content -LiteralPath $gui -Raw), '(?m)^\$ClineReservePercent = (\d+)').Groups[1].Value
$lnDefault = [regex]::Match((Get-Content -LiteralPath $launcher -Raw), '\[int\]\$ReservePercent = (\d+)').Groups[1].Value
Assert-Is $guiDefault $lnDefault 'the GUI''s default headroom is cline-strata.ps1''s'
Assert-Is $guiDefault '2' 'default headroom'
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

# ------------------------------------------------- Ensure-ClineStrataAuth rewrites a stale window
# Run the real function against a throwaway copy of Cline's settings, so a model registered with
# too big a context is seen being repaired rather than kept because the entry already existed.
Write-Host '--- Ensure-ClineStrataAuth (launcher)'
$sandbox = Join-Path $env:TEMP ('strata-launcher-tests-' + [Guid]::NewGuid().ToString('N'))
$settings = Join-Path $sandbox '.cline\data\settings'
New-Item -ItemType Directory -Path $settings | Out-Null
@'
{ "version": 1, "providers": { "openai-compatible": {
    "provider": { "name": "OpenAI Compatible", "baseUrl": "http://127.0.0.1:9999/v1", "defaultModelId": "old-model" },
    "models": { "qwen-test": { "id": "qwen-test", "name": "qwen-test", "contextWindow": 262144,
                               "maxInputTokens": 262144, "capabilities": ["streaming","tools"] } }
} } }
'@ | Set-Content -LiteralPath (Join-Path $settings 'models.json') -Encoding ascii
'{"lastUsedProvider":"cline","providers":{"openai-compatible":{"settings":{"baseUrl":"http://127.0.0.1:9999/v1","model":"old-model","apiKey":"local","contextWindow":262144,"timeout":600000}}}}' |
    Set-Content -LiteralPath (Join-Path $settings 'providers.json') -Encoding ascii
# Legacy globalState: Cline re-imports it into providers.json on start, so a window that is too
# big in here can undo the repair above. planMode's info has no window at all (must be inserted),
# and the distractor block must keep its own unrelated 262144.
'{"openAiBaseUrl":"http://127.0.0.1:9999/v1","actModeOpenAiModelId":"old-model","planModeOpenAiModelId":"old-model",' +
'"actModeOpenAiModelInfo":{"contextWindow":262144,"supportsImages":false,"inputPrice":0},' +
'"planModeOpenAiModelInfo":{"supportsImages":false},' +
'"someOtherState":{"contextWindow":262144}}' |
    Set-Content -LiteralPath (Join-Path $sandbox '.cline\data\globalState.json') -Encoding ascii

$fakeCline = Join-Path $sandbox 'cline-auth.cmd'
'@exit /b 0' | Set-Content -LiteralPath $fakeCline -Encoding ascii
function Get-ClineCommand { $fakeCline }
$Provider = 'openai-compatible'
$ApiKey = 'local'
$StrataBase = 'http://127.0.0.1:8080'
Invoke-Expression (Get-FunctionText $launcher @('Ensure-ClineStrataAuth'))
$oldProfile = $env:USERPROFILE
try {
    $env:USERPROFILE = $sandbox
    [void](Ensure-ClineStrataAuth -ModelId 'qwen-test' -Tokens 126976)
    $m = Get-Content -LiteralPath (Join-Path $settings 'models.json') -Raw | ConvertFrom-Json
    $e = $m.providers.'openai-compatible'.models.'qwen-test'
    Assert-Is $e.contextWindow 126976 'an existing entry gets the server context (was stuck at 262144)'
    Assert-Is $e.maxInputTokens 126976 'maxInputTokens follows'
    Assert-Is $e.maxTokens 31744 'maxTokens filled in (a quarter of the context, at most 32768)'
    $mPath = Join-Path $settings 'models.json'
    foreach ($case in @(@(8192, 31744, 'the old 8192 default is raised'), @(12000, 12000, 'a cap of your own is kept'))) {
        $j = Get-Content -LiteralPath $mPath -Raw | ConvertFrom-Json
        $j.providers.'openai-compatible'.models.'qwen-test'.maxTokens = $case[0]
        [IO.File]::WriteAllText($mPath, ($j | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
        [void](Ensure-ClineStrataAuth -ModelId 'qwen-test' -Tokens 126976)
        Assert-Is (Get-Content -LiteralPath $mPath -Raw | ConvertFrom-Json).providers.'openai-compatible'.models.'qwen-test'.maxTokens $case[1] $case[2]
    }
    $m = Get-Content -LiteralPath $mPath -Raw | ConvertFrom-Json
    Assert-Is $m.providers.'openai-compatible'.provider.baseUrl 'http://127.0.0.1:8080/v1' 'base URL points at this server'
    # Cline's JSON.parse rejects a byte-order mark and then rebuilds the provider without contextWindow,
    # which turns its automatic compaction off: both files must be plain UTF-8.
    foreach ($f in 'models.json', 'providers.json') {
        $b = [IO.File]::ReadAllBytes((Join-Path $settings $f))
        Assert-Is ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) $false "$f has no byte-order mark"
    }
    $p = Get-Content -LiteralPath (Join-Path $settings 'providers.json') -Raw | ConvertFrom-Json
    Assert-Is $p.providers.'openai-compatible'.settings.contextWindow 126976 'providers.json gets it too'
    $g = Get-Content -LiteralPath (Join-Path $sandbox '.cline\data\globalState.json') -Raw | ConvertFrom-Json
    Assert-Is $g.actModeOpenAiModelInfo.contextWindow 126976 'legacy act-mode window follows the server'
    Assert-Is $g.planModeOpenAiModelInfo.contextWindow 126976 'legacy plan-mode window is inserted when missing'
    Assert-Is $g.someOtherState.contextWindow 262144 'an unrelated block keeps its own number'
    Assert-Is $g.openAiBaseUrl 'http://127.0.0.1:8080/v1' 'legacy base URL follows this server'
    Assert-Is $g.actModeOpenAiModelId 'qwen-test' 'legacy model id follows'
} finally {
    $env:USERPROFILE = $oldProfile
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

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
Invoke-Expression (Get-FunctionText $gui @('Get-BaseUrl', 'Get-ContinueConfigText', 'Get-ContinueVsix'))
Write-Host '--- Continue config and VSIX'
$crow = [pscustomobject]@{ Model = 'qwen3.8-flash-next-nvfp4-nvfp4'; Port = 8083 }
$ctext = Get-ContinueConfigText $crow 524288 'xhigh' 'low'
Assert-Is (@($ctext -split "`n" | Where-Object { $_ -match '^  - name: Strata qwen3\.8-flash-next-nvfp4-nvfp4 - (plan|act)' }).Count) 2 'a plan and an act entry'
Assert-Is ($ctext -match 'reasoning_effort: xhigh' -and $ctext -match 'reasoning_effort: low') $true 'each entry carries its thinking level'
Assert-Is ($ctext -match 'apiBase: http://127\.0\.0\.1:8083/v1' -and $ctext -match 'contextLength: 524288' -and $ctext -match 'capabilities: \[tool_use\]') $true 'endpoint, context and tool use'
Assert-Is ($ctext -match 'maxTokens: 32768') $true 'answer cap with room for xhigh thinking'
Assert-Is ((Get-ContinueConfigText $crow 65536 '' 'low') -match 'maxTokens: 16384') $true 'a quarter of a small context'
Assert-Is ((Get-ContinueConfigText $crow 1000 '' 'low') -match '(?s)- plan\s*\n.*?\n  - name') $true 'no level: no thinking suffix and no requestOptions'
Assert-Is ($ctext -match '(?s)  - name: Strata qwen3\.8-flash-next-nvfp4-nvfp4 - autocomplete\s*\n.*roles: \[autocomplete\]') $true 'an autocomplete entry'
Assert-Is ($ctext -match 'useLegacyCompletionsEndpoint: false' -and $ctext -match 'enable_thinking: false' -and $ctext -match 'modelTimeout: 1000') $true 'Tab over chat, no thinking, a timeout that fits'
Assert-Is (@($ctext -split "`n" | Where-Object { $_ -match 'roles: \[autocomplete\]' }).Count) 1 'only the Tab entry autocompletes'
Assert-Is ($ctext -match '[^\x00-\x7F]') $false 'plain ASCII'
$vdir = Join-Path $env:TEMP "vsix-test-$PID"; New-Item -ItemType Directory -Force $vdir | Out-Null
try {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $newVsix = {
        param($name, $publisher, $id, $version)
        $zip = [IO.Compression.ZipFile]::Open((Join-Path $vdir $name), 'Create')
        try {
            $w = New-Object IO.StreamWriter($zip.CreateEntry('extension.vsixmanifest').Open())
            $w.Write("<PackageManifest Version=`"2.0.0`" xmlns=`"http://schemas.microsoft.com/developer/vsx-schema/2011`"><Metadata>" +
                "<Identity Language=`"en-US`" Id=`"$id`" Version=`"$version`" Publisher=`"$publisher`"/></Metadata></PackageManifest>")
            $w.Close()
        } finally { $zip.Dispose() }
    }
    & $newVsix 'continue-1.3.40.vsix' 'Continue' 'continue' '1.3.40'
    Start-Sleep -Milliseconds 50
    & $newVsix 'continued-win32-x64-1.3.40-3e4599d.vsix' 'b1tninja' 'continued' '1.3.40-3e4599d'
    Set-Content -LiteralPath (Join-Path $vdir 'other.vsix') -Value 'x'
    $v = Get-ContinueVsix $vdir
    Assert-Is "$($v.Id) $($v.Version)" 'b1tninja.continued 1.3.40-3e4599d' 'a folder: the newest continue*.vsix, id and version from its manifest'
    Assert-Is (Get-ContinueVsix (Join-Path $vdir 'continue-1.3.40.vsix')).Id 'Continue.continue' 'a file: that file'
    Assert-Is (Get-ContinueVsix (Join-Path $vdir 'other.vsix')) $null 'not a package'
    Assert-Is (Get-ContinueVsix (Join-Path $vdir 'missing')) $null 'nothing there'
} finally { Remove-Item -LiteralPath $vdir -Recurse -Force -ErrorAction SilentlyContinue }

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