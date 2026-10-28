# strata-launcher installer for a new PC. Gets strata-launcher (no admin rights needed), adds Start menu and
# desktop shortcuts, and starts it; its Setup tab then fetches Git, Strata, a model and Cline.
#
#   irm https://raw.githubusercontent.com/b1tninja/strata-launcher/main/install.ps1 | iex
#
# or, in a clone: powershell -ExecutionPolicy Bypass -File install.ps1  (shortcuts for that clone only).
param(
    # Where strata-launcher goes when it is downloaded.
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'Programs\strata-launcher'),
    # Where strata-launcher comes from (a fork, or a mirror).
    [string]$Repo = 'https://github.com/b1tninja/strata-launcher',
    [switch]$NoShortcuts,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

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
