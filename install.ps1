# strata-launcher installer for a new PC. Gets strata-launcher (no admin rights needed), adds Start menu and
# desktop shortcuts, and starts it; its Setup tab then fetches Git, Strata, a model and Cline.
#
#   irm https://raw.githubusercontent.com/b1tninja/strata-launcher/main/install.ps1 | iex
#
# or, in a clone: powershell -ExecutionPolicy Bypass -File install.ps1  (shortcuts for that clone only).
# To remove it: & ([scriptblock]::Create((irm https://raw.githubusercontent.com/b1tninja/strata-launcher/main/install.ps1))) -Uninstall
param(
    # Where strata-launcher goes when it is downloaded.
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'Programs\strata-launcher'),
    # Where strata-launcher comes from (a fork, or a mirror).
    [string]$Repo = 'https://github.com/b1tninja/strata-launcher',
    [switch]$NoShortcuts,
    [switch]$NoStart,
    # Remove strata-launcher: its shortcuts, its Settings > Apps entry, its registry key, the Service tab's
    # scheduled task and (when this installer downloaded it, not a clone you run it from) its folder.
    # Strata, the models, Python, Git, Node.js and Cline stay. Models are removed in the app (Remove model).
    [switch]$Uninstall,
    # Set by the Settings > Apps entry: the result is shown in a message box, as there is no console to read.
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$AppsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\StrataLauncher'

if ($Uninstall) {
    $said = New-Object System.Collections.Generic.List[string]
    # the Service tab's background task runs strata-launcher.ps1 -Service: it goes first
    if (Get-ScheduledTask -TaskName 'Strata on-demand' -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName 'Strata on-demand' -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'Strata on-demand' -Confirm:$false -ErrorAction SilentlyContinue
        $said.Add('Removed the Service tab''s background task.')
    }
    foreach ($folder in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
        foreach ($n in 'Strata Launcher.lnk', 'Strata GUI.lnk') { Remove-Item -LiteralPath (Join-Path $folder $n) -ErrorAction SilentlyContinue }
    }
    $app = (Get-ItemProperty -Path 'HKCU:\Software\StrataLauncher' -ErrorAction SilentlyContinue).AppDir
    Remove-Item -Path 'HKCU:\Software\StrataLauncher', 'HKCU:\Software\StrataGui', $AppsKey -Recurse -ErrorAction SilentlyContinue
    # only the folder this installer downloads into, and only when it holds strata-launcher; a clone stays
    $own = Join-Path $env:LOCALAPPDATA 'Programs\strata-launcher'
    if (Test-Path -LiteralPath (Join-Path $own 'strata-launcher.ps1')) {
        # a running launcher holds the folder (its working folder): close it first; so would this script's own
        # working folder when Settings > Apps runs it from there
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf("$own\strata-launcher.ps1", [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Set-Location -LiteralPath $env:TEMP
        Start-Sleep -Milliseconds 500
        try { Remove-Item -LiteralPath $own -Recurse -Force; $said.Add("Removed $own.") }
        catch { $said.Add("Could not remove all of $own ($($_.Exception.Message)); delete what is left yourself.") }
    } elseif ($app) { $said.Add("Left $app as it is (delete it yourself if you like).") }
    $said.Add('Strata Launcher is uninstalled. Strata, its models and the tools the Setup tab installed are still there.')
    if ($Quiet) {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show(($said -join "`n`n"), 'Strata Launcher', 'OK', 'Information')
    } else { $said | ForEach-Object { Write-Host $_ } }
    return
}

# Run from a clone: use it where it is.
$here = if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'strata-launcher.ps1'))) { $PSScriptRoot } else { $null }
if ($here -and -not $PSBoundParameters.ContainsKey('Dir')) {
    $Dir = $here
    Write-Host "Using strata-launcher in $Dir"
} else {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ((Test-Path -LiteralPath (Join-Path $Dir '.git')) -and $git) {
        Write-Host "Updating strata-launcher in $Dir"
        & $git.Source -C $Dir pull --ff-only
    } elseif ($git -and -not (Test-Path -LiteralPath $Dir)) {
        Write-Host "Cloning $Repo into $Dir"
        & $git.Source clone "$Repo.git" $Dir
    } else {
        # No git (or a folder that is not a clone): the zip, keeping the user's settings across an update.
        Write-Host "Downloading strata-launcher into $Dir"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $env:TEMP 'strata-launcher-main.zip'
        $tmp = Join-Path $env:TEMP 'strata-launcher-main'
        # With its progress bar hidden, Invoke-WebRequest is as fast as curl.exe; shown, it crawls in Windows PowerShell.
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing "$Repo/archive/refs/heads/main.zip" -OutFile $zip
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp
        $src = (Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1).FullName
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Dir -Recurse -Force
        }
        Remove-Item -LiteralPath $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE) { throw "git failed ($LASTEXITCODE)" }
}

