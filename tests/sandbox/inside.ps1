# Runs inside Windows Sandbox (run-sandbox.ps1 starts it at logon): does what a first-time user does,
# checks each result, and writes log.txt, screenshots and done.txt (PASS/FAIL) to C:\out.
# Installs with strata-launcher-setup.cmd (the release's download, which runs the one-line web install from GitHub's main);
# -Local: installs the copy of this repository mapped into the sandbox instead.
param([switch]$SkipPcCheck, [switch]$Local)
$ErrorActionPreference = 'Continue'
$out = 'C:\out'
$src = 'C:\strata-launcher-src'
$gui = if ($Local) { Join-Path $env:USERPROFILE 'strata-launcher' } else { Join-Path $env:LOCALAPPDATA 'Programs\strata-launcher' }
$installUrl = 'https://raw.githubusercontent.com/b1tninja/strata-launcher/main/install.ps1'
$script:fails = 0
$script:shot = 0
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
$A = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]

function Log([string]$m) {
    # the host reads this file while the test writes it, and a write to the mapped folder then fails now
    # and again: try again rather than lose the line
    $line = "{0:HH:mm:ss}  {1}" -f (Get-Date), $m
    for ($i = 0; $i -lt 20; $i++) {
        try { Add-Content -LiteralPath "$out\log.txt" -Encoding UTF8 -Value $line -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 250 }
    }
}
function Check([bool]$ok, [string]$what) { if ($ok) { Log "ok    $what" } else { $script:fails++; Log "FAIL  $what" } }
function Shot([string]$name) {
    $script:shot++
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save(("{0}\{1:00}-{2}.png" -f $out, $script:shot, $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}
Add-Type -Namespace SbTest -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr h, System.IntPtr dc, uint flags); [DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r); public struct RECT { public int L, T, R, B; }'
function Shot-Window($el, [string]$name) {
    # The launcher's window alone, for the README.
    $h = [IntPtr]$el.Current.NativeWindowHandle
    $r = New-Object SbTest.W+RECT; [void][SbTest.W]::GetWindowRect($h, [ref]$r)
    $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
    $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
    [void][SbTest.W]::PrintWindow($h, $dc, 2); $g.ReleaseHdc($dc)
    $bmp.Save("$out\window-$name.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}
function Wait-Until([scriptblock]$Test, [int]$Seconds) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) { $r = & $Test; if ($r) { return $r }; Start-Sleep -Milliseconds 700 }
    return $null
}
function Top([int]$ProcessId) { @($A::RootElement.FindAll('Children', (New-Object System.Windows.Automation.PropertyCondition -ArgumentList $A::ProcessIdProperty, $ProcessId))) }
function All($el) { $el.FindAll('Descendants', [System.Windows.Automation.Condition]::TrueCondition) }
function ById($el, [string]$id) { All $el | Where-Object { $_.Current.AutomationId -eq $id } | Select-Object -First 1 }
function Value($el) { $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value }
function Press($el) { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
function Confirm-Box([int]$ProcessId) {
    # A MessageBox (class #32770) of the GUI: read it, then accept its default button.
    $box = Wait-Until { Top $ProcessId | ForEach-Object { $_; @($_.FindAll('Children', [System.Windows.Automation.Condition]::TrueCondition)) } |
                        Where-Object { $_.Current.ClassName -eq '#32770' } | Select-Object -First 1 } 20
    if (-not $box) { return $null }
    # MessageBox text comes through UI Automation as a pane, not a text element
    $text = (All $box | Where-Object { $_.Current.Name -and $_.Current.Name.Length -gt 12 } | ForEach-Object { $_.Current.Name }) -join ' / '
    [Microsoft.VisualBasic.Interaction]::AppActivate($box.Current.Name) 2>$null
    Start-Sleep -Milliseconds 400
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    return $text
}
function Setup-Steps($win) {
    $tab = All $win | Where-Object { $_.Current.ControlType -eq $CT::TabItem -and $_.Current.Name -eq '  Setup  ' } | Select-Object -First 1
    @(All $tab | Where-Object { $_.Current.ControlType -eq $CT::Text -and $_.Current.Name } | ForEach-Object { $_.Current.Name })
}
function Run-Step($win, [int]$ProcessId, [string]$Button, [string]$Key, [int]$Seconds) {
    # Press a Setup step's button, accept its confirmation, wait for its console's done marker.
    $b = All $win | Where-Object { $_.Current.ControlType -eq $CT::Button -and $_.Current.Name -eq $Button } | Select-Object -First 1
    if (-not $b) { Check $false "button '$Button' is offered"; return $false }
    Remove-Item -LiteralPath (Join-Path $env:TEMP "strata-launcher\setup-$Key.done") -ErrorAction SilentlyContinue   # a marker left by an earlier step
    Press $b
    Log "confirm ($Button): $(Confirm-Box $ProcessId)"
    $marker = Join-Path $env:TEMP "strata-launcher\setup-$Key.done"
    $ok = Wait-Until { Test-Path $marker } $Seconds
    Check ([bool]$ok) "'$Button' finished within $Seconds s"
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match "setup-$Key\.ps1" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }   # close its window
    Start-Sleep 12   # the tab re-checks on its own
    return [bool]$ok
}
function Step-Text($win) { (Setup-Steps $win) -join ' | ' }

function Done([string]$why) {
    if ($why) { $script:fails++; Log "FAIL  $why" }
    Set-Content -LiteralPath "$out\done.txt" -Value $(if ($script:fails) { "FAIL ($($script:fails))" } else { 'PASS' })
    # Shut the sandbox down from the inside: closing its window from the host leaves the VM logging off,
    # and the next sandbox then attaches to that dying session.
    & shutdown.exe /s /t 5 /f
    exit
}

Log "clean PC: winget=$([bool](Get-Command winget -EA SilentlyContinue)) git=$([bool](Get-Command git -EA SilentlyContinue)) python=$([bool](Get-Command python -EA SilentlyContinue | Where-Object { $_.Source -notmatch 'WindowsApps' })) node=$([bool](Get-Command node -EA SilentlyContinue)) nvidia-smi=$([bool](Get-Command nvidia-smi -EA SilentlyContinue))"

# 1. install: the one-line web install a new user runs (it starts the launcher itself), or -Local: this repository's copy
if ($Local) {
    Copy-Item -LiteralPath $src -Destination $gui -Recurse
    foreach ($n in 'strata-launcher.settings.json', 'strata-gui.settings.json') { Remove-Item -LiteralPath (Join-Path $gui $n) -ErrorAction SilentlyContinue }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $gui 'install.ps1') -NoStart *>> "$out\install.txt"
} else {
    Log "> strata-launcher-setup.cmd (runs: irm $installUrl | iex)"
    & cmd.exe /c "$src\strata-launcher-setup.cmd" *>> "$out\install.txt"
    Check ($LASTEXITCODE -eq 0) 'strata-launcher-setup.cmd finished'
    Check (Test-Path (Join-Path $gui 'strata-launcher.ps1')) 'one-line install: the launcher is in LocalAppData\Programs'
}
Check (Test-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Strata Launcher.lnk')) 'install.ps1: desktop shortcut'
Check (Test-Path (Join-Path ([Environment]::GetFolderPath('Programs')) 'Strata Launcher.lnk')) 'install.ps1: Start menu shortcut'
Check ((Get-ItemProperty 'HKCU:\Software\StrataLauncher' -EA SilentlyContinue).AppDir -eq $gui) 'install.ps1: AppDir in the registry'
$appsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\StrataLauncher'
$entry = Get-ItemProperty $appsKey -EA SilentlyContinue
Log "Settings > Apps: $($entry.DisplayName) $($entry.DisplayVersion), $([int]($entry.EstimatedSize / 1024)) MB, uninstall: $($entry.UninstallString)"
Check ($entry.DisplayName -eq 'Strata Launcher' -and $entry.DisplayVersion -match '^\d+\.\d+') 'install.ps1: listed in Settings > Apps with its version'

# 2. first start: the dialog, on a PC without Strata (the web install has started the launcher already)
if ($Local) {
    $p = Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$gui\strata-launcher.ps1`"" -PassThru `
        -RedirectStandardError "$out\gui-err.txt" -WindowStyle Hidden
} else {
    $p = Wait-Until { Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'strata-launcher\.ps1' } |
                      ForEach-Object { Get-Process -Id $_.ProcessId } | Select-Object -First 1 } 30
    if (-not $p) { Shot 'not-started'; Done 'the one-line install did not start the launcher' }
}
$dlg = Wait-Until { Top $p.Id | Where-Object { $_.Current.Name -eq 'Set up Strata' } | Select-Object -First 1 } 90
if (-not $dlg) { Shot 'no-dialog'; Done 'the first-run dialog did not appear' }
Start-Sleep 2; Shot 'first-run-dialog'
$root = Value (ById $dlg 'RootBox'); $data = Value (ById $dlg 'DataBox'); $go = ById $dlg 'Go'
Log "dialog: root=$root data=$data button='$($go.Current.Name)' hint='$((ById $dlg 'Hint').Current.Name)'"
Check ($root -eq 'C:\Strata') 'dialog suggests C:\Strata'
Check ($go.Current.Name -eq 'Download Strata here' -and $go.Current.IsEnabled) 'dialog offers "Download Strata here"'
Press $go

