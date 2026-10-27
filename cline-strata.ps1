# Drop a folder on a "Cline Strata" shortcut, or double-click and
# pick a folder. Starts / waits for Strata (Orca IQ3_XXS), points Cline at it.
param(
    [Parameter(Position = 0)]
    [string]$Folder,
    [string]$Model = 'orcarouter-qwen3.8-flash-next-uncensored-iq3_xxs',
    [string]$Thinking,
    [double]$Temperature,
    # Tokens Cline may fill before it compacts. 0 (default): what the server itself reports as its
    # context - an asked-for value larger than the engine's is refused by it, request after request.
    [int]$Context = 0,
    # Share of the context held back from Cline (at least $ContextReserve tokens) - see Get-ClineContext.
    [ValidateRange(1, 50)]
    [int]$ReservePercent = 10,
    [string]$StrataRoot = 'M:\GITHUB\niko1221\strata',
    [string]$StartScript = 'run-orca-iq3_xxs.bat',
    [string]$StrataBase = 'http://127.0.0.1:8081',
    [string]$Provider = 'openai-compatible',
    [switch]$RestartStrata
)

$ErrorActionPreference = 'Continue'
$DefaultFolder = 'D:\code'
$ThinkingLevels = @('none', 'low', 'medium', 'high', 'xhigh')
$ApiKey = 'local'
$ContextReserve = 4096     # the least held back, whatever the percentage - see Get-ClineContext
$FallbackContext = 32768   # what to assume when the server cannot say (engine not loaded yet)

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
    $npm = Join-Path $env:APPDATA 'npm'
    if (Test-Path -LiteralPath $npm) { $env:Path = "$npm;$env:Path" }
}

function Test-StrataHealth {
    try {
        $r = Invoke-RestMethod -Uri "$StrataBase/health" -TimeoutSec 3
        return [pscustomobject]@{
            Up      = $true
            Loaded  = [bool]$r.loaded
            Model   = [string]$r.model
            Context = if ($null -ne $r.max_context) { [int]$r.max_context } else { 0 }
            Raw     = $r
        }
    } catch {
        return [pscustomobject]@{ Up = $false; Loaded = $false; Model = ''; Context = 0; Raw = $null }
    }
}

# The context Cline is told the model's window is: a little under what the server really has.
# Cline compacts once its own estimate of the prompt reaches 0.9 of the number it is given, and a
# Strata server never truncates: a prompt over the engine's window is refused with a 400, and so
# is every request that follows it - the session cannot get back under the window by itself. So a
# context larger than the server's is the one setting that can never be too high. The reserve
# covers the difference between Cline's estimate (~chars/4, without the ChatML template, the tool
# schemas or the image tokens the engine counts), the server's own 8-token slack, and the answer.
# That error is a share of the prompt, not a fixed number: with 4096 held back from 131072, Cline's
# log shows it still sent 131118-132455-token prompts (~4.5% over what it believed), so the reserve
# is $ReservePercent of the context (10%: ~7.7K left for the answer at 128K), never under 4096.
function Get-ClineContext([int64]$Ctx) {
    if ($Ctx -le 0) { return 0 }
    $half = [int64][Math]::Max(1024, [int][Math]::Ceiling($Ctx * 0.5))
    $reserve = [Math]::Max([int64]$ContextReserve, [int64][Math]::Ceiling($Ctx * $ReservePercent / 100.0))
    return [Math]::Max($half, $Ctx - $reserve)
}

# What Cline may use, settled against what this server actually serves: an asked-for context
# bigger than the engine's is cut down to its own (a value too big is not "more room", it is a
# server that stops answering), and a context nobody asked for comes from the server itself.
function Resolve-ClineContext([int]$Asked) {
    $h = Test-StrataHealth
    $has = [int64] $h.Context
    if ($has -le 0) {
        Write-Host "Server does not report a context (engine not loaded?); assuming $FallbackContext tokens."
        if ($Asked -le 0) { $Asked = $FallbackContext }
    } elseif ($Asked -le 0) {
        $Asked = [int]$has
        Write-Host "Context: $Asked tokens (what the server reports)."
    } elseif ($Asked -gt $has) {
        Write-Host "Asked for $Asked tokens but this server only has $has; using its own."
        $Asked = [int]$has
    }
    $cline = [int](Get-ClineContext $Asked)
    Write-Host "Cline is pointed at $cline tokens ($($Asked - $cline) held back so it compacts before the server refuses)."
    return $cline
}

