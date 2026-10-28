# Runs inside the sandbox (peek-sandbox.ps1 starts it with wsb exec): writes C:\out\peek.txt with what is
# happening - processes, open windows, and the end of every setup window's log and installer log.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("peek at $(Get-Date -Format 'HH:mm:ss')")
$lines.Add('--- processes')
Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(powershell|cmd|python\d*|py|pip|msiexec|node|npm|git|winget|curl|.*setup.*|.*install.*)\.exe$' } |
    ForEach-Object { $c = ($_.CommandLine -replace '\s+', ' '); $lines.Add(('{0,6} {1,-22} {2}' -f $_.ProcessId, $_.Name, $c.Substring(0, [Math]::Min(170, $c.Length)))) }
$lines.Add('--- windows')
Get-Process | Where-Object { $_.MainWindowTitle } | ForEach-Object { $lines.Add(('{0,6} {1,-22} {2}' -f $_.Id, $_.ProcessName, $_.MainWindowTitle)) }
$tmp = Join-Path $env:TEMP 'strata-launcher'
foreach ($f in @(Get-ChildItem -Path $tmp -Filter 'setup-*.log' -ErrorAction SilentlyContinue) + @(Get-ChildItem -Path $tmp -Filter 'setup-*.done' -ErrorAction SilentlyContinue) +
               @(Get-Item -Path (Join-Path $env:TEMP 'strata-python-setup*.log') -ErrorAction SilentlyContinue)) {
    $lines.Add("--- $($f.Name) ($('{0:HH:mm:ss}' -f $f.LastWriteTime))")
    try {
        $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
        try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
        ($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 15) | ForEach-Object { $lines.Add("  $_") }
    } catch { $lines.Add("  (unreadable: $($_.Exception.Message))") }
}
[IO.File]::WriteAllLines('C:\out\peek.txt', $lines)
