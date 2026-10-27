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

Write-Output '--- every shortcut in D:\code points at a script that exists:'
$ws = New-Object -ComObject WScript.Shell
$quote = [char]34
Get-ChildItem -LiteralPath (Split-Path -Parent $gui) -Filter '*.lnk' -File | ForEach-Object {
    $sc = $ws.CreateShortcut($_.FullName)
    $a = $sc.Arguments
    $s = $a.IndexOf($quote); $e = $a.LastIndexOf($quote)
    $path = if ($s -ge 0 -and $e -gt $s) { $a.Substring($s + 1, $e - $s - 1) } else { $a }
    if (Test-Path -LiteralPath $path) { Write-Output ('  ok   ' + $_.Name + ' -> ' + $path) }
    else { $script:bad++; Write-Output ('  FAIL ' + $_.Name + ' -> missing ' + $path) }
}

if ($bad) { Write-Output "$bad problem(s)"; exit 1 }
Write-Output 'all good'
