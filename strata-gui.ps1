# Strata launcher and benchmark GUI. Finds the model configs (strata-*.json) of a Strata
# folder, starts / stops their servers, runs tools\strata_bench.py against one or several
# of them, lists the results, and opens Cline on a running server.
param(
    [string]$StrataRoot,
    # -Service: run one config's server on demand, hidden (the Service tab's scheduled task starts this).
    [switch]$Service,
    [string]$Config,
    [int]$Port = 8080,
    [int]$IdleSeconds = 900
)

$ErrorActionPreference = 'Continue'
$SettingsPath = Join-Path $PSScriptRoot 'strata-gui.settings.json'
$TempDir = Join-Path $env:TEMP 'strata-gui'
$ThinkingLevels = @('none', 'low', 'medium', 'high', 'xhigh')
$LoadTimeoutMinutes = 30
# Tokens held back from the context Cline is told about - see Get-ClineContext.
$ClineContextReserve = 4096
$ClineReservePercent = 10     # the Headroom box
$TrainedContext = 262144      # the model's trained window: past it Strata needs rope scaling
$ServiceLog = Join-Path $PSScriptRoot 'strata-service.log'
$ServiceErrLog = Join-Path $PSScriptRoot 'strata-service.err.log'

# Clean a typed path: trim, drop surrounding quotes, drop trailing separators - except when the path
# is a drive/UNC root, where the trailing \ is part of the path ("M:\" stays, "M:\strata\" becomes "M:\strata").
function Clean-Path([string]$Text) {
    $t = $Text.Trim()
    while ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) { $t = $t.Substring(1, $t.Length - 2).Trim() }
    while ($t.Length -gt 3 -and ($t.EndsWith('\') -or $t.EndsWith('/'))) { $t = $t.Substring(0, $t.Length - 1) }
    return $t
}

# Quote a path for a child process (powershell/cmd/python all parse \" as a literal quote, so a path
# ending in \ would otherwise eat its own closing quote and glue the next argument into it). Doubling
# the trailing backslash ("M:\" -> "M:\\") makes them parse it back to one \ and keeps the quote closing.
function QPath([string]$Path) {
    if ($Path -match '(\\+)$' -and $Matches[1].Length % 2 -eq 1) { $Path += '\' }
    return '"' + $Path + '"'
}

if ($Service) {
    # The server gets a hidden console of its own; the engine it starts shares it, so nothing shows.
    # This process waits for it, so the task is "Running" exactly while the server is.
    $py = Join-Path $StrataRoot '.venv\Scripts\python.exe'
    $server = Join-Path $StrataRoot 'serve\server.py'
    $serverArgs = (QPath $server) + ' --engine strata --config ' + (QPath $Config) + " --port $Port --lazy --idle-unload $IdleSeconds"
    $proc = Start-Process -FilePath $py -ArgumentList $serverArgs -WorkingDirectory $StrataRoot -WindowStyle Hidden `
        -RedirectStandardOutput $ServiceLog -RedirectStandardError $ServiceErrLog -PassThru
    $proc.WaitForExit()
    exit $proc.ExitCode
}

# WPF needs STA; relaunch the same way the Cline shortcuts do.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $forward = @('-STA', '-ExecutionPolicy', 'Bypass', '-File', (QPath $PSCommandPath))
    if ($StrataRoot) { $forward += @('-StrataRoot', (QPath (Clean-Path $StrataRoot))) }
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $forward -WindowStyle Hidden
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Net.Http

# ------------------------------------------------------------------------------------ settings
$defaults = [ordered]@{
    StrataRoot    = 'M:\GITHUB\niko1221\strata'
    ClineScript   = (Join-Path $PSScriptRoot 'cline-strata.ps1')
    ClineFolder   = 'D:\code'
    Thinking      = ''
    Context       = ''
    ExtraArgs     = ''
    VramReserve   = ''
    FitMaxTokens  = $true
    ReservePercent = '10'
    OpenWeb       = $false
    Minimized     = $false
    UnloadOllama  = $true
    Runs          = '3'
    Clients       = '0'
    Long          = $false
    Think         = $false
    StopAfter     = $true
    LastConfig    = ''
    DataFolder    = ''
    FitOnly       = $false
    ServiceConfig = ''
    ServiceIdle   = '15'
}
$settings = [pscustomobject]$defaults
if (Test-Path -LiteralPath $SettingsPath) {
    try {
        $saved = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) {
            if ($defaults.Contains($p.Name)) { $settings.($p.Name) = $p.Value }
        }
    } catch {}
}
if ($StrataRoot) { $settings.StrataRoot = Clean-Path $StrataRoot }

# ------------------------------------------------------------------------------------ XAML
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Strata" Height="760" Width="1040" MinHeight="600" MinWidth="820"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,4"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="MinWidth" Value="84"/>
      <Setter Property="Height" Value="28"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Height" Value="26"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="26"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,0,16,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF666666"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,4,0,0"/>
    </Style>
  </Window.Resources>
  <DockPanel Margin="14">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <TextBlock Text="Strata folder" Style="{StaticResource Label}"/>
      <Button x:Name="RefreshBtn" DockPanel.Dock="Right" Content="Refresh" Margin="8,0,0,0"/>
      <Button x:Name="RootBrowse" DockPanel.Dock="Right" Content="Browse..." Margin="8,0,0,0"/>
      <TextBox x:Name="RootBox"/>
    </DockPanel>

    <Border DockPanel.Dock="Bottom" BorderBrush="#FFCCCCCC" BorderThickness="0,1,0,0" Padding="0,6,0,0" Margin="0,10,0,0">
      <TextBlock x:Name="StatusText" Foreground="#FF444444" Text="Ready."/>
    </Border>

    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="190"/>
        <RowDefinition Height="10"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="Installed models (strata-*.json). Select one to launch, or several to benchmark one after another."
                 Foreground="#FF444444" Margin="0,0,0,4"/>
      <ListView x:Name="ConfigList" Grid.Row="1" SelectionMode="Extended">
        <ListView.View>
          <GridView>
            <GridViewColumn Header="Config" Width="190" DisplayMemberBinding="{Binding File}"/>
            <GridViewColumn Header="Model" Width="300" DisplayMemberBinding="{Binding Model}"/>
            <GridViewColumn Header="Quant" Width="80" DisplayMemberBinding="{Binding Quant}"/>
            <GridViewColumn Header="Context" Width="80" DisplayMemberBinding="{Binding Context}"/>
            <GridViewColumn Header="KV" Width="50" DisplayMemberBinding="{Binding Kv}"/>
            <GridViewColumn Header="Port" Width="50" DisplayMemberBinding="{Binding Port}"/>
            <GridViewColumn Header="Server" Width="210" DisplayMemberBinding="{Binding Status}"/>
          </GridView>
        </ListView.View>
      </ListView>

      <TabControl Grid.Row="3" x:Name="Tabs">
        <TabItem Header="  Launch  ">
          <StackPanel Margin="12">
            <TextBlock Text="Overrides (leave empty to use the config as it is; a changed config is written to %TEMP%\strata-gui)" FontWeight="SemiBold" Margin="0,0,0,8"/>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="110"/>
                <ColumnDefinition Width="200"/>
                <ColumnDefinition Width="24"/>
                <ColumnDefinition Width="110"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="Max context" Style="{StaticResource Label}"/>
              <ComboBox Grid.Column="1" x:Name="CtxBox" IsEditable="True"/>
              <TextBlock Grid.Column="3" Text="Extra engine args" Style="{StaticResource Label}"/>
              <TextBox Grid.Column="4" x:Name="ExtraBox" ToolTip="Appended to the config's engine args, e.g. --kv q8 --prefill 1024"/>
            </Grid>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="110"/>
                <ColumnDefinition Width="200"/>
                <ColumnDefinition Width="24"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="VRAM reserve MiB" Style="{StaticResource Label}"/>
              <TextBox Grid.Column="1" x:Name="VramBox" ToolTip="--vram-reserve-mib: GPU memory the engine leaves free. Empty: the config's. The engine log says when it wants more."/>
              <CheckBox Grid.Column="3" x:Name="FitChk" Content="Shorten an answer that would not fit instead of refusing the request (fit_max_tokens)"/>
            </Grid>
            <TextBlock x:Name="CtxHint" Style="{StaticResource Hint}" Margin="0,2,0,0"/>
            <WrapPanel Margin="0,6,0,10">
              <CheckBox x:Name="OpenWebChk" Content="Open the web page when ready"/>
              <CheckBox x:Name="MinChk" Content="Start the server window minimized"/>
              <CheckBox x:Name="OllamaChk" Content="Unload Ollama models first"/>
            </WrapPanel>
            <WrapPanel>
              <Button x:Name="StartBtn" Content="Start server" FontWeight="SemiBold"/>
              <Button x:Name="StopBtn" Content="Stop server"/>
              <Button x:Name="WebBtn" Content="Open web UI"/>
              <Button x:Name="LogBtn" Content="Open engine log"/>
              <Button x:Name="ConfigBtn" Content="Open config"/>
            </WrapPanel>

            <Separator Margin="0,16,0,12"/>
            <TextBlock Text="Cline" FontWeight="SemiBold" Margin="0,0,0,8"/>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="110"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="Project folder" Style="{StaticResource Label}"/>
              <TextBox Grid.Column="1" x:Name="FolderBox"/>
              <Button Grid.Column="2" x:Name="FolderBrowse" Content="Browse..." Margin="8,0,0,0"/>
            </Grid>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="110"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="Launcher script" Style="{StaticResource Label}"/>
              <TextBox Grid.Column="1" x:Name="ClineScriptBox"/>
              <Button Grid.Column="2" x:Name="ClineScriptBrowse" Content="Browse..." Margin="8,0,0,0"/>
            </Grid>
            <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
              <TextBlock Width="110" Text="Thinking" Style="{StaticResource Label}"/>
              <ComboBox x:Name="ThinkingBox" Width="200" Margin="0,0,16,0"/>
              <TextBlock Text="Headroom" Style="{StaticResource Label}"/>
              <ComboBox x:Name="ReserveBox" Width="70" Margin="0,0,16,0"
                        ToolTip="Share of the context Cline is not told about, so it compacts before the server refuses a prompt (at least 4096 tokens). Cline undercounts by ~4-5%; 10% leaves room for the answer too."/>
              <Button x:Name="ClineBtn" Content="Open Cline" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock Style="{StaticResource Hint}" Text="Starts the selected server if it is not running, waits until the model is loaded, then opens Cline in the folder pointed at that server."/>
          </StackPanel>
        </TabItem>

        <TabItem Header="  Benchmark  ">
          <DockPanel Margin="12">
            <StackPanel DockPanel.Dock="Top">
              <WrapPanel Margin="0,0,0,8">
                <TextBlock Text="Runs per test" Style="{StaticResource Label}"/>
                <ComboBox x:Name="RunsBox" Width="60" Margin="0,0,20,0"/>
                <TextBlock Text="Parallel clients" Style="{StaticResource Label}"/>
                <ComboBox x:Name="ClientsBox" Width="60" Margin="0,0,20,0"/>
                <CheckBox x:Name="LongChk" Content="32K prompt test"/>
                <CheckBox x:Name="ThinkChk" Content="Thinking on"/>
                <CheckBox x:Name="StopAfterChk" Content="Stop the server when done"/>
              </WrapPanel>
              <DockPanel Margin="0,0,0,8">
                <TextBlock Text="Compare with" Style="{StaticResource Label}"/>
                <ComboBox x:Name="CompareBox"/>
              </DockPanel>
              <WrapPanel Margin="0,0,0,8">
                <Button x:Name="BenchBtn" Content="Run benchmark" FontWeight="SemiBold"/>
                <Button x:Name="CancelBtn" Content="Cancel" IsEnabled="False"/>
                <Button x:Name="ClearBtn" Content="Clear output"/>
                <TextBlock x:Name="BenchState" VerticalAlignment="Center" Foreground="#FF444444"/>
              </WrapPanel>
              <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,8"
                         Text="Uses tools\strata_bench.py with the launch overrides above. With several models selected each is started, measured and stopped in turn. A default run takes about 3-10 minutes after loading."/>
            </StackPanel>
            <TextBox x:Name="BenchOut" Height="Auto" VerticalContentAlignment="Top" FontFamily="Consolas" FontSize="12"
                     IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          </DockPanel>
        </TabItem>

        <TabItem Header="  Results  ">
          <Grid Margin="12">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="8"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <WrapPanel Grid.Row="0" Margin="0,0,0,8">
              <Button x:Name="ResRefreshBtn" Content="Refresh"/>
              <Button x:Name="ResReadmeBtn" Content="Open report"/>
              <Button x:Name="ResFolderBtn" Content="Open folder"/>
              <Button x:Name="ResCompareBtn" Content="Compare two selected"/>
              <CheckBox x:Name="OnlyBenchChk" Content="Only strata_bench results" IsChecked="True" Margin="8,0,0,0"/>
            </WrapPanel>
            <ListView Grid.Row="1" x:Name="ResultList" SelectionMode="Extended">
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="Results folder" Width="330" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="Model" Width="190" DisplayMemberBinding="{Binding Model}"/>
                  <GridViewColumn Header="Context" Width="75" DisplayMemberBinding="{Binding Context}"/>
                  <GridViewColumn Header="Decode tok/s" Width="90" DisplayMemberBinding="{Binding Decode}"/>
                  <GridViewColumn Header="4K pp tok/s" Width="85" DisplayMemberBinding="{Binding P4}"/>
                  <GridViewColumn Header="16K pp tok/s" Width="85" DisplayMemberBinding="{Binding P16}"/>
                  <GridViewColumn Header="Agent hit %" Width="80" DisplayMemberBinding="{Binding Hit}"/>
                </GridView>
              </ListView.View>
            </ListView>
            <TextBox Grid.Row="3" x:Name="ResDetail" Height="Auto" VerticalContentAlignment="Top" FontFamily="Consolas" FontSize="12"
                     IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          </Grid>
        </TabItem>

        <TabItem Header="  Models  " x:Name="ModelsTab">
          <Grid Margin="12">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="8"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <DockPanel Grid.Row="0" Margin="0,0,0,8">
              <TextBlock Text="Data folder" Style="{StaticResource Label}"/>
              <Button x:Name="CatRefreshBtn" DockPanel.Dock="Right" Content="Refresh" Margin="8,0,0,0"/>
              <Button x:Name="DataBrowse" DockPanel.Dock="Right" Content="Browse..." Margin="8,0,0,0"/>
              <TextBox x:Name="DataBox" ToolTip="Where setup puts models and packs (its --models-dir drive); free space is measured here"/>
            </DockPanel>
            <DockPanel Grid.Row="1" Margin="0,0,0,8">
              <CheckBox x:Name="FitOnlyChk" DockPanel.Dock="Right" Content="Only what fits" Margin="8,0,0,0"/>
              <TextBlock x:Name="MachineText" VerticalAlignment="Center" TextWrapping="Wrap"/>
            </DockPanel>
            <ListView Grid.Row="2" x:Name="CatalogList" SelectionMode="Single">
              <ListView.ItemContainerStyle>
                <Style TargetType="ListViewItem">
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding Level}" Value="ok"><Setter Property="Background" Value="#FFE3F4E1"/></DataTrigger>
                    <DataTrigger Binding="{Binding Level}" Value="warn"><Setter Property="Background" Value="#FFFFF4D6"/></DataTrigger>
                    <DataTrigger Binding="{Binding Level}" Value="bad"><Setter Property="Background" Value="#FFF9DEDC"/></DataTrigger>
                  </Style.Triggers>
                </Style>
              </ListView.ItemContainerStyle>
              <ListView.View>
                <GridView>
                  <GridViewColumn Header="Family" Width="200" DisplayMemberBinding="{Binding Title}"/>
                  <GridViewColumn Header="Quant" Width="95" DisplayMemberBinding="{Binding Quant}"/>
                  <GridViewColumn Header="Download GB" Width="85" DisplayMemberBinding="{Binding Download}"/>
                  <GridViewColumn Header="Disk need GB" Width="85" DisplayMemberBinding="{Binding Disk}"/>
                  <GridViewColumn Header="RAM need GB" Width="85" DisplayMemberBinding="{Binding Ram}"/>
                  <GridViewColumn Header="RAM" Width="190" DisplayMemberBinding="{Binding RamFit}"/>
                  <GridViewColumn Header="Disk" Width="120" DisplayMemberBinding="{Binding DiskFit}"/>
                  <GridViewColumn Header="Installed" Width="65" DisplayMemberBinding="{Binding Installed}"/>
                </GridView>
              </ListView.View>
            </ListView>
            <DockPanel Grid.Row="4">
              <Button x:Name="InstallBtn" DockPanel.Dock="Right" Content="Install with setup..." Margin="8,0,0,0" VerticalAlignment="Top"/>
              <TextBlock x:Name="CatDetail" TextWrapping="Wrap" Foreground="#FF444444"
                         Text="Green: fits with every expert in RAM. Yellow: runs, with part of the experts read from the SSD (slower). Red: does not fit this PC. Requirements come from this Strata checkout's setup.py; they are setup's estimates."/>
            </DockPanel>
          </Grid>
        </TabItem>

        <TabItem Header="  Service  " x:Name="ServiceTab">
          <StackPanel Margin="12">
            <TextBlock TextWrapping="Wrap" Foreground="#FF444444" Margin="0,0,0,12"
                       Text="Runs one model on demand in the background: its server starts without loading the model (--lazy), the first request (Cline, the web page, Load now) loads it, and it unloads again after the idle time (--idle-unload), so the VRAM is free while nothing uses it. A scheduled task for your user runs it, hidden; it uses the config as it is (no launch overrides)."/>
            <Grid Margin="0,0,0,8">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="130"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="Model" Style="{StaticResource Label}"/>
              <ComboBox Grid.Column="1" x:Name="SvcModelBox"/>
            </Grid>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Width="130" Text="Unload after" Style="{StaticResource Label}"/>
              <ComboBox x:Name="SvcIdleBox" Width="80" IsEditable="True"/>
              <TextBlock Text="minutes without requests" Style="{StaticResource Label}" Margin="8,0,0,0"/>
            </StackPanel>
            <CheckBox x:Name="SvcLogonChk" Content="Start at Windows logon" Margin="130,0,0,12"/>
            <WrapPanel Margin="0,0,0,12">
              <Button x:Name="SvcApplyBtn" Content="Install / update" FontWeight="SemiBold"/>
              <Button x:Name="SvcRemoveBtn" Content="Remove"/>
              <Button x:Name="SvcStartBtn" Content="Start now"/>
              <Button x:Name="SvcStopBtn" Content="Stop"/>
              <Button x:Name="SvcLoadBtn" Content="Load now"/>
              <Button x:Name="SvcUnloadBtn" Content="Unload now"/>
              <Button x:Name="SvcLogBtn" Content="Open log"/>
            </WrapPanel>
            <TextBlock x:Name="SvcStatus" TextWrapping="Wrap" FontFamily="Consolas" FontSize="12"/>
          </StackPanel>
        </TabItem>
      </TabControl>
    </Grid>
  </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $name = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($name) { $ui[$name] = $window.FindName($name) }
}

# ------------------------------------------------------------------------------------ state
$script:configs = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:results = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.ConfigList.ItemsSource = $script:configs
$ui.ResultList.ItemsSource = $script:results
$script:http = New-Object System.Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromSeconds(3)
$script:health = @{}        # port -> health object
$script:healthTasks = @{}   # port -> pending Task[string]
$script:started = @{}       # port -> the cmd.exe process this GUI started
$script:startedRow = @{}    # port -> the config path that process serves
$script:clinePending = $null
$script:job = $null

# ------------------------------------------------------------------------------------ helpers
function Set-Status([string]$Text) { $ui.StatusText.Text = $Text }

function Write-BenchLine([string]$Text) {
    $ui.BenchOut.AppendText($Text + "`r`n")
    $ui.BenchOut.ScrollToEnd()
}

function Get-Root { Clean-Path $ui.RootBox.Text }

function Get-Python {
    $py = Join-Path (Get-Root) '.venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $py) { return $py }
    return $null
}

function Get-ArgValue($ArgList, [string]$Name) {
    for ($i = 0; $i -lt $ArgList.Count - 1; $i++) {
        if ($ArgList[$i] -eq $Name) { return [string]$ArgList[$i + 1] }
    }
    return $null
}

function Get-QuantLabel($Cfg) {
    foreach ($key in @('--native', '--pack')) {
        $v = Get-ArgValue $Cfg.args $key
        if ($v -and ((Split-Path $v -Leaf) -match '(?i)(UD-)?(IQ\d_[A-Z]+|Q\d_K(_[SMLX]+)?|Q\d_\d|NVFP4|MXFP4|BF16|F16)')) {
            return $Matches[0].ToUpper()
        }
    }
    return '-'
}

function Format-Tokens($Value) {
    if (-not $Value) { return '-' }
    $n = [int64]$Value
    if ($n -ge 1048576 -and $n % 1048576 -eq 0) { return '{0}M' -f ($n / 1048576) }
    if ($n -ge 1024 -and $n % 1024 -eq 0) { return '{0}K' -f ($n / 1024) }
    return [string]$n
}

function Split-Args([string]$Text) {
    $out = @()
    foreach ($m in [regex]::Matches($Text, '"([^"]*)"|(\S+)')) {
        if ($m.Groups[1].Success) { $out += $m.Groups[1].Value } else { $out += $m.Groups[2].Value }
    }
    return , $out
}

function Get-SelectedConfigs { @($ui.ConfigList.SelectedItems | ForEach-Object { $_ }) }

function Get-Selected {
    $sel = @(Get-SelectedConfigs)
    if ($sel.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Select a model in the list first.', 'Strata') | Out-Null
        return $null
    }
    return $sel[0]
}

function Get-BaseUrl($Row) { "http://127.0.0.1:$($Row.Port)" }

function Test-RowReady($Row) {
    $h = $script:health[$Row.Port]
    return ($h -and $h.Loaded -and (-not $h.Model -or $h.Model -eq $Row.Model))
}

function Read-Configs {
    $root = Get-Root
    $keep = @(Get-SelectedConfigs | ForEach-Object { $_.Path })
    if (-not $keep -and $settings.LastConfig) { $keep = @($settings.LastConfig) }
    $script:configs.Clear()
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Set-Status "Not a folder: $root"
        return
    }
    $files = Get-ChildItem -LiteralPath $root -Filter 'strata-*.json' -File |
        Where-Object { $_.Name -notlike '*.shared-settings.json' } |
        Sort-Object LastWriteTime -Descending
    foreach ($f in $files) {
        try { $cfg = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $cfg.exe -or -not $cfg.args) { continue }
        $port = if ($cfg.port) { [int]$cfg.port } else { 8080 }
        $kv = Get-ArgValue $cfg.args '--kv'
        $row = [pscustomobject]@{
            File    = $f.Name
            Path    = $f.FullName
            Model   = if ($cfg.model_name) { [string]$cfg.model_name } else { $f.BaseName }
            Quant   = Get-QuantLabel $cfg
            Context = Format-Tokens (Get-ArgValue $cfg.args '--max-context')
            Kv      = if ($kv) { $kv } else { '-' }
            Port    = $port
            Log     = [string]$cfg.log
            Status  = '...'
            Cfg     = $cfg
        }
        $script:configs.Add($row)
    }
    foreach ($row in $script:configs) {
        if ($keep -contains $row.Path) { [void]$ui.ConfigList.SelectedItems.Add($row) }
    }
    if ($ui.ConfigList.SelectedItems.Count -eq 0 -and $script:configs.Count -gt 0) { $ui.ConfigList.SelectedIndex = 0 }
    if ($script:configs.Count -eq 0) {
        Set-Status "No strata-*.json configs in $root. Run START-HERE.bat there first."
    } else {
        Set-Status "$($script:configs.Count) model config(s) in $root"
    }
}

function Get-CtxOverride {
    # The Max context box as tokens, 0 for "(config)". Its steps read "393216  (yarn x1.5, experimental)".
    $t = $ui.CtxBox.Text.Trim()
    if (-not $t -or $t -eq '(config)') { return 0 }
    if ($t -notmatch '^(\d+)') { throw "Max context must be a number of tokens: $t" }
    return [int64]$Matches[1]
}

function Get-RopeScale([int64]$Ctx) {
    # The yarn factor that covers $Ctx, as setup derives it: context / the trained 262144, at least 1.
    return [Math]::Max(1.0, [Math]::Ceiling($Ctx / [double]$TrainedContext * 100) / 100)
}

function Set-ArgValue($List, [string]$Name, [string]$Value) {
    $i = $List.IndexOf($Name)
    if ($i -ge 0 -and $i + 1 -lt $List.Count) { $List[$i + 1] = $Value } else { $List.Add($Name); $List.Add($Value) }
}

function Remove-Arg($List, [string]$Name) {
    $i = $List.IndexOf($Name)
    if ($i -ge 0) { $List.RemoveRange($i, [Math]::Min(2, $List.Count - $i)) }
}

function Set-ContextArgs($List, [int64]$Ctx) {
    # --max-context plus the rope scaling it needs. Inside the trained 262144 a run is unscaled (a scaled run is
    # a slightly different model at every position, so Strata's setup only scales past it); past it, yarn with a
    # factor that covers the context (the one Strata's docs recommend; experimental there).
    Set-ArgValue $List '--max-context' ([string]$Ctx)
    if ($Ctx -le $TrainedContext) {
        Remove-Arg $List '--rope-scaling'
        Remove-Arg $List '--rope-scale'
        return
    }
    if ($List.IndexOf('--rope-scaling') -lt 0) { Set-ArgValue $List '--rope-scaling' 'yarn' }
    $need = Get-RopeScale $Ctx
    $have = Get-ArgValue $List '--rope-scale'
    if (-not $have -or [double]$have -lt $need) { Set-ArgValue $List '--rope-scale' $need.ToString([Globalization.CultureInfo]::InvariantCulture) }
}

function Get-EffectiveConfig($Row) {
    # The config as is, or a copy with the launch overrides applied.
    $ctx = Get-CtxOverride
    $extra = $ui.ExtraBox.Text.Trim()
    $vram = $ui.VramBox.Text.Trim()
    if ($vram -and $vram -notmatch '^\d+$') { throw "VRAM reserve must be a number of MiB: $vram" }
    $fit = [bool]$ui.FitChk.IsChecked
    if (-not $ctx -and -not $extra -and -not $vram -and -not $fit) { return $Row.Path }
    $cfg = Get-Content -LiteralPath $Row.Path -Raw | ConvertFrom-Json
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($a in $cfg.args) { $list.Add([string]$a) }
    if ($ctx) { Set-ContextArgs $list $ctx }
    if ($vram) { Set-ArgValue $list '--vram-reserve-mib' $vram }
    if ($extra) { foreach ($a in (Split-Args $extra)) { $list.Add($a) } }
    if ($fit) { $cfg | Add-Member -NotePropertyName fit_max_tokens -NotePropertyValue $true -Force }
    $cfg.args = $list.ToArray()
    if (-not (Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Path $TempDir | Out-Null }
    $out = Join-Path $TempDir $Row.File
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $out -Encoding utf8
    return $out
}

function Get-PortListeners([int]$Port) {
    @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -and $_ -ne 0 })
}

function Test-StartedHere($Row) {
    # This GUI started a server for this config and its window is still open.
    $p = $script:started[$Row.Port]
    return ($p -and -not $p.HasExited -and $script:startedRow[$Row.Port] -eq $Row.Path)
}

function Test-RowRunning($Row) {
    # A server for this model (and no other) is on its port, or is starting from here.
    if (Test-StartedHere $Row) { return $true }
    $h = $script:health[$Row.Port]
    return ($h -and $h.Up -and $h.Model -eq $Row.Model)
}

function Stop-Row($Row) {
    # Stops this model's server only. -> $false when it was not running.
    if (-not (Test-RowRunning $Row)) { return $false }
    if ((Test-ServiceRow $Row) -and -not (Test-StartedHere $Row)) { return (Stop-StrataService) }
    $ids = @()
    if (Test-StartedHere $Row) { $ids += $script:started[$Row.Port].Id }
    $ids += Get-PortListeners $Row.Port
    foreach ($id in ($ids | Select-Object -Unique)) { & taskkill.exe /PID $id /T /F 2>$null | Out-Null }
    $script:started.Remove($Row.Port)
    $script:startedRow.Remove($Row.Port)
    $script:health.Remove($Row.Port)
    return $true
}

function Stop-OllamaModels {
    if (-not $ui.OllamaChk.IsChecked) { return }
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) { return }
    $lines = & ollama ps 2>$null
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if ($line -match '^\s*(\S+)') { & ollama stop $Matches[1] 2>$null | Out-Null }
    }
}

function Start-Server($Row, [switch]$Quiet) {
    # -> $true when the server is starting or already up for this config.
    $py = Get-Python
    if (-not $py) {
        [System.Windows.MessageBox]::Show("No .venv in $(Get-Root). Run START-HERE.bat there first.", 'Strata') | Out-Null
        return $false
    }
    if (Test-RowRunning $Row) { return $true }
    # The service's model starts through its task, so it stays on demand.
    $task = Get-ServiceTask
    if ($task -and (Test-ServiceRow $Row) -and (Get-PortListeners $Row.Port).Count -eq 0) {
        Start-ScheduledTask -TaskName $ServiceTask
        Set-Status "Starting the on-demand service for $($Row.Model); it loads once something asks for it..."
        return $true
    }
    # Never touch another model's server: if the port is taken, say so and leave it alone.
    if ((Get-PortListeners $Row.Port).Count -gt 0 -or ($script:started[$Row.Port] -and -not $script:started[$Row.Port].HasExited)) {
        $h = $script:health[$Row.Port]
        $owner = if ($h -and $h.Model) { $h.Model } else {
            $path = $script:startedRow[$Row.Port]
            $r = $script:configs | Where-Object { $_.Path -eq $path } | Select-Object -First 1
            if ($r) { $r.Model } else { 'another program' }
        }
        $msg = "Port $($Row.Port) is in use by $owner. Stop that one first, or give $($Row.File) another port."
        if ($Quiet) { Write-BenchLine "    $msg" } else { [System.Windows.MessageBox]::Show($msg, 'Strata') | Out-Null }
        return $false
    }
    try { $cfgPath = Get-EffectiveConfig $Row } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Strata') | Out-Null
        return $false
    }
    Stop-OllamaModels
    $title = ('Strata ' + $Row.Model) -replace '[^\w\-\. ]', ''
    $server = Join-Path (Get-Root) 'serve\server.py'
    $line = "title $title & $(QPath $py) $(QPath $server) --engine strata --config $(QPath $cfgPath) --port $($Row.Port)"
    if ($ui.OpenWebChk.IsChecked) { $line += ' --open' }
    $line += ' & if errorlevel 1 pause'
    $style = if ($ui.MinChk.IsChecked) { 'Minimized' } else { 'Normal' }
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList "/s /c `"$line`"" `
        -WorkingDirectory (Get-Root) -WindowStyle $style -PassThru
    $script:started[$Row.Port] = $proc
    $script:startedRow[$Row.Port] = $Row.Path
    $script:health[$Row.Port] = [pscustomobject]@{ Up = $false; Loaded = $false; Model = ''; Context = 0; Starting = (Get-Date) }
    Set-Status "Starting $($Row.Model) on port $($Row.Port)$(if ($cfgPath -ne $Row.Path) { ' with overrides' })..."
    return $true
}

# ------------------------------------------------------------------------------------ health polling
function Update-Health {
    foreach ($port in @($script:configs | Select-Object -ExpandProperty Port -Unique)) {
        $task = $script:healthTasks[$port]
        if ($task) {
            if (-not $task.IsCompleted) { continue }
            $prev = $script:health[$port]
            $h = [pscustomobject]@{ Up = $false; Loaded = $false; Model = ''; Context = 0; Starting = $null }
            if ($task.Status -eq 'RanToCompletion') {
                try {
                    $j = $task.Result | ConvertFrom-Json
                    if ($j.service -eq 'strata') {
                        $h.Up = $true; $h.Loaded = [bool]$j.loaded; $h.Model = [string]$j.model
                        $h.Context = if ($j.max_context) { [int64]$j.max_context } else { 0 }
                    }
                } catch {}
            }
            # Keep "starting" until the server answers or the window it runs in has closed.
            if (-not $h.Up -and $prev -and $prev.Starting) {
                $proc = $script:started[$port]
                if ($proc -and -not $proc.HasExited) { $h.Starting = $prev.Starting }
            }
            $script:health[$port] = $h
            $script:healthTasks.Remove($port)
        } else {
            $script:healthTasks[$port] = $script:http.GetStringAsync("http://127.0.0.1:$port/health")
        }
    }
    $changed = $false
    foreach ($row in $script:configs) {
        $h = $script:health[$row.Port]
        $mine = Test-StartedHere $row
        $loading = $script:loadTasks[$row.Port] -and -not $script:loadTasks[$row.Port].IsCompleted
        $status = if (-not $h) { '...' }
            elseif ($h.Up -and $h.Model -and $h.Model -ne $row.Model) { 'stopped (port in use)' }
            elseif ($h.Loaded) { "ready  ($(Format-Tokens $h.Context) ctx)" }
            elseif ($h.Up -and $loading) { 'loading model...' }
            elseif ($h.Up -and -not $mine) { 'on demand (unloaded)' }
            elseif ($h.Up -and ($mine -or -not $script:startedRow[$row.Port])) { 'loading model...' }
            elseif ($h.Starting -and $mine) { 'starting ({0:n0} s)' -f ((Get-Date) - $h.Starting).TotalSeconds }
            else { 'stopped' }
        if ($row.Status -ne $status) { $row.Status = $status; $changed = $true }
    }
    if ($changed) { $ui.ConfigList.Items.Refresh() }
}

# ------------------------------------------------------------------------------------ Cline
function Get-RowContext($Row) {
    # The context this model can really serve, in tokens, or 0 when nothing says.
    # Order of trust: the running server's own answer (it knows what its engine actually loaded,
    # and it is the one that will refuse a prompt), then the --max-context override this GUI
    # would start the server with, then the config's own --max-context. A lazy server that has
    # never started its engine answers max_context 0 (#strata: reported_ctx), which is why this
    # falls through to the config instead of trusting health alone.
    $h = $script:health[$Row.Port]
    if ($h -and $h.Context) { return [int64]$h.Context }
    $ctx = 0
    try { $ctx = Get-CtxOverride } catch {}
    if ($ctx -gt 0) { return $ctx }
    $c = Get-ArgValue $Row.Cfg.args '--max-context'
    if ($c -and $c -match '^\d+$') { return [int64]$c }
    return 0
}

function Get-ClineContext([int64]$Ctx) {
    # The number Cline is told the window is: a little under what the server really has.
    # Cline only compacts once its own estimate of the prompt reaches 0.9x this number, and a
    # Strata server never truncates: a prompt that outgrows the engine is refused with a 400,
    # and every request that follows with it - the session cannot recover on its own. Cline's
    # estimate counts ~chars/4 and misses the ChatML template, the tool schemas and the image
    # tokens the engine really counts, so it sits under the true number (it corrects itself with
    # the reported prompt_tokens, but only after the first oversized request). The reserve covers
    # that error, the server's own CTX_SLACK (8) and the answer's room. The launcher runs the same
    # formula on the number it is handed (tests\context-tests.ps1 keeps the two in step) and the
    # status bar shows both numbers when Cline opens.
    # The reserve is a share of the context ($ClineReservePercent, the Headroom box), never under
    # $ClineContextReserve: Cline's log showed it still sending prompts ~4.5% over a 4096-token reserve.
    if ($Ctx -le 0) { return 0 }
    $half = [int64][Math]::Max(1024, [int][Math]::Ceiling($Ctx * 0.5))
    $reserve = [Math]::Max([int64]$ClineContextReserve, [int64][Math]::Ceiling($Ctx * $ClineReservePercent / 100.0))
    return [Math]::Max($half, $Ctx - $reserve)
}

function Update-CtxHint {
    # What the chosen context costs and does, for the selected model, before anything starts.
    $row = @(Get-SelectedConfigs) | Select-Object -First 1
    if (-not $row) { $ui.CtxHint.Text = ''; return }
    $ctx = 0
    try { $ctx = Get-CtxOverride } catch { $ui.CtxHint.Text = $_.Exception.Message; return }
    if (-not $ctx) { $c = Get-ArgValue $row.Cfg.args '--max-context'; if ($c -match '^\d+$') { $ctx = [int64]$c } }
    if (-not $ctx) { $ui.CtxHint.Text = 'The config sets no --max-context: the engine picks its own.'; return }
    $kv = Get-ArgValue $row.Cfg.args '--kv'
    $cell = @{ 'int8' = 1056; 'q8_0' = 1056; 'k8v4' = 816; 'q4_0' = 576 }[[string]$kv]
    $parts = @()
    if ($cell) {
        $gb = $ctx * 13 * $cell / 1e9
        $resident = Get-ArgValue $row.Cfg.args '--kv-resident'
        $parts += if ($resident) {
            'KV cache ~{0:n1} GB of RAM (streamed; {1:n0} tokens of it in VRAM, whatever the context)' -f $gb, [int64]$resident
        } else { 'KV cache ~{0:n1} GB of VRAM (not streamed: a longer context takes GPU memory from the experts)' -f $gb }
    }
    $parts += if ($ctx -le $TrainedContext) { 'no rope scaling (inside the trained 262,144)' }
        else { 'past the trained 262,144: yarn x{0} is added - EXPERIMENTAL, the model computes slightly differently at every position' -f (Get-RopeScale $ctx) }
    $parts += 'Cline is told {0:n0} tokens' -f (Get-ClineContext $ctx)
    $hint = ($parts -join ';  ') + '.'
    if ($row.Log -and (Test-Path -LiteralPath $row.Log)) {
        $want = Select-String -LiteralPath $row.Log -Pattern 'add --vram-reserve-mib (\d+)' | Select-Object -Last 1
        if ($want) { $hint += "  The engine log asked for --vram-reserve-mib $($want.Matches[0].Groups[1].Value) (GPU memory ran low)." }
    }
    $ui.CtxHint.Text = $hint
}

function Start-Cline($Row) {
    $launcher = Clean-Path $ui.ClineScriptBox.Text
    $folder = Clean-Path $ui.FolderBox.Text
    if (-not (Test-Path -LiteralPath $launcher)) {
        Set-Status "Cline launcher not found: $launcher - pick another in the Cline launcher box."
        return
    }
    # The context comes from what this model really serves - never from a guess. A context bigger
    # than the engine's is worse than a small one: Cline keeps the conversation until 0.9 of the
    # window it was given, the server never truncates, so the first prompt over the engine's
    # window is the last one that answers (a 262144 default here stuck a 131072 model that way).
    $raw = Get-RowContext $Row
    if ($raw -le 0) {
        Set-Status "Cannot tell $($Row.Model)'s context: no --max-context in its config and the server does not say. Cline was not opened."
        return
    }
    $clArgs = "-NoExit -STA -ExecutionPolicy Bypass -File $(QPath $launcher) -Folder $(QPath $folder) -Model `"$($Row.Model)`" " +
        "-StrataBase `"$(Get-BaseUrl $Row)`" -Context $raw -ReservePercent $ClineReservePercent -StrataRoot $(QPath (Get-Root))"
    $thinking = [string]$ui.ThinkingBox.SelectedItem
    if ($ThinkingLevels -contains $thinking) { $clArgs += " -Thinking $thinking" }
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $clArgs -WorkingDirectory $folder
    Set-Status ("Opened Cline in $folder on $($Row.Model): Cline's context {0:n0}, the server has {1:n0} tokens." -f (Get-ClineContext $raw), $raw)
}

# ------------------------------------------------------------------------------------ benchmark
function Read-NewText($State, [string]$Key) {
    $path = $State["$Key.File"]
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -le $State["$Key.Pos"]) { return '' }
        $null = $fs.Seek($State["$Key.Pos"], 'Begin')
        $buf = [byte[]]::new($fs.Length - $State["$Key.Pos"])
        $n = $fs.Read($buf, 0, $buf.Length)
        $State["$Key.Pos"] += $n
        $chars = [char[]]::new($n + 1)
        $c = $State["$Key.Dec"].GetChars($buf, 0, $n, $chars, 0)
        return [string]::new($chars, 0, $c)
    } finally { $fs.Dispose() }
}

function Flush-BenchOutput {
    foreach ($key in @('out', 'err')) {
        $text = Read-NewText $script:job $key
        if ($text) {
            $ui.BenchOut.AppendText(($text -replace "`r?`n", "`r`n"))
            $ui.BenchOut.ScrollToEnd()
        }
    }
}

function Set-BenchBusy([bool]$Busy) {
    $ui.BenchBtn.IsEnabled = -not $Busy
    $ui.CancelBtn.IsEnabled = $Busy
    if (-not $Busy) { $ui.BenchState.Text = '' }
}

function Start-BenchQueue {
    $rows = @(Get-SelectedConfigs)
    if ($rows.Count -eq 0) { [void](Get-Selected); return }
    $py = Get-Python
    if (-not $py) {
        [System.Windows.MessageBox]::Show("No .venv in $(Get-Root). Run START-HERE.bat there first.", 'Strata') | Out-Null
        return
    }
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($r in $rows) { $queue.Enqueue($r) }
    $script:job = @{ Queue = $queue; Row = $null; Phase = 'next'; Many = ($rows.Count -gt 1); Done = @() }
    $ui.Tabs.SelectedIndex = 1
    Set-BenchBusy $true
    Write-BenchLine ("=== {0}: benchmarking {1}" -f (Get-Date -Format 'HH:mm:ss'), (($rows | ForEach-Object { $_.Model }) -join ', '))
}

function Invoke-BenchStep {
    $job = $script:job
    if (-not $job) { return }
    switch ($job.Phase) {
        'next' {
            if ($job.Queue.Count -eq 0) {
                Write-BenchLine ("=== {0}: done." -f (Get-Date -Format 'HH:mm:ss'))
                if ($job.Done.Count -gt 1 -and $job.Done[0].Dir -and $job.Done[-1].Dir) {
                    Write-BenchLine 'Select the new results on the Results tab and use "Compare two selected" to see them side by side.'
                }
                $script:job = $null
                Set-BenchBusy $false
                Read-Results
                return
            }
            $row = $job.Queue.Dequeue()
            $job.Row = $row
            $job.T0 = Get-Date
            $job.WeStarted = $false
            if (-not (Test-RowReady $row)) {
                Write-BenchLine "--- $($row.Model): starting the server (port $($row.Port))..."
                if (-not (Start-Server $row -Quiet)) { Write-BenchLine '    could not start it, skipped.'; return }
                $job.WeStarted = $true
            } else {
                Write-BenchLine "--- $($row.Model): using the server already running on port $($row.Port)."
                if ($ui.CtxBox.Text.Trim() -and $ui.CtxBox.Text -ne '(config)' -or $ui.ExtraBox.Text.Trim()) {
                    Write-BenchLine '    note: overrides only apply when the server is started from here; stop it to benchmark with them.'
                }
            }
            $job.Phase = 'loading'
        }
        'loading' {
            $row = $job.Row
            Request-LoadIfIdle $row
            if (Test-RowReady $row) {
                $job.Phase = 'bench'
                Start-BenchProcess $row
                return
            }
            $elapsed = ((Get-Date) - $job.T0).TotalSeconds
            $ui.BenchState.Text = 'Loading {0} ({1:n0} s)...' -f $row.Model, $elapsed
            $proc = $script:started[$row.Port]
            if ($job.WeStarted -and $proc -and $proc.HasExited -and -not ($script:health[$row.Port] -and $script:health[$row.Port].Up)) {
                Write-BenchLine "    the server window closed before the model loaded. See its log: $($row.Log)"
                $job.Phase = 'next'
            } elseif ($elapsed -gt $LoadTimeoutMinutes * 60) {
                Write-BenchLine "    the model did not load within $LoadTimeoutMinutes minutes, skipped."
                if ($job.WeStarted) { [void](Stop-Row $row) }
                $job.Phase = 'next'
            }
        }
        'bench' {
            Flush-BenchOutput
            $elapsed = ((Get-Date) - $job.T0).TotalSeconds
            $ui.BenchState.Text = 'Benchmarking {0} ({1:n0} s)...' -f $job.Row.Model, $elapsed
            if (-not $job.Proc.HasExited) { return }
            $job.Proc.WaitForExit()
            Flush-BenchOutput
            $code = $job.Proc.ExitCode
            $dir = Get-ChildItem -LiteralPath (Join-Path (Get-Root) 'bench\results') -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.CreationTime -ge $job.BenchStart } | Sort-Object CreationTime -Descending | Select-Object -First 1
            Write-BenchLine "--- $($job.Row.Model): finished (exit code $code)$(if ($dir) { ", results in $($dir.Name)" })"
            $job.Done += [pscustomobject]@{ Model = $job.Row.Model; Dir = $(if ($dir) { $dir.FullName }) }
            if ($ui.StopAfterChk.IsChecked -or ($job.Many -and $job.Queue.Count -gt 0)) {
                Write-BenchLine "    stopping the server on port $($job.Row.Port)."
                [void](Stop-Row $job.Row)
            }
            $job.Phase = 'next'
        }
    }
}