function Stop-Strata {
    Write-Host 'Stopping Strata...'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and (
            $_.CommandLine -match [regex]::Escape($StrataRoot) -or
            $_.CommandLine -match 'run-orca-iq3_xxs|strata-orca|strata\.exe|--pack.*orca-iq3'
        ) -and (
            $_.Name -match '^(cmd|python|strata)\.exe$' -or
            $_.CommandLine -match 'serve\\server\.py|run-orca'
        )
    } | ForEach-Object {
        Write-Host "  stop $($_.ProcessId) $($_.Name)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
    # Narrow catch for engine left behind
    Get-Process -Name strata -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $h = Test-StrataHealth
        if (-not $h.Up) { return $true }
        Start-Sleep -Seconds 1
    }
    return -not (Test-StrataHealth).Up
}

function Start-StrataProcess {
    $bat = Join-Path $StrataRoot $StartScript
    if (-not (Test-Path -LiteralPath $bat)) {
        Write-Host "Missing start script: $bat"
        return $false
    }
    Write-Host "Starting Strata ($StartScript)..."
    Start-Process -FilePath $bat -WorkingDirectory $StrataRoot
    return $true
}

function Wait-StrataReady {
    param([int]$Minutes = 10)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        $health = Test-StrataHealth
        if ($health.Up -and $health.Loaded) {
            Write-Host "Strata ready: $($health.Model)  context=$($health.Context)"
            return $true
        }
        if ($health.Up) {
            Write-Host 'Strata is up; waiting for model load...'
        } else {
            Write-Host 'Waiting for Strata /health...'
        }
        Start-Sleep -Seconds 5
    }
    Write-Host 'Strata did not become ready in time. Check its window / strata-orca-iq3_xxs.log'
    return $false
}

function Ensure-StrataModel {
    param([switch]$ForceRestart)

    $health = Test-StrataHealth
    if ($ForceRestart -or $RestartStrata) {
        if ($health.Up) { [void](Stop-Strata) }
        if (-not (Start-StrataProcess)) { return $false }
        return (Wait-StrataReady)
    }

    if ($health.Up -and $health.Loaded) {
        Write-Host "Strata already loaded: $($health.Model)  context=$($health.Context)"
        if ($Model -and $health.Model -and ($health.Model -ne $Model)) {
            Write-Host "Note: loaded model '$($health.Model)' differs from expected '$Model'."
        }
        return $true
    }

    if ($health.Up -and -not $health.Loaded) {
        Write-Host 'Strata is running but the model is not loaded yet.'
        return (Wait-StrataReady)
    }

    # Free a competing Ollama GPU model if one is sitting there
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        try {
            $ps = & ollama ps 2>$null | Out-String
            if ($ps -match 'NAME') {
                Write-Host 'Unloading Ollama models so Strata can use the GPU...'
                & ollama ps 2>$null | Select-Object -Skip 1 | ForEach-Object {
                    if ($_ -match '^\s*(\S+)') {
                        $name = $Matches[1]
                        if ($name -and $name -ne 'NAME') {
                            Write-Host "  ollama stop $name"
                            & ollama stop $name 2>$null | Out-Null
                        }
                    }
                }
            }
        } catch {}
    }

    if (-not (Start-StrataProcess)) { return $false }
    return (Wait-StrataReady)
}

function Select-FolderDialog {
    param([string]$Initial)
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the folder Cline should open (repo root)'
    $dialog.ShowNewFolderButton = $false
    if ($Initial -and (Test-Path -LiteralPath $Initial -PathType Container)) {
        $dialog.SelectedPath = $Initial
    } elseif (Test-Path -LiteralPath $DefaultFolder -PathType Container) {
        $dialog.SelectedPath = $DefaultFolder
    }
    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    $path = $dialog.SelectedPath
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { return $null }
    return (Resolve-Path -LiteralPath $path).Path
}

