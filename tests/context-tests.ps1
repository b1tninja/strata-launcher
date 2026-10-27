# Test the context logic of strata-gui.ps1 / cline-strata.ps1 without starting either UI:
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
$launcher = 'D:\code\cline-strata.ps1'
Invoke-Expression (Get-FunctionText $launcher @('Get-ClineContext'))
Invoke-Expression (Get-FunctionText $launcher @('Resolve-ClineContext'))
$ContextReserve = 4096
$FallbackContext = 32768
Write-Host '--- Get-ClineContext (launcher)'
Assert-Is (Get-ClineContext 131072) 126976 '131072 - 4096'
Assert-Is (Get-ClineContext 1048576) 1044480 '1M - 4096'
Assert-Is (Get-ClineContext 8192) 4096 '8192 - 4096'
Assert-Is (Get-ClineContext 4096) 2048 '4096 -> half, not 0'
Assert-Is (Get-ClineContext 1024) 1024 'tiny context stays usable'
Assert-Is (Get-ClineContext 0) 0 'unknown stays 0'

# stub the health probe the extracted Resolve-ClineContext calls
$testHealth = $null
function Test-StrataHealth { [pscustomobject]@{ Context = $testHealth } }
Write-Host '--- Resolve-ClineContext (launcher)'
$testHealth = 131072; Assert-Is (Resolve-ClineContext 262144) 126976 'asked 262144 clamps to the server (the bug)'
$testHealth = 131072; Assert-Is (Resolve-ClineContext 0) 126976 'asked nothing -> the server answers'
$testHealth = 131072; Assert-Is (Resolve-ClineContext 65536) 61440 'a smaller ask is kept'
$testHealth = 0;      Assert-Is (Resolve-ClineContext 0) 28672 'server silent -> fallback, minus the reserve'
$testHealth = 0;      Assert-Is (Resolve-ClineContext 32768) 28672 'server silent, asked 32768'

# ---------------------------------------------------------------- strata-gui.ps1
$gui = 'D:\code\strata-gui\strata-gui.ps1'
Invoke-Expression (Get-FunctionText $gui @('Get-ArgValue', 'Get-RowContext', 'Get-ClineContext'))
$ClineContextReserve = 4096
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
Assert-Is (Get-ClineContext 131072) 126976 'GUI reserve matches the launcher'

# ------------------------------------------------- Ensure-ClineStrataAuth rewrites a stale window
# Run the real function against a throwaway copy of Cline's settings, so a model registered with
# too big a context is seen being repaired rather than kept because the entry already existed.
Write-Host '--- Ensure-ClineStrataAuth (launcher)'
$sandbox = Join-Path $env:TEMP ('strata-gui-tests-' + [Guid]::NewGuid().ToString('N'))
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
    Assert-Is $e.maxTokens 8192 'maxTokens filled in (min of 8192 and a quarter)'
    Assert-Is $m.providers.'openai-compatible'.provider.baseUrl 'http://127.0.0.1:8080/v1' 'base URL points at this server'
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

if ($fails) { "`n$fails FAILED"; exit 1 }
"`nall good"