function Start-BenchProcess($Row) {
    $job = $script:job
    $root = Get-Root
    $out = Join-Path $TempDir "bench-$PID.out.txt"
    $err = Join-Path $TempDir "bench-$PID.err.txt"
    if (-not (Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Path $TempDir | Out-Null }
    $cfgPath = if ($job.WeStarted) { Get-EffectiveConfig $Row } else { $Row.Path }
    $bargs = "-u $(QPath (Join-Path $root 'tools\strata_bench.py')) --url $(Get-BaseUrl $Row) --config $(QPath $cfgPath) --runs $($ui.RunsBox.SelectedItem)"
    if ([int]$ui.ClientsBox.SelectedItem -gt 0) { $bargs += " --clients $($ui.ClientsBox.SelectedItem)" }
    if ($ui.LongChk.IsChecked) { $bargs += ' --long' }
    if ($ui.ThinkChk.IsChecked) { $bargs += ' --think' }
    $cmp = $ui.CompareBox.SelectedItem
    if ($cmp -and $cmp -ne '(none)') { $bargs += " --compare $(QPath (Join-Path $root "bench\results\$cmp"))" }
    $env:PYTHONUNBUFFERED = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    Write-BenchLine "    python $bargs"
    $job.BenchStart = (Get-Date).AddSeconds(-2)
    $job.T0 = Get-Date
    $job['out.File'] = $out; $job['out.Pos'] = 0L; $job['out.Dec'] = [Text.Encoding]::UTF8.GetDecoder()
    $job['err.File'] = $err; $job['err.Pos'] = 0L; $job['err.Dec'] = [Text.Encoding]::UTF8.GetDecoder()
    $job.Proc = Start-Process -FilePath (Get-Python) -ArgumentList $bargs -WorkingDirectory $root -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
}

function Stop-Bench {
    $job = $script:job
    if (-not $job) { return }
    if ($job.Proc -and -not $job.Proc.HasExited) { & taskkill.exe /PID $job.Proc.Id /T /F 2>$null | Out-Null }
    if ($job.Row -and ($job.WeStarted -or $ui.StopAfterChk.IsChecked)) { [void](Stop-Row $job.Row) }
    Write-BenchLine ("=== {0}: cancelled." -f (Get-Date -Format 'HH:mm:ss'))
    $script:job = $null
    Set-BenchBusy $false
}

# ------------------------------------------------------------------------------------ results
function Get-Median($Stat, [string]$Format = '{0:n1}') {
    if ($Stat -and $null -ne $Stat.median) { return ($Format -f [double]$Stat.median) }
    return '-'
}

function Read-Results {
    $dir = Join-Path (Get-Root) 'bench\results'
    $script:results.Clear()
    $compare = @('(none)')
    if (Test-Path -LiteralPath $dir) {
        foreach ($d in (Get-ChildItem -LiteralPath $dir -Directory | Sort-Object Name -Descending)) {
            $file = Join-Path $d.FullName 'results.json'
            $j = $null
            if (Test-Path -LiteralPath $file) {
                try { $j = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
            }
            $bench = ($j -and $j.schema -and $j.results -and $j.results.PSObject.Properties['chat'])
            if (-not $bench -and $ui.OnlyBenchChk.IsChecked) { continue }
            $row = [pscustomobject]@{ Name = $d.Name; Path = $d.FullName; Model = '-'; Context = '-'; Decode = '-'; P4 = '-'; P16 = '-'; Hit = '-'; Json = $null }
            if ($bench) {
                $r = $j.results
                $row.Json = $j
                $row.Model = (@($j.machine.model, $j.machine.quant) | Where-Object { $_ }) -join ' '
                $row.Context = Format-Tokens $j.machine.context
                $row.Decode = Get-Median $r.chat.decode_tps
                if ($r.prompts) {
                    $row.P4 = Get-Median $r.prompts.'4K'.prompt_tps '{0:n0}'
                    $row.P16 = Get-Median $r.prompts.'16K'.prompt_tps '{0:n0}'
                }
                if ($r.agent) { $row.Hit = Get-Median $r.agent.hit_pct }
                $compare += $d.Name
            }
            $script:results.Add($row)
        }
    }
    $prev = $ui.CompareBox.SelectedItem
    $ui.CompareBox.ItemsSource = $compare
    $ui.CompareBox.SelectedItem = $(if ($compare -contains $prev) { $prev } else { '(none)' })
}

function Show-ResultDetail($Row) {
    if (-not $Row) { $ui.ResDetail.Text = ''; return }
    $readme = Join-Path $Row.Path 'README.md'
    $lines = @()
    if ($Row.Json) {
        $j = $Row.Json
        $m = $j.machine
        $lines += "Date:     $($j.date)    suite took $([int]$j.elapsed_s) s    $($j.params.command)"
        $lines += "GPU:      $((@($m.gpu) -join ' + '))    driver $($m.gpu_driver)    CUDA $($m.cuda)"
        $lines += "CPU/RAM:  $($m.cpu)    $($m.ram_gib) GiB"
        $lines += "Model:    $($m.model)  $($m.quant)    context $($m.context)    engine $($m.engine_version)"
        $lines += ''
        $lines += '{0,-34} {1,10}   {2}' -f 'metric', 'median', 'range (n)'
        $r = $j.results
        $metrics = [ordered]@{ 'chat decode tok/s' = $r.chat.decode_tps; 'chat first token (s)' = $r.chat.ttft_s }
        if ($r.prompts) {
            foreach ($p in $r.prompts.PSObject.Properties) {
                $metrics["$($p.Name) prompt tok/s"] = $p.Value.prompt_tps
                $metrics["$($p.Name) first token (s)"] = $p.Value.ttft_s
            }
        }
        if ($r.agent) {
            $metrics['agent cache hit %'] = $r.agent.hit_pct
            $metrics['agent re-read tokens/session'] = $r.agent.reread_tokens
            $metrics['agent turn first token (s)'] = $r.agent.turn_ttft_s
            $metrics['agent decode tok/s'] = $r.agent.turn_decode_tps
        }
        if ($r.clients) { $metrics["$($r.clients.clients) clients total tok/s"] = $r.clients.total_tps }
        foreach ($k in $metrics.Keys) {
            $s = $metrics[$k]
            if ($s -and $null -ne $s.median) {
                $lines += '{0,-34} {1,10:n2}   {2:n2} - {3:n2} (n={4})' -f $k, [double]$s.median, [double]$s.min, [double]$s.max, $s.n
            }
        }
        if ($m.launch) { $lines += ''; $lines += $m.launch }
    } elseif (Test-Path -LiteralPath $readme) {
        $lines = Get-Content -LiteralPath $readme -Encoding UTF8 -TotalCount 80
    } else {
        $lines = @('No README.md or strata_bench results.json in this folder.')
    }
    $ui.ResDetail.Text = $lines -join "`r`n"
}

function Compare-Results {
    $sel = @($ui.ResultList.SelectedItems | Where-Object { $_.Json } | Sort-Object Name)
    if ($sel.Count -ne 2) {
        [System.Windows.MessageBox]::Show('Select exactly two strata_bench results (Ctrl+click).', 'Strata') | Out-Null
        return
    }
    $py = Get-Python
    $tool = Join-Path (Get-Root) 'tools\strata_bench.py'
    $text = & $py $tool --compare $sel[0].Path --compare-only $sel[1].Path 2>&1 | Out-String
    $ui.ResDetail.Text = "old: $($sel[0].Name)`r`nnew: $($sel[1].Name)`r`n`r`n" + ($text -replace "`r?`n", "`r`n")
}

# ------------------------------------------------------------------------------------ on-demand service
$ServiceTask = 'Strata on-demand'
$script:httpLong = New-Object System.Net.Http.HttpClient
$script:httpLong.Timeout = [TimeSpan]::FromMinutes($LoadTimeoutMinutes)
$script:loadTasks = @{}     # port -> pending POST /load
$script:svcTick = 0

function Get-ServiceTask { Get-ScheduledTask -TaskName $ServiceTask -ErrorAction SilentlyContinue }

function Get-ServiceRow {
    # The config the installed service runs, from its task (so it is right even if the box changed).
    $task = Get-ServiceTask
    if (-not $task -or [string]$task.Actions[0].Arguments -notmatch '-Config "([^"]+)"') { return $null }
    $path = $Matches[1]
    return ($script:configs | Where-Object { $_.Path -eq $path } | Select-Object -First 1)
}

function Test-ServiceRow($Row) {
    $svc = Get-ServiceRow
    return ($svc -and $Row -and $svc.Path -eq $Row.Path)
}

function Get-ServiceProcesses($Row) {
    # The server processes the service started for this config (they carry --lazy and its config path).
    @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine.Contains($Row.Path) -and $_.CommandLine -match '--lazy'
    } | Select-Object -ExpandProperty ProcessId)
}