function Get-ClineCommand {
    Update-SessionPath
    $cmd = Get-Command cline -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($name in @('cline.cmd', 'cline.ps1', 'cline')) {
        $candidate = Join-Path $env:APPDATA "npm\$name"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Ensure-Cline {
    if (Get-ClineCommand) { return $true }
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Host 'npm/winget missing. Install Node.js LTS, then try again.'
            return $false
        }
        Write-Host 'Installing Node.js LTS...'
        & winget install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements --disable-interactivity
        Update-SessionPath
    }
    Write-Host 'Installing Cline...'
    & npm install -g cline
    Update-SessionPath
    return [bool](Get-ClineCommand)
}

function Ensure-ClineStrataAuth {
    param(
        [string]$ModelId,
        [int]$Tokens
    )
    $cline = Get-ClineCommand
    if (-not $cline) {
        Write-Host 'cline not found on PATH.'
        return $false
    }
    $base = "$StrataBase/v1"
    Write-Host "Pointing Cline at Strata ($base)..."
    & $cline auth -p $Provider -m $ModelId -b $base -k $ApiKey
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'cline auth failed.'
        return $false
    }

    $providersPath = Join-Path $env:USERPROFILE '.cline\data\settings\providers.json'
    if (Test-Path -LiteralPath $providersPath) {
        try {
            $cfg = Get-Content -LiteralPath $providersPath -Raw | ConvertFrom-Json
            $cfg.lastUsedProvider = $Provider
            $settings = $cfg.providers.$Provider.settings
            if ($settings) {
                $settings | Add-Member -NotePropertyName baseUrl -NotePropertyValue $base -Force
                $settings | Add-Member -NotePropertyName model -NotePropertyValue $ModelId -Force
                $settings | Add-Member -NotePropertyName apiKey -NotePropertyValue $ApiKey -Force
                $settings | Add-Member -NotePropertyName contextWindow -NotePropertyValue $Tokens -Force
                $settings | Add-Member -NotePropertyName timeout -NotePropertyValue 600000 -Force
                $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $providersPath -Encoding utf8
            }
        } catch {
            Write-Host "Could not patch providers.json: $_"
        }
    }

    $modelsPath = Join-Path $env:USERPROFILE '.cline\data\settings\models.json'
    if (Test-Path -LiteralPath $modelsPath) {
        try {
            $json = Get-Content -LiteralPath $modelsPath -Raw | ConvertFrom-Json
            $prov = $json.providers.$Provider
            $changed = $false
            if ($prov.provider) {
                $prov.provider | Add-Member -NotePropertyName baseUrl -NotePropertyValue $base -Force
                $prov.provider | Add-Member -NotePropertyName defaultModelId -NotePropertyValue $ModelId -Force
                $changed = $true
            }
            $models = $prov.models
            if ($models) {
                if (-not ($models.PSObject.Properties.Name -contains $ModelId)) {
                    $entry = [pscustomobject]@{
                        id             = $ModelId
                        name           = $ModelId
                        capabilities   = @('streaming', 'tools')
                    }
                    $models | Add-Member -NotePropertyName $ModelId -NotePropertyValue $entry
                    $changed = $true
                } else {
                    $entry = $models.$ModelId
                }
                # The window is written every time, not only when the model is first seen: an entry that was
                # once registered with a larger context keeps Cline filling past what this server answers,
                # and nothing else in the file ever notices.
                if ($entry.contextWindow -ne $Tokens -or $entry.maxInputTokens -ne $Tokens) {
                    $entry | Add-Member -NotePropertyName contextWindow -NotePropertyValue $Tokens -Force
                    $entry | Add-Member -NotePropertyName maxInputTokens -NotePropertyValue $Tokens -Force
                    $changed = $true
                }
                $maxOut = [Math]::Min(8192, [int]($Tokens / 4))
                if ($null -eq $entry.maxTokens) {
                    $entry | Add-Member -NotePropertyName maxTokens -NotePropertyValue $maxOut -Force
                    $changed = $true
                }
            }
            if ($changed) { $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $modelsPath -Encoding utf8 }
        } catch {
            Write-Host "Could not patch models.json: $_"
        }
    }

    # Cline re-imports its legacy globalState.json into providers.json when it starts, which put back an
    # old base URL (another port). Point the legacy OpenAI keys at this server too. Plain text edits: the
    # file is large and only these string values change.
    $statePath = Join-Path $env:USERPROFILE '.cline\data\globalState.json'
    if (Test-Path -LiteralPath $statePath) {
        try {
            $text = [IO.File]::ReadAllText($statePath)
            $new = $text
            $values = @{
                'openAiBaseUrl'         = $base
                'actModeOpenAiModelId'  = $ModelId
                'planModeOpenAiModelId' = $ModelId
            }
            foreach ($key in $values.Keys) {
                $value = $values[$key]
                $new = [regex]::Replace($new, '("' + $key + '"\s*:\s*)"[^"]*"', { param($m) $m.Groups[1].Value + '"' + $value + '"' })
            }
            # ...and the window inside the legacy model info. A stale number there is the one
            # setting that cannot be too high: Cline compacts at 0.9 of the window it is told and a
            # Strata server never truncates, so a window larger than the engine's rides straight into
            # a 400 that every later request repeats. Rewritten on every run, like models.json.
            foreach ($infoKey in @('actModeOpenAiModelInfo', 'planModeOpenAiModelInfo')) {
                $new = [regex]::Replace($new, '("' + $infoKey + '"\s*:\s*\{)([^}]*)(\})', {
                    param($m)
                    $body = $m.Groups[2].Value
                    if ([regex]::IsMatch($body, '"contextWindow"\s*:\s*[0-9]+')) {
                        $body = [regex]::Replace($body, '("contextWindow"\s*:\s*)[0-9]+', ('${1}' + $Tokens))
                    } else {
                        $body = '"contextWindow":' + $Tokens + ',' + $body.TrimStart()
                    }
                    $m.Groups[1].Value + $body + $m.Groups[3].Value
                })
            }
            if ($new -ne $text) {
                [IO.File]::WriteAllText($statePath, $new, (New-Object Text.UTF8Encoding $false))
            }
        } catch {
            Write-Host "Could not patch globalState.json: $_"
        }
    }
    return $true
}

