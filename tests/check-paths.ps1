$ErrorActionPreference = 'Stop'
$gui = Split-Path -Parent $PSScriptRoot
$bad = 0

# Where the launcher used to live, built at runtime so this file never matches itself.
$sep = [IO.Path]::DirectorySeparatorChar
$needle = $sep + 'code' + $sep + 'cline-strata.ps1'

Write-Output '--- the launcher the GUI launches by default:'
$default = Join-Path $gui 'cline-strata.ps1'
if (Test-Path -LiteralPath $default) { Write-Output "  ok   $default" }
else { $bad++; Write-Output "  FAIL missing: $default" }

Write-Output '--- leftover references to the old loose copy:'
$left = Get-ChildItem -LiteralPath $gui -Recurse -Include *.ps1, *.md, *.json -File |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|\.git)\\' } |
    Select-String -SimpleMatch -Pattern $needle
if ($left) { $bad += @($left).Count; $left | ForEach-Object { Write-Output ("  FAIL {0}:{1}" -f $_.Path, $_.LineNumber) } }
else { Write-Output '  none' }

Write-Output '--- every Strata Launcher shortcut (desktop, Start menu, next to this folder) points at a script that exists:'
$ws = New-Object -ComObject WScript.Shell
$quote = [char]34
$lnks = @(Get-ChildItem -LiteralPath (Split-Path -Parent $gui) -Filter '*.lnk' -File -ErrorAction SilentlyContinue) +
    @(foreach ($f in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        Get-Item -LiteralPath (Join-Path $f 'Strata Launcher.lnk') -ErrorAction SilentlyContinue })
if (-not $lnks) { Write-Output '  none' }
$lnks | ForEach-Object {
    $sc = $ws.CreateShortcut($_.FullName)
    $a = $sc.Arguments
    $s = $a.IndexOf($quote); $e = $a.LastIndexOf($quote)
    $path = if ($s -ge 0 -and $e -gt $s) { $a.Substring($s + 1, $e - $s - 1) } else { $a }
    if (Test-Path -LiteralPath $path) { Write-Output ('  ok   ' + $_.FullName + ' -> ' + $path) }
    else { $script:bad++; Write-Output ('  FAIL ' + $_.FullName + ' -> missing ' + $path) }
}

Write-Output '--- every function the scripts define is code (a here-string left open hides the rest as text):'
foreach ($ps1 in Get-ChildItem -LiteralPath $gui -Filter '*.ps1' -File) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ps1.FullName, [ref]$tokens, [ref]$errors)
    $seen = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $written = @(Select-String -LiteralPath $ps1.FullName -Pattern '^\s*function ([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    $hidden = @($written | Where-Object { $seen -notcontains $_ })
    if ($errors -or $hidden) { $bad++; Write-Output ("  FAIL {0}: {1} parse error(s); hidden: {2}" -f $ps1.Name, @($errors).Count, ($hidden -join ', ')) }
    else { Write-Output ("  ok   {0}: {1} functions" -f $ps1.Name, $seen.Count) }
}
Write-Output '--- no machine-specific paths in the scripts:'
$machine = Get-ChildItem -LiteralPath $gui -Filter '*.ps1' -File | Select-String -Pattern 'niko1221\\|M:\\GITHUB|D:\\code\\|D:\\ai\\'
if ($machine) { $bad += @($machine).Count; $machine | ForEach-Object { Write-Output ("  FAIL {0}:{1}: {2}" -f $_.Filename, $_.LineNumber, $_.Line.Trim()) } }
else { Write-Output '  none' }
if ($bad) { Write-Output "$bad problem(s)"; exit 1 }
Write-Output 'all good'