function Install-StrataService {
    $row = $script:configs | Where-Object { $_.File -eq $ui.SvcModelBox.SelectedItem } | Select-Object -First 1
    if (-not $row) { [System.Windows.MessageBox]::Show('Choose the model the service runs.', 'Strata') | Out-Null; return }
    $py = Get-Python
    if (-not $py) { [System.Windows.MessageBox]::Show("No .venv in $(Get-Root). Run START-HERE.bat there first.", 'Strata') | Out-Null; return }
    $minutes = $ui.SvcIdleBox.Text.Trim()
    if ($minutes -notmatch '^\d+(\.\d+)?$' -or [double]$minutes -le 0) {
        [System.Windows.MessageBox]::Show('Unload after: a number of minutes.', 'Strata') | Out-Null
        return
    }
    $old = Get-ServiceRow
    $task = Get-ServiceTask
    $wasRunning = $task -and $task.State -eq 'Running'
    if ($wasRunning) { [void](Stop-StrataService) }
    if ($old -and $old.Path -ne $row.Path -and (Test-RowRunning $row)) {
        [System.Windows.MessageBox]::Show("$($row.Model) is already running (started from the Launch tab). Stop it first.", 'Strata') | Out-Null
        return
    }
    $seconds = [int]([double]$minutes * 60)
    $taskArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $(QPath $PSCommandPath) -Service " +
        "-StrataRoot $(QPath (Get-Root)) -Config $(QPath $row.Path) -Port $($row.Port) -IdleSeconds $seconds"
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $taskArgs -WorkingDirectory (Get-Root)
    $settingsSet = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $params = @{ TaskName = $ServiceTask; Action = $action; Settings = $settingsSet; Principal = $principal; Force = $true
                 Description = "Strata $($row.Model) on demand (port $($row.Port), unloads after $minutes min idle). Managed by strata-gui.ps1." }
    if ($ui.SvcLogonChk.IsChecked) { $params.Trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME" }
    try { Register-ScheduledTask @params -ErrorAction Stop | Out-Null } catch {
        [System.Windows.MessageBox]::Show("Could not register the scheduled task: $($_.Exception.Message)", 'Strata') | Out-Null
        return
    }
    Set-Status "Service installed: $($row.Model) on port $($row.Port), unloads after $minutes min$(if ($ui.SvcLogonChk.IsChecked) { ', starts at logon' })."
    if ($wasRunning) { Start-StrataService }
    Update-ServiceStatus
}

function Start-StrataService {
    $task = Get-ServiceTask
    if (-not $task) { [System.Windows.MessageBox]::Show('Install the service first.', 'Strata') | Out-Null; return }
    $row = Get-ServiceRow
    if ($row -and -not (Test-RowRunning $row) -and (Get-PortListeners $row.Port).Count -gt 0) {
        [System.Windows.MessageBox]::Show("Port $($row.Port) is in use by another server. Stop it first.", 'Strata') | Out-Null
        return
    }
    if ($row -and (Test-StartedHere $row)) {
        [System.Windows.MessageBox]::Show("$($row.Model) is running from the Launch tab. Stop it there first.", 'Strata') | Out-Null
        return
    }
    Start-ScheduledTask -TaskName $ServiceTask
    Set-Status 'Service started; the model loads with the first request.'
    Update-ServiceStatus
}

function Stop-StrataService {
    # Ends the task first (so it is not restarted as a failure), then its server.
    $row = Get-ServiceRow
    if (Get-ServiceTask) { Stop-ScheduledTask -TaskName $ServiceTask -ErrorAction SilentlyContinue }
    if (-not $row) { return $false }
    $ids = @(Get-ServiceProcesses $row)
    $h = $script:health[$row.Port]
    if ($h -and $h.Up -and $h.Model -eq $row.Model -and -not (Test-StartedHere $row)) { $ids += Get-PortListeners $row.Port }
    foreach ($id in ($ids | Select-Object -Unique)) { & taskkill.exe /PID $id /T /F 2>$null | Out-Null }
    $script:health.Remove($row.Port)
    Update-ServiceStatus
    return ($ids.Count -gt 0)
}

function Remove-StrataService {
    if (-not (Get-ServiceTask)) { Set-Status 'No service is installed.'; return }
    if ([System.Windows.MessageBox]::Show('Stop and remove the on-demand service?', 'Strata', 'YesNo') -ne 'Yes') { return }
    [void](Stop-StrataService)
    Unregister-ScheduledTask -TaskName $ServiceTask -Confirm:$false -ErrorAction SilentlyContinue
    Set-Status 'Service removed.'
    Update-ServiceStatus
}

function Request-Load($Row) {
    # POST /load: loads an unloaded (lazy or idle-unloaded) model now; returns at once, the load runs on.
    if ($script:loadTasks[$Row.Port] -and -not $script:loadTasks[$Row.Port].IsCompleted) { return }
    $body = New-Object System.Net.Http.StringContent('{}', [Text.Encoding]::UTF8, 'application/json')
    $script:loadTasks[$Row.Port] = $script:httpLong.PostAsync("http://127.0.0.1:$($Row.Port)/load", $body)
}

function Request-Unload($Row) {
    $body = New-Object System.Net.Http.StringContent('{}', [Text.Encoding]::UTF8, 'application/json')
    try {
        $r = $script:http.PostAsync("http://127.0.0.1:$($Row.Port)/unload", $body).Result
        return [int]$r.StatusCode
    } catch { return 0 }
}

function Request-LoadIfIdle($Row) {
    # A server that is up with this model unloaded (on demand, or unloaded after idle): load it now.
    # Not for a server started from the Launch tab: that one is still loading by itself.
    $h = $script:health[$Row.Port]
    if ($h -and $h.Up -and -not $h.Loaded -and $h.Model -eq $Row.Model -and -not (Test-StartedHere $Row)) { Request-Load $Row }
}

function Update-ServiceStatus {
    $task = Get-ServiceTask
    $row = Get-ServiceRow
    $lines = @()
    if (-not $task) {
        $lines += 'Not installed.'
    } else {
        $info = Get-ScheduledTaskInfo -TaskName $ServiceTask -ErrorAction SilentlyContinue
        $logon = [bool]($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
        $lines += "Task:    $($task.State)$(if ($logon) { ', starts at logon' } else { ', started by hand' })" +
            $(if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { ", last run $($info.LastRunTime)" })
        if ($row) {
            $h = $script:health[$row.Port]
            $state = if (-not $h -or -not $h.Up) { 'not running' }
                elseif ($h.Model -ne $row.Model) { "port used by $($h.Model)" }
                elseif ($h.Loaded) { "loaded ($(Format-Tokens $h.Context) ctx)" }
                elseif ($script:loadTasks[$row.Port] -and -not $script:loadTasks[$row.Port].IsCompleted) { 'loading...' }
                else { 'running, model unloaded (loads with the first request)' }
            $lines += "Model:   $($row.Model)  (port $($row.Port), API http://127.0.0.1:$($row.Port)/v1)"
            $lines += "Server:  $state"
        } else {
            $lines += 'Model:   the config in the service script is not in this Strata folder any more.'
        }
        if ($task.Description -match 'after ([\d\.]+) min') { $lines += "Idle:    unloads after $($Matches[1]) min without requests" }
    }
    $ui.SvcStatus.Text = $lines -join "`r`n"
    if ($task) { $ui.SvcLogonChk.IsChecked = [bool]($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }) }
}

function Update-ServicePicker {
    $prev = $ui.SvcModelBox.SelectedItem
    $ui.SvcModelBox.ItemsSource = @($script:configs | ForEach-Object { $_.File })
    $svc = Get-ServiceRow
    $want = if ($svc) { $svc.File } elseif ($prev) { $prev } elseif ($settings.ServiceConfig) { Split-Path $settings.ServiceConfig -Leaf } else { $null }
    $ui.SvcModelBox.SelectedItem = $want
    if (-not $ui.SvcModelBox.SelectedItem -and $script:configs.Count -gt 0) { $ui.SvcModelBox.SelectedIndex = 0 }
}

# ------------------------------------------------------------------------------------ model catalog
# setup.py holds the catalog (sizes and RAM needs per quant); it is read from this checkout so it stays current.
$CatalogPy = @'
import json, sys
sys.path.insert(0, sys.argv[1])
import setup as S
out = {"ram_gib": S.ram_gb(), "headroom": S.LOW_RAM_HEADROOM_GB, "beside": S.UNSLOTH_RESIDENT_BESIDE_GB,
       "unsloth_min": S.UNSLOTH_MIN_RAM_GB, "models": []}
for fam, fd in S.FAMILIES.items():
    for q, m in S.MODELS.items():
        if fam not in m.get("families", ("qwen", "swift")):
            continue
        out["models"].append({"family": fam, "title": fd["title"], "name": fd.get("name", ""), "quant": q,
                              "about": m.get("about", ""), "family_about": fd.get("about", ""),
                              "download_gb": m.get("download_gb"), "ram_gb": m.get("ram_gb"), "arena_gb": m.get("arena_gb"),
                              "budget": bool(m.get("budget")), "nvidia_only": bool(m.get("nvidia_only")),
                              "vision": bool(m.get("vision", fd.get("vision"))), "own_path": False})
for fam, fd in getattr(S, "OWN_PATH_FAMILIES", {}).items():
    for q, m in fd.get("models", {}).items():
        size = fd.get("sha256", {}).get(fd["file"].format(q=q), (0,))[0]
        out["models"].append({"family": fam, "title": fd["title"], "name": fd.get("name", ""), "quant": q,
                              "about": m.get("about", ""), "family_about": fd.get("about", ""),
                              "download_gb": round(size / 1e9, 1), "ram_gb": m.get("ram_gb"), "arena_gb": None,
                              "budget": False, "nvidia_only": False, "vision": bool(fd.get("vision")), "own_path": True})
print(json.dumps(out))
'@
$script:catalog = $null
$script:catalogRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ui.CatalogList.ItemsSource = $script:catalogRows

function Get-DefaultDataFolder {
    foreach ($row in $script:configs) {
        $pack = Get-ArgValue $row.Cfg.args '--pack'
        if ($pack -and $pack -match '^(.*)[\\/]packs[\\/]') { return $Matches[1] }
    }
    return (Get-Root)
}

function Get-GpuInfo {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        $lines = & $smi.Source --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        $gpus = @($lines | Where-Object { $_ -match ',' } | ForEach-Object {
            $name, $mib = $_ -split ',\s*'
            '{0} {1:n0} GB' -f $name.Trim(), ([double]$mib / 1024)
        })
        if ($gpus.Count -gt 0) { return @{ Nvidia = $true; Text = ($gpus -join ' + ') } }
    }
    $names = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    return @{ Nvidia = [bool]($names -match 'NVIDIA'); Text = $(if ($names) { $names -join ' + ' } else { 'no GPU found' }) }
}