$gui = Join-Path $Dir 'strata-launcher.ps1'
if (-not (Test-Path -LiteralPath $gui)) { throw "strata-launcher.ps1 is not in $Dir" }
# Downloaded files carry the internet zone mark; Windows PowerShell then asks before running them.
Get-ChildItem -LiteralPath $Dir -Recurse -Include *.ps1 -File | Unblock-File

# Where strata-launcher is, for anything that looks for it (per user, no admin rights).
$key = 'HKCU:\Software\StrataLauncher'
if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
Set-ItemProperty -Path $key -Name AppDir -Value $Dir

# Settings > Apps > Installed apps (per user, no admin rights): its Uninstall runs this file with -Uninstall.
$version = [regex]::Match((Get-Content -LiteralPath $gui -Raw), "(?m)^\`$AppVersion = '([^']+)'").Groups[1].Value
if (-not (Test-Path $AppsKey)) { New-Item -Path $AppsKey -Force | Out-Null }
$installer = Join-Path $Dir 'install.ps1'
$sizeKb = [int]((Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1KB)
$entry = @{
    DisplayName = 'Strata Launcher'; DisplayVersion = $(if ($version) { $version } else { '0' }); Publisher = 'b1tninja'
    DisplayIcon = (Join-Path $Dir 'assets\strata-launcher.ico'); InstallLocation = $Dir; InstallDate = (Get-Date -Format 'yyyyMMdd')
    URLInfoAbout = $Repo; HelpLink = "$Repo/blob/main/docs/troubleshooting.md"
    UninstallString = "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installer`" -Uninstall -Quiet"
}
foreach ($k in $entry.Keys) { Set-ItemProperty -Path $AppsKey -Name $k -Value $entry[$k] }
foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $AppsKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
New-ItemProperty -Path $AppsKey -Name EstimatedSize -Value $sizeKb -PropertyType DWord -Force | Out-Null

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launch = "-NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File `"$gui`""
if (-not $NoShortcuts) {
    $ws = New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
        $lnk = $ws.CreateShortcut((Join-Path $folder 'Strata Launcher.lnk'))
        $lnk.TargetPath = $ps
        $lnk.Arguments = $launch
        $lnk.WorkingDirectory = $Dir
        $lnk.WindowStyle = 7
        $lnk.Description = 'Launch, benchmark and set up Strata models'
        $ico = Join-Path $Dir 'assets\strata-launcher.ico'
        $lnk.IconLocation = $(if (Test-Path -LiteralPath $ico) { "$ico,0" } else { "$env:SystemRoot\System32\imageres.dll,144" })
        $lnk.Save()
        # the same shortcut under this tool's earlier name
        Remove-Item -LiteralPath (Join-Path $folder 'Strata GUI.lnk') -ErrorAction SilentlyContinue
    }
    Write-Host 'Added Strata Launcher to the Start menu and the desktop.'
}
if (-not $NoStart) {
    Start-Process -FilePath $ps -ArgumentList $launch -WorkingDirectory $Dir
    Write-Host 'Started Strata Launcher. Without a Strata folder it opens on its Setup tab.'
}