# 3. the download starts by itself once the window is up (after its confirmation)
$win = Wait-Until { Top $p.Id | Where-Object { $_.Current.Name -eq 'Strata Launcher' } | Select-Object -First 1 } 60
if (-not $win) { Shot 'no-main-window'; Done 'the main window did not appear' }
$confirm = Confirm-Box $p.Id
Log "confirm: $confirm"
Check ($confirm -match 'Download Strata into') 'the download asks first'
Check ($confirm -match 'zip') 'without Git it says it uses the zip'
$marker = Join-Path $env:TEMP 'strata-launcher\setup-strata.done'
$ok = Wait-Until { Test-Path $marker } 600
Shot 'after-download'
Check ([bool]$ok) 'the download window finished'
Check (Test-Path 'C:\Strata\START-HERE.bat') 'Strata is in C:\Strata'
Start-Sleep 12
$steps = Setup-Steps $win
Log 'setup steps:'; $steps | ForEach-Object { Log "    $_" }
Check (($steps -join ' ') -match 'In C:\\Strata') 'Setup tab: Strata found'
Check (($steps -join ' ') -match 'No NVIDIA or AMD graphics card') 'Setup tab: no GPU in the sandbox is reported'
Check (($steps -join ' ') -match 'installs Python for your account') 'Setup tab: the PC check is offered next to Strata'
$status = (ById $win 'StatusText').Current.Name
Check ($status -notmatch 'No Strata in') "status bar no longer says Strata is missing ('$status')"
Shot 'setup-tab'