function Read-Catalog {
    $py = Get-Python
    if (-not $py) { $ui.MachineText.Text = "No .venv in $(Get-Root): run START-HERE.bat there first."; return }
    if (-not (Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Path $TempDir | Out-Null }
    $file = Join-Path $TempDir 'catalog.py'
    Set-Content -LiteralPath $file -Value $CatalogPy -Encoding ascii
    Push-Location -LiteralPath (Get-Root)
    try { $json = & $py -I $file (Get-Root) 2>$null | Out-String } finally { Pop-Location }
    try { $script:catalog = $json | ConvertFrom-Json } catch {
        $script:catalog = $null
        $ui.MachineText.Text = 'Could not read the model catalog from setup.py.'
        return
    }
    $script:gpu = Get-GpuInfo
    if (-not $ui.DataBox.Text.Trim()) { $ui.DataBox.Text = Get-DefaultDataFolder }
    Update-CatalogFit
}

function Update-CatalogFit {
    $cat = $script:catalog
    if (-not $cat) { return }
    $ram = [double]$cat.ram_gib
    $data = Clean-Path $ui.DataBox.Text
    $free = $null
    try { $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($data))).AvailableFreeSpace / 1e9 } catch {}
    $mtpHave = Test-Path -LiteralPath (Join-Path $data 'mtp\rt\experts.bin')
    $installed = @($script:configs | ForEach-Object { $_.Model.ToLower() })
    $ui.MachineText.Text = 'This PC: {0:n0} GiB RAM;  GPU: {1};  free on {2}: {3}' -f $ram, $script:gpu.Text, $data,
        $(if ($null -ne $free) { '{0:n0} GB' -f $free } else { 'unknown' })
    $script:catalogRows.Clear()
    foreach ($m in $cat.models) {
        $lowRam = $false
        if ($m.nvidia_only -and -not $script:gpu.Nvidia) {
            $ramLevel = 'bad'; $ramFit = 'needs an NVIDIA GPU'
        } elseif ($m.own_path) {
            if ($ram -ge $m.ram_gb) { $ramLevel = 'ok'; $ramFit = 'fits' } else { $ramLevel = 'bad'; $ramFit = 'too little RAM' }
        } elseif ($m.budget) {
            $full = $m.arena_gb / 1.073741824 + $cat.beside
            if ($ram -ge $full) { $ramLevel = 'ok'; $ramFit = 'all experts in RAM' }
            elseif ($ram -ge $cat.unsloth_min) { $ramLevel = 'warn'; $ramFit = 'RAM budget, rest from SSD' }
            else { $ramLevel = 'bad'; $ramFit = "needs at least $($cat.unsloth_min) GB" }
        } else {
            $full = [math]::Max([double]$m.ram_gb, $m.arena_gb + $cat.headroom)
            if ($ram -ge $full) { $ramLevel = 'ok'; $ramFit = 'all experts in RAM' }
            else { $ramLevel = 'warn'; $ramFit = 'low-RAM mode, from SSD'; $lowRam = $true }
        }
        $need = [double]$m.download_gb
        if ($m.own_path) { $need += 1 } else {
            $need += $(if ($mtpHave) { 2 } else { 8 })
            if ($lowRam) { $need += $m.arena_gb + 1 }
        }
        $isInstalled = $installed -contains ('{0}-{1}' -f $m.name, $m.quant).ToLower()
        if ($isInstalled) { $diskLevel = 'ok'; $diskFit = 'installed' }
        elseif ($null -eq $free) { $diskLevel = 'warn'; $diskFit = 'free space unknown' }
        elseif ($free -ge $need) { $diskLevel = 'ok'; $diskFit = '{0:n0} GB left after' -f ($free - $need) }
        else { $diskLevel = 'bad'; $diskFit = '{0:n0} GB short' -f ($need - $free) }
        $order = @{ ok = 0; warn = 1; bad = 2 }
        $level = if ($order[$diskLevel] -gt $order[$ramLevel]) { $diskLevel } else { $ramLevel }
        if ($ui.FitOnlyChk.IsChecked -and $level -eq 'bad') { continue }
        $row = [pscustomobject]@{
            Title     = $m.title
            Family    = $m.family
            Quant     = $m.quant
            Download  = '{0:n1}' -f [double]$m.download_gb
            Disk      = '{0:n0}' -f $need
            Ram       = $(if ($m.budget) { '{0}-{1:n0}' -f $cat.unsloth_min, ($m.arena_gb / 1.073741824 + $cat.beside) } else { [string]$m.ram_gb })
            RamFit    = $ramFit
            DiskFit   = $diskFit
            Installed = $(if ($isInstalled) { 'yes' } else { '' })
            Level     = $level
            About     = "$($m.title) $($m.quant): $($m.about). Family: $($m.family_about)." +
                $(if ($m.arena_gb) { " Experts: $($m.arena_gb) GB." } else { '' }) +
                $(if ($m.vision) { ' Reads images.' } else { '' })
        }
        $script:catalogRows.Add($row)
    }
}