Update-SessionPath

if ($Thinking -and ($ThinkingLevels -notcontains $Thinking)) {
    Write-Host "Thinking must be one of: $($ThinkingLevels -join ', ')"
    return
}

# Folder browser needs STA
if (-not $Folder -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $forward = @('-NoExit', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($PSBoundParameters.ContainsKey('Model')) { $forward += @('-Model', $Model) }
    if ($PSBoundParameters.ContainsKey('Thinking')) { $forward += @('-Thinking', $Thinking) }
    if ($PSBoundParameters.ContainsKey('Temperature')) { $forward += @('-Temperature', ([string]$Temperature)) }
    if ($PSBoundParameters.ContainsKey('Context')) { $forward += @('-Context', ([string]$Context)) }
    if ($RestartStrata) { $forward += '-RestartStrata' }
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $forward
    exit
}

if ($Folder) {
    $Folder = $Folder.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        Write-Host "Not a folder: $Folder"
        return
    }
    $Folder = (Resolve-Path -LiteralPath $Folder).Path
} else {
    Write-Host 'No folder dropped — choose a repo folder.'
    $Folder = Select-FolderDialog -Initial $DefaultFolder
    if (-not $Folder) {
        Write-Host 'Cancelled.'
        return
    }
}

Write-Host "Folder: $Folder"
Write-Host '---- Strata ----'
if (-not (Ensure-StrataModel)) { return }
if (-not (Ensure-Cline)) { return }
Write-Host '---- Context ----'
$ClineContext = Resolve-ClineContext $Context
if (-not (Ensure-ClineStrataAuth -ModelId $Model -Tokens $ClineContext)) { return }

$health = Test-StrataHealth
Write-Host "API: $StrataBase/v1  model=$($health.Model)  context=$($health.Context)"

Set-Location -LiteralPath $Folder
$cline = Get-ClineCommand
$clineArgs = @('-i', '-P', $Provider, '-m', $Model)
if ($Thinking) { $clineArgs += @('--thinking', $Thinking) }
Write-Host "Cline in $Folder  provider=$Provider  model=$Model  thinking=$Thinking"
& $cline @clineArgs