# 4. Git without winget: the portable MinGit
if (Run-Step $win $p.Id 'Install Git (portable)' 'git' 300) {
    Check ((Step-Text $win) -match 'Git \d') 'Setup tab: Git found after the portable install'
    Check (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\MinGit\cmd\git.exe')) 'MinGit is in LocalAppData\Programs'
}
Shot 'after-git'

# 5. the PC check: uv makes .venv with Strata's Python, then Strata's START-HERE.bat --check installs its packages
if (-not $SkipPcCheck) {
    $t0 = Get-Date
    if (Run-Step $win $p.Id 'Check this PC' 'check' 1500) {
        Log ("      the PC check took {0:n0} s" -f ((Get-Date) - $t0).TotalSeconds)
        Check (Test-Path 'C:\Strata\.venv\Scripts\python.exe') 'Strata''s .venv exists'
        Check (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\uv\uv.exe')) 'uv is in LocalAppData\Programs'
        Check ((Get-Content 'C:\Strata\.venv\pyvenv.cfg' -Raw -ErrorAction SilentlyContinue) -match '(?m)^uv = ') 'uv made the .venv'
        Check (-not (Test-Path (Join-Path $env:TEMP 'strata-python-setup.exe'))) 'no python.org installer was needed'
        Check ((Step-Text $win) -match 'Python environment is ready') 'Setup tab: Python ready'
    }
    Shot 'after-pc-check'
}

# 5b. the zip copy becomes a git clone that can update itself (Git is there now)
if (Run-Step $win $p.Id 'Make it updatable' 'strata' 1500) {
    Check (Test-Path 'C:\Strata\.git') 'Strata is now a git clone'
    Check ((Step-Text $win) -match 'Up to date with GitHub') 'Setup tab: Strata up to date with GitHub'
}
Shot 'after-make-updatable'

# 6. Cline without winget: Node.js from its portable zip, then npm install -g cline
if (Run-Step $win $p.Id 'Install Cline' 'cline' 900) {
    Check ((Step-Text $win) -match 'Cline is installed') 'Setup tab: Cline installed'
}
Shot 'after-cline'

# 7. winget itself, the way Microsoft documents it for Windows Sandbox
if (Run-Step $win $p.Id 'Set up winget' 'winget' 900) {
    Check ((Step-Text $win) -match 'winget is installed') 'Setup tab: winget installed'
}
Shot 'after-winget'
Log 'final setup steps:'; Setup-Steps $win | ForEach-Object { Log "    $_" }
Shot-Window $win 'setup'

# 7b. Remove model: two small stand-in models (a two-part file, and a file both use) in Strata's model folder;
# removing one takes its parts and its config, and keeps what the other still uses
if (-not $SkipPcCheck) {
    $md = 'C:\Strata-data\test-models'; New-Item -ItemType Directory -Force "$md\a", "$md\b" | Out-Null
    foreach ($f in "$md\a\ta-00001-of-00002.gguf", "$md\a\ta-00002-of-00002.gguf", "$md\b\tb.gguf", "$md\shared.gguf") {
        $fs = [IO.File]::Create($f); $fs.SetLength(4MB); $fs.Close(); Set-Content "$f.done" 'ok'
    }
    foreach ($t in @(@('test-a', "$md\a\ta-00001-of-00002.gguf"), @('test-b', "$md\b\tb.gguf"))) {
        [IO.File]::WriteAllText("C:\Strata\strata-$($t[0]).json", (@{ exe = 'x'; model_name = $t[0]; args = @('--native', $t[1], '--mtp-gguf', "$md\shared.gguf") } | ConvertTo-Json))
    }
    Press (All $win | Where-Object { $_.Current.ControlType -eq $CT::Button -and $_.Current.Name -eq 'Refresh' } | Select-Object -First 1)
    Start-Sleep 3
    $list = ById $win 'ConfigList'
    $row = All $list | Where-Object { (All $_ | ForEach-Object { $_.Current.Name }) -contains 'test-a' } | Select-Object -First 1
    if (-not $row) { Check $false 'Remove model: the test model is listed' }
    else {
        $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); Start-Sleep 1
        Press (All $win | Where-Object { $_.Current.ControlType -eq $CT::Button -and $_.Current.Name -eq 'Remove model...' } | Select-Object -First 1)
        $said = Confirm-Box $p.Id
        Log "remove model asked: $($said -replace "`r?`n", ' / ')"
        Check ($said -match 'ta-00002-of-00002\.gguf' -and $said -match 'Kept:' -and $said -match 'shared\.gguf') 'Remove model: lists both parts and keeps the shared file'
        Start-Sleep 5
        Check (-not (Test-Path "$md\a\ta-00001-of-00002.gguf") -and -not (Test-Path "$md\a\ta-00002-of-00002.gguf")) 'Remove model: both parts deleted'
        Check (-not (Test-Path 'C:\Strata\strata-test-a.json')) 'Remove model: its config deleted'
        Check ((Test-Path "$md\shared.gguf") -and (Test-Path "$md\b\tb.gguf") -and (Test-Path 'C:\Strata\strata-test-b.json')) 'Remove model: the other model and the shared file stay'
        Log "status: $((ById $win 'StatusText').Current.Name)"
    }
}
if ($Local) {
    $err = Get-Content "$out\gui-err.txt" -ErrorAction SilentlyContinue
    Check (-not $err) 'the GUI wrote no errors'
} else {
    # 8. uninstall the way Settings > Apps does - its UninstallString - with the launcher still open
    $u = [regex]::Match([string](Get-ItemProperty $appsKey -EA SilentlyContinue).UninstallString, '^"([^"]+)"\s+(.*)$')
    if (-not $u.Success) { Check $false 'uninstall: Settings > Apps has an uninstall command' }
    else {
        $un = Start-Process -FilePath $u.Groups[1].Value -ArgumentList $u.Groups[2].Value -PassThru
        $said = Confirm-Box $un.Id
        Log "uninstall said: $said"
        Check ($said -match 'is uninstalled') 'uninstall: it says what it did'
        [void]$un.WaitForExit(30000)
    }
    Start-Sleep 2
    Check (-not (Test-Path $appsKey)) 'uninstall: gone from Settings > Apps'
    Check (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) 'uninstall: the open launcher was closed'
    Check (-not (Test-Path $gui)) 'uninstall: the launcher''s folder is gone'
    Check (-not (Test-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Strata Launcher.lnk'))) 'uninstall: no desktop shortcut'
    Check (-not (Test-Path 'HKCU:\Software\StrataLauncher')) 'uninstall: no registry key'
    Check (Test-Path 'C:\Strata\START-HERE.bat') 'uninstall: Strata is still there'
}
Done $null