function Install-CatalogModel {
    $row = $ui.CatalogList.SelectedItem
    if (-not $row) { [System.Windows.MessageBox]::Show('Select a model in the list first.', 'Strata') | Out-Null; return }
    $bat = Join-Path (Get-Root) 'START-HERE.bat'
    if (-not (Test-Path -LiteralPath $bat)) { [System.Windows.MessageBox]::Show("Missing $bat", 'Strata') | Out-Null; return }
    $msg = "Run Strata setup for $($row.Title) $($row.Quant)?`n`nDownload: $($row.Download) GB, disk need ~$($row.Disk) GB.`nRAM: $($row.RamFit). Disk: $($row.DiskFit).`n`nSetup opens in its own window and asks the remaining questions there."
    if ($row.Level -eq 'bad') { $msg = "This model does not fit this PC by setup's estimate.`n`n" + $msg }
    if ([System.Windows.MessageBox]::Show($msg, 'Strata', 'YesNo') -ne 'Yes') { return }
    $line = "$(QPath $bat) --family $($row.Family) --model $($row.Quant)"
    $data = Clean-Path $ui.DataBox.Text
    if ($data -and $data -ne (Get-Root)) { $line += " --data-dir $(QPath $data)" }
    Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList "/s /c `"$line`"" -WorkingDirectory (Get-Root)
    Set-Status "Setup started for $($row.Title) $($row.Quant). Refresh the model list when it has finished."
}

# ------------------------------------------------------------------------------------ wire up
function Select-Folder([string]$Initial, [string]$Description) {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    if ($Initial -and (Test-Path -LiteralPath $Initial -PathType Container)) { $dialog.SelectedPath = $Initial }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    return $null
}

$ui.RootBox.Text = $settings.StrataRoot
$ui.FolderBox.Text = $settings.ClineFolder
$ui.ClineScriptBox.Text = $settings.ClineScript
$ui.ExtraBox.Text = $settings.ExtraArgs
$ui.VramBox.Text = $settings.VramReserve
$ui.FitChk.IsChecked = [bool]$settings.FitMaxTokens
foreach ($v in @('5', '10', '15', '20')) { [void]$ui.ReserveBox.Items.Add($v) }
$ui.ReserveBox.SelectedItem = $(if (@('5', '10', '15', '20') -contains [string]$settings.ReservePercent) { [string]$settings.ReservePercent } else { '10' })
$ClineReservePercent = [int]$ui.ReserveBox.SelectedItem
$ui.ReserveBox.Add_SelectionChanged({ $script:ClineReservePercent = [int]$ui.ReserveBox.SelectedItem; Update-CtxHint })
$ui.CtxBox.Add_SelectionChanged({ $window.Dispatcher.BeginInvoke([action]{ Update-CtxHint }) | Out-Null })
$ui.CtxBox.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.Controls.TextChangedEventHandler]{ Update-CtxHint })
$ui.ConfigList.Add_SelectionChanged({ Update-CtxHint })
$ui.OpenWebChk.IsChecked = [bool]$settings.OpenWeb
$ui.MinChk.IsChecked = [bool]$settings.Minimized
$ui.OllamaChk.IsChecked = [bool]$settings.UnloadOllama
$ui.LongChk.IsChecked = [bool]$settings.Long
$ui.ThinkChk.IsChecked = [bool]$settings.Think
$ui.StopAfterChk.IsChecked = [bool]$settings.StopAfter
$ui.DataBox.Text = $settings.DataFolder
$ui.FitOnlyChk.IsChecked = [bool]$settings.FitOnly
foreach ($v in @('5', '10', '15', '30', '60', '120')) { [void]$ui.SvcIdleBox.Items.Add($v) }
$ui.SvcIdleBox.Text = $(if ($settings.ServiceIdle) { $settings.ServiceIdle } else { '15' })
# Steps up to the trained 262144 run unscaled; past it Set-ContextArgs adds yarn, so those say so.
foreach ($v in @('(config)', '32768', '65536', '131072', '204800', '262144', '393216  (yarn x1.5, experimental)',
                 '524288  (yarn x2, experimental)', '1048576  (yarn x4, experimental)')) { [void]$ui.CtxBox.Items.Add($v) }
$ui.CtxBox.Text = $(if ($settings.Context) { $settings.Context } else { '(config)' })
foreach ($v in @('(default)') + $ThinkingLevels) { [void]$ui.ThinkingBox.Items.Add($v) }
$ui.ThinkingBox.SelectedItem = $(if ($ThinkingLevels -contains $settings.Thinking) { $settings.Thinking } else { '(default)' })
foreach ($v in 1..5) { [void]$ui.RunsBox.Items.Add([string]$v) }
$ui.RunsBox.SelectedItem = [string]$settings.Runs
if (-not $ui.RunsBox.SelectedItem) { $ui.RunsBox.SelectedItem = '3' }
foreach ($v in @('0', '2', '4', '8')) { [void]$ui.ClientsBox.Items.Add($v) }
$ui.ClientsBox.SelectedItem = [string]$settings.Clients
if (-not $ui.ClientsBox.SelectedItem) { $ui.ClientsBox.SelectedItem = '0' }

$ui.RootBrowse.Add_Click({
    $p = Select-Folder (Get-Root) 'Select the Strata folder (the one with START-HERE.bat)'
    if ($p) { $ui.RootBox.Text = $p; Read-Configs; Update-ServicePicker; Read-Results }
})
$ui.RefreshBtn.Add_Click({ Read-Configs; Update-ServicePicker; Read-Results })
$ui.FolderBrowse.Add_Click({
    $p = Select-Folder $ui.FolderBox.Text 'Select the folder Cline should open'
    if ($p) { $ui.FolderBox.Text = $p }
})
$ui.ClineScriptBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'PowerShell scripts (*.ps1)|*.ps1'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $ui.ClineScriptBox.Text = $dialog.FileName }
})

$ui.StartBtn.Add_Click({
    $row = Get-Selected
    if (-not $row) { return }
    if (Test-RowReady $row) { Set-Status "$($row.Model) is already running on port $($row.Port)."; return }
    $h = $script:health[$row.Port]
    if ($h -and $h.Up -and $h.Model -eq $row.Model -and -not (Test-StartedHere $row)) {
        Request-Load $row
        Set-Status "Loading $($row.Model)..."
        return
    }
    [void](Start-Server $row)
})
$ui.StopBtn.Add_Click({
    $row = Get-Selected
    if (-not $row) { return }
    if ($script:job -and $script:job.Row -and $script:job.Row.Path -eq $row.Path) { Stop-Bench }
    if (Stop-Row $row) { Set-Status "Stopped $($row.Model)." }
    else { Set-Status "$($row.Model) is not running; nothing was stopped." }
})
$ui.WebBtn.Add_Click({
    $row = Get-Selected
    if ($row) { Start-Process (Get-BaseUrl $row) }
})
$ui.LogBtn.Add_Click({
    $row = Get-Selected
    if (-not $row) { return }
    if ($row.Log -and (Test-Path -LiteralPath $row.Log)) { Start-Process notepad.exe -ArgumentList "`"$($row.Log)`"" }
    else { Set-Status "No engine log yet: $($row.Log)" }
})
$ui.ConfigBtn.Add_Click({
    $row = Get-Selected
    if ($row) { Start-Process notepad.exe -ArgumentList "`"$($row.Path)`"" }
})
$ui.ClineBtn.Add_Click({
    $row = Get-Selected
    if (-not $row) { return }
    $launcher = Clean-Path $ui.ClineScriptBox.Text
    $folder = Clean-Path $ui.FolderBox.Text
    if (-not (Test-Path -LiteralPath $launcher)) { [System.Windows.MessageBox]::Show("Launcher script not found: $launcher", 'Strata') | Out-Null; return }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [System.Windows.MessageBox]::Show('Choose a project folder.', 'Strata') | Out-Null; return }
    if (Test-RowReady $row) { Start-Cline $row; return }
    if (-not (Start-Server $row)) { return }
    $script:clinePending = @{ Row = $row; T0 = Get-Date }
    Set-Status "Cline opens once $($row.Model) has loaded..."
})

$ui.BenchBtn.Add_Click({ Start-BenchQueue })
$ui.CancelBtn.Add_Click({ Stop-Bench })
$ui.ClearBtn.Add_Click({ $ui.BenchOut.Clear() })

$ui.ResRefreshBtn.Add_Click({ Read-Results })
$ui.OnlyBenchChk.Add_Click({ Read-Results })
$ui.ResultList.Add_SelectionChanged({ Show-ResultDetail $ui.ResultList.SelectedItem })
$ui.ResReadmeBtn.Add_Click({
    $row = $ui.ResultList.SelectedItem
    if (-not $row) { return }
    $readme = Join-Path $row.Path 'README.md'
    if (Test-Path -LiteralPath $readme) { Start-Process notepad.exe -ArgumentList "`"$readme`"" }
})
$ui.ResFolderBtn.Add_Click({
    $row = $ui.ResultList.SelectedItem
    if ($row) { Start-Process explorer.exe -ArgumentList "`"$($row.Path)`"" }
})
$ui.ResCompareBtn.Add_Click({ Compare-Results })

$ui.Tabs.Add_SelectionChanged({
    param($sender, $e)
    if ($e.OriginalSource -eq $ui.Tabs -and $ui.Tabs.SelectedItem -eq $ui.ServiceTab) { Update-ServiceStatus }
    if ($e.OriginalSource -eq $ui.Tabs -and $ui.Tabs.SelectedItem -eq $ui.ModelsTab -and -not $script:catalog) {
        Set-Status 'Reading the model catalog from setup.py...'
        Read-Catalog
        Set-Status "$($script:catalogRows.Count) catalog model(s)."
    }
})
$ui.CatRefreshBtn.Add_Click({ Read-Catalog })
$ui.FitOnlyChk.Add_Click({ Update-CatalogFit })
$ui.DataBox.Add_LostFocus({ Update-CatalogFit })
$ui.DataBrowse.Add_Click({
    $p = Select-Folder $ui.DataBox.Text 'Select the Strata data folder (where models and packs go)'
    if ($p) { $ui.DataBox.Text = $p; Update-CatalogFit }
})
$ui.CatalogList.Add_SelectionChanged({
    $row = $ui.CatalogList.SelectedItem
    if ($row) { $ui.CatDetail.Text = $row.About }
})
$ui.InstallBtn.Add_Click({ Install-CatalogModel })

$ui.SvcApplyBtn.Add_Click({ Install-StrataService })
$ui.SvcRemoveBtn.Add_Click({ Remove-StrataService })
$ui.SvcStartBtn.Add_Click({ Start-StrataService })
$ui.SvcStopBtn.Add_Click({
    if (Stop-StrataService) { Set-Status 'Service stopped.' } else { Set-Status 'The service was not running.' }
})
$ui.SvcLoadBtn.Add_Click({
    $row = Get-ServiceRow
    if (-not $row -or -not (Test-RowRunning $row)) { Set-Status 'Start the service first.'; return }
    Request-Load $row
    Set-Status "Loading $($row.Model)..."
})
$ui.SvcUnloadBtn.Add_Click({
    $row = Get-ServiceRow
    if (-not $row -or -not (Test-RowRunning $row)) { Set-Status 'The service is not running.'; return }
    $code = Request-Unload $row
    Set-Status $(switch ($code) { 200 { "Unloaded $($row.Model); the next request loads it again." }
        409 { 'Busy: a request is running. Try again when it has finished.' } default { "Unload failed (HTTP $code)." } })
})
$ui.SvcLogBtn.Add_Click({
    if (Test-Path -LiteralPath $ServiceLog) { Start-Process notepad.exe -ArgumentList "`"$ServiceLog`"" } else { Set-Status 'No service log yet.' }
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1000)
$timer.Add_Tick({
    try {
        Update-Health
        if ($script:clinePending) {
            $row = $script:clinePending.Row
            Request-LoadIfIdle $row
            if (Test-RowReady $row) {
                $script:clinePending = $null
                Start-Cline $row
            } elseif (((Get-Date) - $script:clinePending.T0).TotalMinutes -gt $LoadTimeoutMinutes) {
                $script:clinePending = $null
                Set-Status "$($row.Model) did not load in time; Cline was not opened."
            }
        }
        Invoke-BenchStep
        $script:svcTick++
        if ($script:svcTick % 5 -eq 0 -and $ui.Tabs.SelectedItem -eq $ui.ServiceTab) { Update-ServiceStatus }
    } catch {
        Set-Status "Error: $($_.Exception.Message)"
    }
})

$window.Add_Closing({
    param($sender, $e)
    if ($script:job) {
        $answer = [System.Windows.MessageBox]::Show('A benchmark is running. Cancel it and close?', 'Strata', 'YesNo')
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        Stop-Bench
    }
    $timer.Stop()
    $sel = @(Get-SelectedConfigs)
    $out = [ordered]@{
        StrataRoot   = Get-Root
        ClineScript  = Clean-Path $ui.ClineScriptBox.Text
        ClineFolder  = Clean-Path $ui.FolderBox.Text
        Thinking     = [string]$ui.ThinkingBox.SelectedItem
        Context      = $(if ($ui.CtxBox.Text -eq '(config)') { '' } else { $ui.CtxBox.Text })
        ExtraArgs    = $ui.ExtraBox.Text
        VramReserve  = $ui.VramBox.Text
        FitMaxTokens = [bool]$ui.FitChk.IsChecked
        ReservePercent = [string]$ui.ReserveBox.SelectedItem
        OpenWeb      = [bool]$ui.OpenWebChk.IsChecked
        Minimized    = [bool]$ui.MinChk.IsChecked
        UnloadOllama = [bool]$ui.OllamaChk.IsChecked
        Runs         = [string]$ui.RunsBox.SelectedItem
        Clients      = [string]$ui.ClientsBox.SelectedItem
        Long         = [bool]$ui.LongChk.IsChecked
        Think        = [bool]$ui.ThinkChk.IsChecked
        StopAfter    = [bool]$ui.StopAfterChk.IsChecked
        LastConfig   = $(if ($sel.Count -gt 0) { $sel[0].Path } else { '' })
        DataFolder   = Clean-Path $ui.DataBox.Text
        FitOnly      = [bool]$ui.FitOnlyChk.IsChecked
        ServiceConfig = $(if ($ui.SvcModelBox.SelectedItem) { Join-Path (Get-Root) $ui.SvcModelBox.SelectedItem } else { '' })
        ServiceIdle  = $ui.SvcIdleBox.Text
    }
    try { [pscustomobject]$out | ConvertTo-Json | Set-Content -LiteralPath $SettingsPath -Encoding utf8 } catch {}
})

Read-Configs
Update-CtxHint
Update-ServicePicker
Read-Results
Update-Health
$timer.Start()
[void]$window.ShowDialog()
