# Strata launcher and benchmark GUI. Finds the model configs (strata-*.json) of a Strata
# folder, starts / stops their servers, runs tools\strata_bench.py against one or several
# of them, lists the results, and opens Cline on a running server.
param(
    [string]$StrataRoot,
    # -Service: run one config's server on demand, hidden (the Service tab's scheduled task starts this).
    [switch]$Service,
    [string]$Config,
    [int]$Port = 8080,
    [int]$IdleSeconds = 900,
    # -Service -Hibernate: this runner unloads the idle model itself, saving the session first.
    [switch]$Hibernate,
    [string]$SessionName
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
    # -Hibernate: the server's own --idle-unload would drop the conversation, so this runner watches
    # /status and, after $IdleSeconds without a request, saves the session file and then unloads.
    $idleArg = if ($Hibernate) { '' } else { " --idle-unload $IdleSeconds" }
    $serverArgs = (QPath $server) + ' --engine strata --config ' + (QPath $Config) + " --port $Port --lazy$idleArg"
    $proc = Start-Process -FilePath $py -ArgumentList $serverArgs -WorkingDirectory $StrataRoot -WindowStyle Hidden `
        -RedirectStandardOutput $ServiceLog -RedirectStandardError $ServiceErrLog -PassThru
    if (-not $Hibernate) { $proc.WaitForExit(); exit $proc.ExitCode }
    $hlog = Join-Path $PSScriptRoot 'strata-service.hibernate.log'
    $say = { param($m) Add-Content -LiteralPath $hlog -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) }
    & $say "watching http://127.0.0.1:$Port; unload after $IdleSeconds s idle, saving $SessionName first"
    $base = "http://127.0.0.1:$Port"
    $last = Get-Date
    $seen = ''
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 15
        try {
            $h = Invoke-RestMethod "$base/health" -TimeoutSec 5
            $st = Invoke-RestMethod "$base/status" -TimeoutSec 5
        } catch { continue }
        # Activity: a request running or queued, or the last request's counters moved since the last look.
        $mark = "$($st.prompt_tokens)|$($st.generated)|$($st.phase)"
        if (-not $h.loaded -or $st.busy -or $st.queued -or $mark -ne $seen) { $last = Get-Date; $seen = $mark; continue }
        if (((Get-Date) - $last).TotalSeconds -lt $IdleSeconds) { continue }
        try {
            $r = Invoke-RestMethod -Method Post "$base/slots/0?action=save" -ContentType 'application/json' `
                -Body (@{ filename = $SessionName } | ConvertTo-Json -Compress) -TimeoutSec 900
            & $say "saved $($r.n_saved) tokens ($([int]($r.n_written / 1MB)) MiB) in $($r.timings.save_ms) ms"
        } catch { & $say "save failed, unloading anyway: $($_.Exception.Message)" }
        try {
            $u = Invoke-RestMethod -Method Post "$base/unload" -ContentType 'application/json' -Body '{}' -TimeoutSec 120
            & $say "unload: $($u.status)"
        } catch { & $say "unload failed: $($_.Exception.Message)" }
        $last = Get-Date
    }
    & $say "server exited ($($proc.ExitCode))"
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
    ResumeFirst   = $false
    SvcHibernate  = $false
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
          <ScrollViewer VerticalScrollBarVisibility="Auto">
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
            <TextBlock Text="Sessions: the conversation the engine holds, saved to disk and restored in seconds instead of read again" FontWeight="SemiBold" Margin="0,0,0,8"/>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="110"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="Session file" Style="{StaticResource Label}"/>
              <ComboBox Grid.Column="1" x:Name="SessionBox" IsEditable="True"
                        ToolTip="A file in the config's session folder (slot_save_path). Type a new name to save under it."/>
              <WrapPanel Grid.Column="2" Margin="8,0,0,0">
                <Button x:Name="SessSaveBtn" Content="Save"/>
                <Button x:Name="SessRestoreBtn" Content="Restore"/>
                <Button x:Name="SessDeleteBtn" Content="Delete"/>
                <Button x:Name="SessFolderBtn" Content="Folder" Margin="0"/>
              </WrapPanel>
            </Grid>
            <WrapPanel Margin="110,0,0,0">
              <Button x:Name="HibernateBtn" Content="Hibernate" FontWeight="SemiBold"
                      ToolTip="Save the conversation as &lt;config&gt;-latest.bin, then stop the server."/>
              <Button x:Name="ResumeBtn" Content="Resume" FontWeight="SemiBold"
                      ToolTip="Start the server (or load the model), then restore &lt;config&gt;-latest.bin."/>
            </WrapPanel>
            <TextBlock x:Name="SessionHint" Style="{StaticResource Hint}"/>

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
            <CheckBox x:Name="ResumeChk" Margin="110,6,0,0" Content="Resume the latest session first (when the model has one)"/>
            <TextBlock Style="{StaticResource Hint}" Text="Starts the selected server if it is not running, waits until the model is loaded, then opens Cline in the folder pointed at that server."/>
          </StackPanel>
          </ScrollViewer>
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
            <CheckBox x:Name="SvcLogonChk" Content="Start at Windows logon" Margin="130,0,0,6"/>
            <CheckBox x:Name="SvcHibernateChk" Margin="130,0,0,12"
                      Content="Save the conversation before unloading (needs a session folder; Resume or Open Cline brings it back)"/>
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

        <TabItem Header="  Config  " x:Name="ConfigTab">
          <DockPanel Margin="8">
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
              <WrapPanel DockPanel.Dock="Right">
                <Button x:Name="CfgSaveBtn" Content="Save" FontWeight="SemiBold"/>
                <Button x:Name="CfgRevertBtn" Content="Revert"/>
                <Button x:Name="CfgSaveAsBtn" Content="Save as new..."/>
                <Button x:Name="CfgFileBtn" Content="Open file"/>
                <Button x:Name="CfgFolderBtn" Content="Open folder" Margin="0"/>
              </WrapPanel>
              <TextBlock x:Name="CfgTitle" VerticalAlignment="Center" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
            <TextBlock DockPanel.Dock="Bottom" x:Name="CfgChanges" TextWrapping="Wrap" Margin="0,6,0,0" MaxHeight="60" Foreground="#FF444444"/>
            <TabControl x:Name="CfgTabs">
              <TabItem Header="Model and server">
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="CfgServerPanel" Margin="6"/></ScrollViewer>
              </TabItem>
              <TabItem Header="Engine">
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="CfgEnginePanel" Margin="6"/></ScrollViewer>
              </TabItem>
              <TabItem Header="Files">
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="CfgFilesPanel" Margin="6"/></ScrollViewer>
              </TabItem>
              <TabItem Header="Other arguments">
                <DockPanel Margin="6">
                  <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                    <WrapPanel DockPanel.Dock="Right">
                      <Button x:Name="CfgArgAddBtn" Content="Add"/>
                      <Button x:Name="CfgArgDelBtn" Content="Remove" Margin="0"/>
                    </WrapPanel>
                    <TextBlock TextWrapping="Wrap" VerticalAlignment="Center" Foreground="#FF444444"
                               Text="Engine arguments without their own control. Leave Value empty for a switch (a flag that takes no value). The engine's --help lists them all."/>
                  </DockPanel>
                  <DataGrid x:Name="CfgArgsGrid" AutoGenerateColumns="False" CanUserAddRows="False" HeadersVisibility="Column"
                            SelectionMode="Single" GridLinesVisibility="Horizontal">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="Flag" Width="240" Binding="{Binding Flag, UpdateSourceTrigger=PropertyChanged}"/>
                      <DataGridTextColumn Header="Value" Width="*" Binding="{Binding Value, UpdateSourceTrigger=PropertyChanged}"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </DockPanel>
              </TabItem>
              <TabItem Header="JSON">
                <DockPanel Margin="6">
                  <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                    <Button x:Name="CfgJsonApplyBtn" DockPanel.Dock="Right" Content="Load this into the form" Margin="0"/>
                    <TextBlock VerticalAlignment="Center" TextWrapping="Wrap" Foreground="#FF444444"
                               Text="The config as Save would write it. Edit it here for anything the form does not cover, then load it into the form."/>
                  </DockPanel>
                  <TextBox x:Name="CfgJson" Height="Auto" VerticalContentAlignment="Top" FontFamily="Consolas" FontSize="12"
                           AcceptsReturn="True" AcceptsTab="True" TextWrapping="NoWrap"
                           VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
                </DockPanel>
              </TabItem>
            </TabControl>
          </DockPanel>
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

function Get-ServerLauncher([int]$ProcessId) {
    # The outermost process of a Strata server's launch chain above $ProcessId: the venv's python.exe
    # starts the real interpreter as a child, and a cmd.exe (run-*.bat, this GUI's own launch line)
    # waits around both with "if errorlevel 1 pause". Killing only the listener leaves that window
    # at "Press any key", so climb while the parent is part of the same launch.
    $procs = @{}
    foreach ($w in @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='cmd.exe'" -ErrorAction SilentlyContinue)) { $procs[[int]$w.ProcessId] = $w }
    $id = $ProcessId
    for ($i = 0; $i -lt 4; $i++) {
        $me = $procs[$id]
        if (-not $me) { break }
        $parent = $procs[[int]$me.ParentProcessId]
        if (-not $parent -or $parent.CommandLine -notmatch 'server\.py|run-[\w\.\-]+\.bat') { break }
        $id = [int]$parent.ProcessId
    }
    return $id
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
    $ids += @(Get-PortListeners $Row.Port | ForEach-Object { Get-ServerLauncher $_ })
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
    $hibernate = [bool]$ui.SvcHibernateChk.IsChecked
    if ($hibernate -and -not (Get-SessionDir $row)) {
        [System.Windows.MessageBox]::Show("Saving before unloading needs a session folder: set slot_save_path for $($row.File) in Config > Files first.", 'Strata') | Out-Null
        return
    }
    if ($hibernate) { $taskArgs += " -Hibernate -SessionName `"$(Get-LatestSessionName $row)`"" }
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $taskArgs -WorkingDirectory (Get-Root)
    $settingsSet = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $params = @{ TaskName = $ServiceTask; Action = $action; Settings = $settingsSet; Principal = $principal; Force = $true
                 Description = "Strata $($row.Model) on demand (port $($row.Port), unloads after $minutes min idle$(if ($hibernate) { ', saving the session first' })). Managed by strata-gui.ps1." }
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

# ------------------------------------------------------------------------------------ sessions
# Strata's session files (POST /slots/0?action=save|restore, on when the config has slot_save_path):
# the engine's state for the conversation it holds - KV cache, recurrent state, the deepest checkpoint -
# written to disk and read back, also into a freshly started engine. A file only restores into the same
# engine version with the same context, KV and rope settings (the engine checks and refuses otherwise),
# and a client still sends its messages: a matching conversation then continues from the restored state.
$script:slotOp = $null
$script:resumePending = $null

function Get-SessionDir($Row) {
    if (-not $Row) { return $null }
    $d = [string]$Row.Cfg.slot_save_path
    if (-not $d) { return $null }
    if (-not [IO.Path]::IsPathRooted($d)) {   # the server resolves it against the config's cwd
        $cwd = if ($Row.Cfg.cwd) { [string]$Row.Cfg.cwd } else { Get-Root }
        $d = Join-Path $cwd $d
    }
    return $d
}

function Get-LatestSessionName($Row) { [IO.Path]::GetFileNameWithoutExtension($Row.File) + '-latest.bin' }

function Test-SessionName([string]$Name) {
    # The engine wants one plain file name: no path, drive, stream, device name, leading dot or trailing dot/space.
    return ($Name -match '^[A-Za-z0-9_][\w\.\-]*$' -and -not $Name.EndsWith('.') -and
            $Name -notmatch '^(CON|PRN|AUX|NUL|COM\d|LPT\d)(\.|$)')
}

function Update-SessionList([switch]$KeepText) {
    $row = @(Get-SelectedConfigs) | Select-Object -First 1
    $dir = Get-SessionDir $row
    $text = $ui.SessionBox.Text
    $ui.SessionBox.Items.Clear()
    foreach ($b in @($ui.SessSaveBtn, $ui.SessRestoreBtn, $ui.SessDeleteBtn, $ui.SessFolderBtn, $ui.HibernateBtn, $ui.ResumeBtn)) { $b.IsEnabled = [bool]$dir }
    if (-not $row) { $ui.SessionHint.Text = ''; return }
    if (-not $dir) {
        $ui.SessionHint.Text = "Session files are off for $($row.File): set a session folder (slot_save_path) in Config > Files, then restart the server."
        $ui.SessionBox.Text = ''
        return
    }
    $files = @()
    if (Test-Path -LiteralPath $dir) {
        $files = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object LastWriteTime -Descending)
    }
    foreach ($f in $files) { [void]$ui.SessionBox.Items.Add($f.Name) }
    $ui.SessionBox.Text = $(if ($KeepText -and $text) { $text } else { Get-LatestSessionName $row })
    Update-SessionHint
}

function Update-SessionHint {
    $row = @(Get-SelectedConfigs) | Select-Object -First 1
    $dir = Get-SessionDir $row
    if (-not $dir) { return }
    $name = $ui.SessionBox.Text.Trim()
    $all = if (Test-Path -LiteralPath $dir) { @(Get-ChildItem -LiteralPath $dir -File | Where-Object { -not $_.Name.StartsWith('.') }) } else { @() }
    $total = ($all | Measure-Object Length -Sum).Sum
    $hint = "Folder $dir`: $($all.Count) file(s), {0:n1} GB." -f ($total / 1GB)
    $f = $all | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($f) { $hint += "  $name`: {0:n0} MiB, saved {1:g}." -f ($f.Length / 1MB), $f.LastWriteTime }
    elseif ($name -and -not (Test-SessionName $name)) { $hint += "  '$name' is not a plain file name (letters, digits, _ . - only)." }
    elseif ($name) { $hint += "  $name does not exist yet: Save creates it." }
    $hint += '  A file restores only into the same engine version with the same context, KV and rope settings; ~24 KB per token.'
    $ui.SessionHint.Text = $hint
}

function Start-SlotAction($Row, [string]$Action, [string]$Name, [string]$Then) {
    # POST /slots/0?action=...; runs in the background, Update-SlotOp (the timer) finishes it.
    if ($script:slotOp) { Set-Status 'A session save or restore is still running.'; return }
    if (-not (Get-SessionDir $Row)) { Set-Status "Session files are off for $($Row.File): set a session folder in Config > Files."; return }
    if (-not (Test-SessionName $Name)) { Set-Status "'$Name' is not a plain file name (letters, digits, _ . - only)."; return }
    if (-not (Test-RowReady $Row)) { Set-Status "$($Row.Model) is not loaded: nothing to $Action."; return }
    $body = New-Object System.Net.Http.StringContent((@{ filename = $Name } | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, 'application/json')
    $script:slotOp = @{ Row = $Row; Action = $Action; Name = $Name; Then = $Then; T0 = Get-Date
                        Task = $script:httpLong.PostAsync("http://127.0.0.1:$($Row.Port)/slots/0?action=$Action", $body) }
    Set-Status ("{0} session {1}..." -f $(if ($Action -eq 'save') { 'Saving' } else { 'Restoring' }), $Name)
}

function Update-SlotOp {
    $op = $script:slotOp
    if (-not $op) { return }
    $verb = if ($op.Action -eq 'save') { 'Saving' } else { 'Restoring' }
    if (-not $op.Task.IsCompleted) { Set-Status ('{0} session {1}... ({2:n0} s)' -f $verb, $op.Name, ((Get-Date) - $op.T0).TotalSeconds); return }
    $script:slotOp = $null
    $ok = $false
    if ($op.Task.Status -ne 'RanToCompletion') {
        $msg = "$verb $($op.Name) failed: $($op.Task.Exception.InnerException.Message)"
    } else {
        $resp = $op.Task.Result
        $code = [int]$resp.StatusCode
        $j = $null
        try { $j = $resp.Content.ReadAsStringAsync().Result | ConvertFrom-Json } catch {}
        if ($code -eq 200 -and $j) {
            $ok = $true
            $msg = if ($op.Action -eq 'save') {
                'Saved {0:n0} tokens ({1:n0} MiB) to {2} in {3:n2} s.' -f $j.n_saved, ($j.n_written / 1MB), $op.Name, ($j.timings.save_ms / 1000)
            } else {
                'Restored {0:n0} tokens ({1:n0} MiB) from {2} in {3:n2} s; a client that sends the same conversation continues from there.' -f $j.n_restored, ($j.n_read / 1MB), $op.Name, ($j.timings.restore_ms / 1000)
            }
        } else {
            $why = if ($j -and $j.error) { $j.error.message } else { "HTTP $code" }
            $msg = "$verb $($op.Name) failed (HTTP $code): $why"
        }
    }
    switch ($op.Then) {
        'stop' {
            if ($ok) { [void](Stop-Row $op.Row); $msg += " Stopped $($op.Row.Model)." }
            else { $msg += ' The server was left running so the conversation is not lost.' }
        }
        'cline' { Start-Cline $op.Row; if (-not $ok) { $msg += ' Cline opened anyway (it reads the conversation from the start).' } }
    }
    Set-Status $msg
    Update-SessionList -KeepText
}

function Start-Resume($Row, [switch]$Cline) {
    # Start the server or load the model as needed, then restore <config>-latest.bin (and open Cline).
    $name = Get-LatestSessionName $Row
    $dir = Get-SessionDir $Row
    if (-not $dir -or -not (Test-Path -LiteralPath (Join-Path $dir $name))) { Set-Status "No $name to resume for $($Row.Model)."; return $false }
    if (Test-RowReady $Row) { Start-SlotAction $Row 'restore' $name $(if ($Cline) { 'cline' } else { '' }); return $true }
    $h = $script:health[$Row.Port]
    if ($h -and $h.Up -and $h.Model -eq $Row.Model) { Request-Load $Row }
    elseif (-not (Start-Server $Row)) { return $false }
    $script:resumePending = @{ Row = $Row; Name = $name; Cline = [bool]$Cline; T0 = Get-Date }
    Set-Status "Resuming $($Row.Model): $name is restored once the model has loaded..."
    return $true
}

function Update-ResumePending {
    $rp = $script:resumePending
    if (-not $rp) { return }
    Request-LoadIfIdle $rp.Row
    if (Test-RowReady $rp.Row) {
        $script:resumePending = $null
        Start-SlotAction $rp.Row 'restore' $rp.Name $(if ($rp.Cline) { 'cline' } else { '' })
    } elseif (((Get-Date) - $rp.T0).TotalMinutes -gt $LoadTimeoutMinutes) {
        $script:resumePending = $null
        Set-Status "$($rp.Row.Model) did not load in time; nothing was restored."
    }
}

# ------------------------------------------------------------------------------------ files and logs
function Open-External([string]$Path) {
    # The file's default app. Notepad is not a safe fallback: Windows 11 can have its Store stub
    # without the app behind it ("The application cannot be started"), so say what failed instead.
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { Set-Status "Not found: $Path"; return }
    try { Start-Process -FilePath $Path -ErrorAction Stop }
    catch { Set-Status "Windows could not open $Path ($($_.Exception.Message)). Set a default app for $([IO.Path]::GetExtension($Path)) files." }
}

function Show-TextWindow([string]$Path, [string]$Title) {
    # A read-only viewer for logs and reports, so they open whatever app Windows has for .log/.md.
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { Set-Status "Not found: $Path"; return }
    [xml]$x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="640" Width="980" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="13">
  <DockPanel Margin="10">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <WrapPanel DockPanel.Dock="Right">
        <CheckBox x:Name="Follow" Content="Follow" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <Button x:Name="Reload" Content="Reload" Padding="12,4" Margin="0,0,8,0"/>
        <Button x:Name="Ext" Content="Open in its app" Padding="12,4"/>
      </WrapPanel>
      <TextBlock x:Name="PathText" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
    <TextBox x:Name="Body" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
  </DockPanel>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $w.Owner = $window
    $w.Title = $Title
    $body = $w.FindName('Body')
    $w.FindName('PathText').Text = $Path
    $load = {
        # The last 2 MB at most: engine logs grow without bound.
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $skip = [Math]::Max(0L, $fs.Length - 2MB)
            $null = $fs.Seek($skip, 'Begin')
            $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd()
        } finally { $fs.Dispose() }
        if ($skip -gt 0) { $text = "[... the first $([int]($skip / 1MB)) MB are not shown ...]`r`n" + $text }
        $body.Text = $text -replace "(?<!`r)`n", "`r`n"
        $body.ScrollToEnd()
    }.GetNewClosure()
    & $load
    $w.FindName('Reload').Add_Click($load)
    $ext = $w.FindName('Ext'); $ext.Tag = $Path
    $ext.Add_Click({ param($s, $a) Open-External $s.Tag })
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(2)
    $follow = $w.FindName('Follow')
    $t.Add_Tick({ if ($follow.IsChecked) { & $load } }.GetNewClosure())
    $t.Start()
    $w.Add_Closed({ $t.Stop() }.GetNewClosure())
    $w.Show()
}

# ------------------------------------------------------------------------------------ config editor
# Server settings come from Strata's own serve\runconfig.py (the list its web page edits, with the
# same checks), saving goes through its runconfig.save (the earlier file kept as <name>.bak, the new
# one moved into place whole). Engine flags with a control are curated from `strata.exe --help`;
# every other argument stays as it is in the Other arguments table.
$ConfigPy = @'
import json, sys
sys.path.insert(0, sys.argv[2])
import runconfig as R
if sys.argv[1] == "schema":
    out = []
    for key, kind, help_ in R.EDITABLE:
        k = kind[0] if isinstance(kind, tuple) else kind
        if k == "arg":
            continue                      # engine flags are edited on the Engine tab
        out.append({"key": key, "kind": kind[1] if k == "sampling" else k,
                    "choices": kind[1] if k == "enum" else None, "help": help_})
    print(json.dumps(out))
elif sys.argv[1] == "save":
    cfg = json.loads(open(sys.argv[4], encoding="utf-8-sig").read())
    print(R.save(sys.argv[3], cfg))
'@

# (flag, kind, choices or range, help). Kinds: int / num (with min..max), enum, auto (a word or a whole number),
# switch (no value), ctx (the context, which also drives rope scaling).
$EngineFlags = @(
    @{ Flag = '--max-context'; Kind = 'ctx'; Help = 'Tokens of context the engine holds. Up to the trained 262,144 no rope scaling is needed; past it set rope scaling below (yarn; experimental in Strata). Each token costs ~13.7 KB of KV cache at int8.' }
    @{ Flag = '--rope-scaling'; Kind = 'enum'; Choices = @('none', 'linear', 'yarn'); Help = 'Only for a context past 262,144: yarn is what Strata recommends. Fixed for the run; within the trained range it changes the model slightly at every position.' }
    @{ Flag = '--rope-scale'; Kind = 'num'; Min = 1; Max = 64; Help = 'The extension factor: context / 262,144 (1.5 at 384K, 2 at 512K, 4 at 1M). Set automatically with the context.' }
    @{ Flag = '--kv'; Kind = 'enum'; Choices = @('fp16', 'int8', 'k8v4', 'q4_0'); Help = 'KV cache format. int8: setup''s default. k8v4: 23% less memory, close to int8. q4_0: half of int8, measurably less precise on long documents.' }
    @{ Flag = '--kv-resident'; Kind = 'int'; Min = 0; Help = 'KV streaming: cells of each attention layer kept in VRAM (at least 20480; 0 = all in VRAM). The rest lives in pinned RAM and the freed VRAM holds more experts. Setup writes 32768 from 64K up.' }
    @{ Flag = '--kv-grow'; Kind = 'switch'; Help = 'Allocate KV VRAM only as the context is reached, lending the rest to the expert cache (one GPU, needs --expert-profile).' }
    @{ Flag = '--vram-reserve-mib'; Kind = 'int'; Min = 0; Help = 'GPU memory (MiB) the engine leaves free for other programs (engine default 700). Raise it when the engine log says VRAM is LOW.' }
    @{ Flag = '--expert-cache'; Kind = 'auto'; Choices = @('auto'); Help = 'Expert blobs kept in VRAM: auto (as many as fit) or a number.' }
    @{ Flag = '--resident-budget-gib'; Kind = 'num'; Min = 1; Help = 'Unsloth / NVFP4 files: GiB of experts kept in RAM; the rest is read from the SSD.' }
    @{ Flag = '--prefill'; Kind = 'auto'; Choices = @('auto', 'auto:16384', 'auto:32768'); Help = 'Prompt reading in chunks of this many tokens: auto (the largest up to 8192 that fits), auto:16384 / auto:32768 to allow bigger, or a number.' }
    @{ Flag = '--spec'; Kind = 'int'; Min = 1; Max = 8; Help = 'Speculative decoding: tokens the draft layer proposes per check (setup writes 4).' }
    @{ Flag = '--spec-min-p'; Kind = 'num'; Min = 0; Max = 1; Help = 'How sure the draft layer must be to extend a window (setup writes 0.5).' }
    @{ Flag = '--batch'; Kind = 'int'; Min = 2; Max = 8; Help = 'Serve up to N requests at once (each slot takes VRAM like the main session). Empty: one at a time.' }
    @{ Flag = '--batch-mtp'; Kind = 'switch'; Help = 'With --batch: each slot also verifies a draft (needs --spec and --mtp).' }
    @{ Flag = '--prompt-cache'; Kind = 'int'; Min = 0; Help = 'Conversation checkpoints kept between requests (default 6, ~118 MB of RAM each; 0 = re-read every prompt).' }
    @{ Flag = '--conversation-cache-mib'; Kind = 'int'; Min = 0; Help = 'RAM for parked conversations, so switching between chats does not re-read them (default 0 = off).' }
    @{ Flag = '--pool-workers'; Kind = 'int'; Min = 0; Help = 'CPU expert threads (default 0 = every physical core but one).' }
    @{ Flag = '--pool-affinity'; Kind = 'enum'; Choices = @('all', 'auto', 'p-cores', 'measure'); Help = 'Where the CPU expert threads run: all (one per physical core), auto / p-cores for hybrid Intel CPUs, measure (time both at start).' }
    @{ Flag = '--host-core'; Kind = 'enum'; Choices = @('first', 'last', 'sibling'); Help = 'Core of the engine''s host thread; last or sibling keeps it away from the GPU interrupts on core 0.' }
)
$FileFlags = @(
    @{ Flag = '--pack'; Dir = $true; Help = 'The pack folder (experts and tokenizer).' }
    @{ Flag = '--native'; Help = 'The model''s first GGUF shard.' }
    @{ Flag = '--ple-gguf'; Help = 'The shard with the n-gram (PLE) table. Without it the model silently computes something else.' }
    @{ Flag = '--embd-gguf'; Help = 'The token embedding GGUF (NVFP4 packs).' }
    @{ Flag = '--mtp'; Dir = $true; Help = 'The draft layer folder for speculative decoding.' }
    @{ Flag = '--expert-profile'; Help = 'Which experts start in VRAM (setup''s profile).' }
)
$TopFiles = @(
    @{ Key = 'exe'; Help = 'The engine executable.' }
    @{ Key = 'tokenizer'; Dir = $true; Help = 'The tokenizer folder.' }
    @{ Key = 'cwd'; Dir = $true; Help = 'The engine''s working folder.' }
    @{ Key = 'log'; NoCheck = $true; Help = 'The engine log (created when the engine starts).' }
    @{ Key = 'slot_save_path'; Dir = $true; NoCheck = $true; Help = 'Session files (Launch > Sessions): where saved conversations go. Created when missing; ~24 KB per token of conversation, never deleted by Strata - pick a drive with room. Empty: sessions off.' }
)
$script:cfgSchema = $null
$script:cfgEdit = $null
$script:cfgLoading = $false
Add-Type -TypeDefinition 'public class StrataCfgArg { public string Flag { get; set; } public string Value { get; set; } }'
$script:cfgArgs = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:cfgPending = $null
$ui.CfgArgsGrid.ItemsSource = $script:cfgArgs

function Get-ConfigSchema {
    if ($script:cfgSchema) { return $script:cfgSchema }
    $py = Get-Python
    if ($py) {
        if (-not (Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Path $TempDir | Out-Null }
        $file = Join-Path $TempDir 'runconfig-gui.py'
        Set-Content -LiteralPath $file -Value $ConfigPy -Encoding ascii
        try { $script:cfgSchema = @(& $py -I $file schema (Join-Path (Get-Root) 'serve') 2>$null | Out-String | ConvertFrom-Json) } catch {}
    }
    if (-not $script:cfgSchema) {
        # An older Strata without runconfig.py: the few keys every version reads.
        $script:cfgSchema = @(
            [pscustomobject]@{ key = 'fit_max_tokens'; kind = 'bool'; choices = $null; help = 'Shorten a max_tokens that does not fit the context instead of answering 400' }
            [pscustomobject]@{ key = 'idle_unload_s'; kind = 'num>=0'; choices = $null; help = 'Unload the model after this many seconds without requests' }
            [pscustomobject]@{ key = 'lazy_load'; kind = 'bool'; choices = $null; help = 'Start without loading the model; the first request loads it' }
        )
    }
    return $script:cfgSchema
}

function Split-ArgEntries($ArgList) {
    # args as [flag, value-or-$null] pairs: a token after a flag is its value unless it is a flag itself.
    $out = New-Object System.Collections.Generic.List[object]
    $a = @($ArgList | ForEach-Object { [string]$_ })
    for ($i = 0; $i -lt $a.Count; $i++) {
        $value = $null
        if ($i + 1 -lt $a.Count -and -not $a[$i + 1].StartsWith('--')) { $value = $a[$i + 1]; $i++ }
        $out.Add([pscustomobject]@{ Flag = $a[$i - [int]($null -ne $value)]; Value = $value })
    }
    return , $out
}

function Get-JsonValue($Obj, [string]$Key) {
    # "sampling.temperature" reads a nested key.
    $parts = $Key.Split('.')
    $o = $Obj
    foreach ($p in $parts) {
        if ($null -eq $o -or -not $o.PSObject.Properties[$p]) { return $null }
        $o = $o.$p
    }
    return $o
}

function Set-JsonValue($Obj, [string]$Key, $Value) {
    # $null removes the key (and an emptied parent block).
    $parts = $Key.Split('.')
    if ($parts.Count -eq 2) {
        $parent = $Obj.PSObject.Properties[$parts[0]]
        if ($null -eq $Value) {
            if ($parent -and $parent.Value.PSObject.Properties[$parts[1]]) {
                $parent.Value.PSObject.Properties.Remove($parts[1])
                if (@($parent.Value.PSObject.Properties).Count -eq 0) { $Obj.PSObject.Properties.Remove($parts[0]) }
            }
            return
        }
        if (-not $parent) { $Obj | Add-Member -NotePropertyName $parts[0] -NotePropertyValue ([pscustomobject]@{}) }
        $Obj.($parts[0]) | Add-Member -NotePropertyName $parts[1] -NotePropertyValue $Value -Force
        return
    }
    if ($null -eq $Value) { $Obj.PSObject.Properties.Remove($Key); return }
    $Obj | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
}

function New-CfgRow([System.Windows.Controls.Panel]$Panel, [string]$Label, $Editor, [string]$Help, $Extra) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '0,0,0,8'
    foreach ($w in @(190, 260, 12)) { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; $g.ColumnDefinitions.Add($c) }
    $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = [System.Windows.GridLength]::new(1, 'Star'); $g.ColumnDefinitions.Add($c)
    $l = New-Object System.Windows.Controls.TextBlock
    $l.Text = $Label; $l.VerticalAlignment = 'Center'; $l.FontFamily = 'Consolas'; $l.TextTrimming = 'CharacterEllipsis'; $l.ToolTip = $Label
    [void]$g.Children.Add($l)
    if ($Extra) {
        $dp = New-Object System.Windows.Controls.DockPanel
        [System.Windows.Controls.DockPanel]::SetDock($Extra, 'Right')
        $Extra.Margin = '6,0,0,0'
        [void]$dp.Children.Add($Extra); [void]$dp.Children.Add($Editor)
        [System.Windows.Controls.Grid]::SetColumn($dp, 1); [void]$g.Children.Add($dp)
    } else {
        [System.Windows.Controls.Grid]::SetColumn($Editor, 1); [void]$g.Children.Add($Editor)
    }
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $Help; $h.TextWrapping = 'Wrap'; $h.Foreground = '#FF666666'; $h.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($h, 3); [void]$g.Children.Add($h)
    [void]$Panel.Children.Add($g)
}

function New-CfgHeader([System.Windows.Controls.Panel]$Panel, [string]$Text) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontWeight = 'SemiBold'; $t.Margin = '0,6,0,8'
    [void]$Panel.Children.Add($t)
}

function New-CfgEditor($Field) {
    # The control for one field; its Tag is the field, so one handler serves them all.
    switch ($Field.Kind) {
        { $_ -in 'bool', 'switch' } {
            $e = New-Object System.Windows.Controls.CheckBox
            $e.VerticalAlignment = 'Center'
            if ($Field.Kind -eq 'bool') { $e.IsThreeState = $true; $e.Content = '(dot = not set: the default)' }
            $e.Add_Click({ Update-CfgChanges })
        }
        { $_ -in 'enum', 'auto', 'ctx', 'host' } {
            $e = New-Object System.Windows.Controls.ComboBox
            $e.IsEditable = $_ -ne 'enum'
            $e.Height = 26
            [void]$e.Items.Add('')
            $items = if ($_ -eq 'ctx') { @('32768', '65536', '131072', '204800', '262144', '393216', '524288', '1048576') }
                elseif ($_ -eq 'host') { @('127.0.0.1', '0.0.0.0') } else { $Field.Choices }
            foreach ($c in $items) { [void]$e.Items.Add([string]$c) }
            $e.Add_SelectionChanged({
                param($s, $a)
                $script:cfgPending = $s.Tag
                $s.Dispatcher.BeginInvoke([action]{ if ($script:cfgPending.Kind -eq 'ctx') { Sync-RopeToContext $script:cfgPending }; Update-CfgChanges }) | Out-Null
            })
            $e.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.Controls.TextChangedEventHandler]{
                param($s, $a)
                if ($s.Tag.Kind -eq 'ctx') { Sync-RopeToContext $s.Tag }
                Update-CfgChanges
            })
        }
        default {
            $e = New-Object System.Windows.Controls.TextBox
            $e.Add_TextChanged({ Update-CfgChanges })
        }
    }
    $e.Tag = $Field
    [System.Windows.Automation.AutomationProperties]::SetName($e, $Field.Name)   # screen readers and UI tests
    $Field.Control = $e
    return $e
}

function Get-FieldText($Field) {
    # The control's value as text; $null = not set.
    $c = $Field.Control
    switch ($Field.Kind) {
        'bool' { if ($null -eq $c.IsChecked) { return $null }; return ([string][bool]$c.IsChecked).ToLower() }
        'switch' { if ($c.IsChecked) { return 'on' }; return $null }
        { $_ -in 'enum', 'auto', 'ctx', 'host' } { $t = [string]$c.Text; if ($c -is [System.Windows.Controls.ComboBox] -and -not $c.IsEditable) { $t = [string]$c.SelectedItem } }
        default { $t = [string]$c.Text }
    }
    $t = $t.Trim()
    if ($t -eq '') { return $null }
    return $t
}

function Set-FieldValue($Field, $Value) {
    $c = $Field.Control
    switch ($Field.Kind) {
        'bool' { $c.IsChecked = $(if ($null -eq $Value) { $null } else { [bool]$Value }) }
        'switch' { $c.IsChecked = [bool]$Value }
        'enum' {
            $v = if ($null -eq $Value) { '' } else { [string]$Value }
            if (-not $c.Items.Contains($v)) { [void]$c.Items.Add($v) }   # a value the list does not know is kept, not dropped
            $c.SelectedItem = $v
        }
        { $_ -in 'auto', 'ctx', 'host' } { $c.Text = $(if ($null -eq $Value) { '' } else { [string]$Value }) }
        'names' { $c.Text = $(if ($null -eq $Value) { '' } else { @($Value) -join ', ' }) }
        default { $c.Text = $(if ($null -eq $Value) { '' } else { [string]$Value }) }
    }
}

function Test-FieldText($Field, [string]$Text) {
    # -> the value to store (typed), or throws naming what is expected.
    $name = $Field.Name
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $num = {
        param($whole)
        $d = 0.0
        if (-not [double]::TryParse($Text, [Globalization.NumberStyles]::Float, $inv, [ref]$d) -or ($whole -and $d -ne [Math]::Floor($d))) {
            throw "${name}: expected a $(if ($whole) { 'whole ' })number, not '$Text'"
        }
        if ($null -ne $Field.Min -and $d -lt $Field.Min) { throw "${name}: at least $($Field.Min)" }
        if ($null -ne $Field.Max -and $d -gt $Field.Max) { throw "${name}: at most $($Field.Max)" }
        if ($whole) { return [int64]$d } else { return $d }
    }
    switch ($Field.Kind) {
        'bool' { return ($Text -eq 'true') }
        'switch' { return $true }
        'enum' { if ($Field.Choices -notcontains $Text -and $Text -ne $Field.Original) { throw "${name}: one of $($Field.Choices -join ', ')" }; return $Text }
        'auto' { if ($Field.Choices -contains $Text -or $Text -match '^\d+$') { return $Text }; throw "${name}: $($Field.Choices -join ', ') or a whole number" }
        'ctx' { if ($Text -notmatch '^\d+$' -or [int64]$Text -lt 2048) { throw "${name}: a number of tokens (at least 2048)" }; return $Text }
        'host' { return $Text }
        'names' { return @($Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        'text' { return $Text }
        'port' { $Field.Min = 1; $Field.Max = 65535; return (& $num $true) }
        'int' { return (& $num $true) }
        'int>=0' { $Field.Min = 0; return (& $num $true) }
        'num' { return (& $num $false) }
        'num>=0' { $Field.Min = 0; return (& $num $false) }
        '0<x<=1' { $v = & $num $false; if ($v -le 0 -or $v -gt 1) { throw "${name}: more than 0 and at most 1" }; return $v }
        '0<=x<=1' { $Field.Min = 0; $Field.Max = 1; return (& $num $false) }
        '1..64' { $Field.Min = 1; $Field.Max = 64; return (& $num $true) }
        default { return $Text }
    }
}

function Open-ConfigEditor($Row, [switch]$Force, $Override) {
    # Load $Row's config into the form (asking first when the form has unsaved changes). $Override:
    # fill the form from that config instead (the JSON tab) while changes still count against the file.
    if (-not $Row) { return }
    if ($script:cfgEdit -and -not $Force -and -not $Override) {
        if ($script:cfgEdit.Row.Path -eq $Row.Path) { return }
        if ($script:cfgEdit.Dirty) {
            $a = [System.Windows.MessageBox]::Show("Discard the unsaved changes to $($script:cfgEdit.Row.File)?", 'Strata', 'YesNo')
            if ($a -ne 'Yes') { return }
        }
    }
    try { $fileCfg = Get-Content -LiteralPath $Row.Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
        $ui.CfgTitle.Text = "$($Row.File): not valid JSON ($($_.Exception.Message)). Fix it in the JSON tab or another editor."
        $script:cfgEdit = $null
        return
    }
    $cfg = if ($Override) { $Override } else { $fileCfg }
    $script:cfgLoading = $true
    $fields = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($ui.CfgServerPanel, $ui.CfgEnginePanel, $ui.CfgFilesPanel)) { $p.Children.Clear() }

    New-CfgHeader $ui.CfgServerPanel 'Model and network'
    foreach ($d in @(
            @{ Name = 'model_name'; Kind = 'text'; Help = 'The model id the API reports and clients ask for. Cline, the benchmark and this GUI find the server by it.' }
            @{ Name = 'port'; Kind = 'port'; Help = 'The HTTP port (Strata''s default 8080). Two configs on one port cannot run together.' }
            @{ Name = 'host'; Kind = 'host'; Help = 'The address the server listens on. Empty or 127.0.0.1: this PC only. Anything else needs an API key (saving refuses without one).' }
            @{ Name = 'api_key'; Kind = 'text'; Help = 'Clients must send this key. Needed when host is not this PC only.' }
            @{ Name = 'gpu'; Kind = 'text'; Help = 'The GPU(s) to run on, as nvidia-smi numbers them (e.g. 0, or 0,1 for a layer split).' })) {
        $f = [pscustomobject]@{ Name = $d.Name; Key = $d.Name; Kind = $d.Kind; Choices = $null; Min = $null; Max = $null; Where = 'top'; Control = $null; Original = $null }
        New-CfgRow $ui.CfgServerPanel $d.Name (New-CfgEditor $f) $d.Help $null
        $fields.Add($f)
    }
    New-CfgHeader $ui.CfgServerPanel 'Server settings (the list Strata''s own Settings page edits)'
    foreach ($s in (Get-ConfigSchema)) {
        $kind = if ($s.kind -eq 'enum') { 'enum' } else { [string]$s.kind }
        $f = [pscustomobject]@{ Name = $s.key; Key = $s.key; Kind = $kind; Choices = @($s.choices); Min = $null; Max = $null; Where = 'top'; Control = $null; Original = $null }
        New-CfgRow $ui.CfgServerPanel $s.key (New-CfgEditor $f) $s.help $null
        $fields.Add($f)
    }

    New-CfgHeader $ui.CfgEnginePanel 'Engine options (args). Empty = not passed: the engine''s default.'
    foreach ($d in $EngineFlags) {
        $f = [pscustomobject]@{ Name = $d.Flag; Key = $d.Flag; Kind = $d.Kind; Choices = @($d.Choices); Min = $d.Min; Max = $d.Max; Where = 'arg'; Control = $null; Original = $null }
        New-CfgRow $ui.CfgEnginePanel $d.Flag (New-CfgEditor $f) $d.Help $null
        $fields.Add($f)
    }

    New-CfgHeader $ui.CfgFilesPanel 'Model files (a red mark: the path does not exist)'
    foreach ($d in @($TopFiles | ForEach-Object { $_ + @{ Where = 'top'; Name = $_.Key } }) + @($FileFlags | ForEach-Object { $_ + @{ Where = 'arg'; Name = $_.Flag; Key = $_.Flag } })) {
        $f = [pscustomobject]@{ Name = $d.Name; Key = $d.Key; Kind = 'path'; Choices = $null; Min = $null; Max = $null; Where = $d.Where
                                Dir = [bool]$d.Dir; NoCheck = [bool]$d.NoCheck; Control = $null; Original = $null; Mark = $null }
        $ed = New-CfgEditor $f
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Orientation = 'Horizontal'
        $mark = New-Object System.Windows.Controls.TextBlock
        $mark.Width = 16; $mark.VerticalAlignment = 'Center'; $mark.FontWeight = 'Bold'
        $f.Mark = $mark
        $b = New-Object System.Windows.Controls.Button
        $b.Content = '...'; $b.MinWidth = 30; $b.Padding = '6,0'; $b.Margin = '0'; $b.Tag = $f
        $b.Add_Click({
            param($s, $a)
            $fld = $s.Tag
            if ($fld.Dir) { $p = Select-Folder (Get-FieldText $fld) "Choose $($fld.Name)" }
            else {
                $dlg = New-Object System.Windows.Forms.OpenFileDialog
                $cur = Get-FieldText $fld
                if ($cur -and (Test-Path -LiteralPath (Split-Path $cur -Parent))) { $dlg.InitialDirectory = Split-Path $cur -Parent; $dlg.FileName = Split-Path $cur -Leaf }
                $p = if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $dlg.FileName } else { $null }
            }
            if ($p) { $fld.Control.Text = $p }
        })
        [void]$panel.Children.Add($mark); [void]$panel.Children.Add($b)
        New-CfgRow $ui.CfgFilesPanel $d.Name $ed $d.Help $panel
        $fields.Add($f)
    }

    # Values: top-level keys straight from the JSON; args split into flag/value pairs, the first of
    # each curated flag goes to its control and everything else to the Other arguments table.
    $entries = Split-ArgEntries $cfg.args
    $curated = @($fields | Where-Object { $_.Where -eq 'arg' } | ForEach-Object { $_.Key })
    $taken = @{}
    $script:cfgArgs.Clear()
    foreach ($e in $entries) {
        if ($curated -contains $e.Flag -and -not $taken.ContainsKey($e.Flag)) { $taken[$e.Flag] = $e; continue }
        $script:cfgArgs.Add((New-Object StrataCfgArg -Property @{ Flag = $e.Flag; Value = $e.Value }))
    }
    foreach ($f in $fields) {
        $v = if ($f.Where -eq 'top') { Get-JsonValue $cfg $f.Key }
            elseif ($taken.ContainsKey($f.Key)) { if ($f.Kind -eq 'switch') { $true } else { $taken[$f.Key].Value } }
            else { $null }
        Set-FieldValue $f $v
        $f.Original = Get-FieldText $f
    }
    $script:cfgEdit = @{ Row = $Row; Cfg = $fileCfg; Base = $cfg; Fields = $fields; Dirty = $false; OriginalJson = (Get-ConfigText $fileCfg) }
    $script:cfgLoading = $false
    $ui.CfgTitle.Text = "$($Row.File)  -  $($Row.Path)"
    Update-CfgChanges
}

function Get-ConfigText($Cfg) { ($Cfg | ConvertTo-Json -Depth 20) }

function Build-Config {
    # The config the form describes: a copy of the loaded one with every field and the table applied.
    # -> @{ Cfg; Errors }
    $ed = $script:cfgEdit
    $new = (Get-ConfigText $ed.Base) | ConvertFrom-Json
    $errors = New-Object System.Collections.Generic.List[string]
    $argOut = New-Object System.Collections.Generic.List[string]
    foreach ($f in $ed.Fields) {
        $t = Get-FieldText $f
        $v = $null
        if ($null -ne $t) { try { $v = Test-FieldText $f $t } catch { $errors.Add($_.Exception.Message); continue } }
        if ($f.Where -eq 'top') {
            if ($f.Key -eq 'gpu' -and $v -is [string] -and $v -match '^\d+$') { $v = [int]$v }
            if ($f.Kind -eq 'names' -and @($v).Count -eq 0) { $v = $null }
            Set-JsonValue $new $f.Key $v
        } elseif ($null -ne $v) {
            $argOut.Add($f.Key)
            if ($f.Kind -ne 'switch') { $argOut.Add($(if ($v -is [double]) { $v.ToString([Globalization.CultureInfo]::InvariantCulture) } else { [string]$v })) }
        }
    }
    foreach ($r in $script:cfgArgs) {
        $flag = ([string]$r.Flag).Trim()
        if (-not $flag) { continue }
        if (-not $flag.StartsWith('--')) { $errors.Add("Other arguments: '$flag' is not a flag (they start with --)"); continue }
        $argOut.Add($flag)
        $val = ([string]$r.Value).Trim()
        if ($val) { $argOut.Add($val) }
    }
    $new.args = $argOut.ToArray()
    # The same guards Strata keeps: no network exposure without a key, no lazy load with images.
    $hostV = [string]$new.host
    if ($hostV -and $hostV -notin @('127.0.0.1', 'localhost', '::1') -and -not $new.api_key) {
        $errors.Add("host $($hostV): reachable from other machines, so set an api_key first")
    }
    if ($new.lazy_load -eq $true -and $new.vision) { $errors.Add('lazy_load: lazy loading is text-only, and this model reads images ("vision")') }
    $ctx = Get-ArgValue $new.args '--max-context'
    if ($ctx -match '^\d+$' -and [int64]$ctx -gt $TrainedContext -and -not (Get-ArgValue $new.args '--rope-scaling')) {
        $errors.Add("--max-context $($ctx): past the trained 262,144, so set --rope-scaling (yarn)")
    }
    if (-not $new.model_name) { $errors.Add('model_name: required') }
    return @{ Cfg = $new; Errors = $errors }
}

function Get-ConfigDiff($Old, $New) {
    # Readable changes between two configs: top-level keys, then args flag by flag.
    $lines = New-Object System.Collections.Generic.List[string]
    $keys = @($Old.PSObject.Properties.Name) + @($New.PSObject.Properties.Name) | Where-Object { $_ -ne 'args' } | Select-Object -Unique
    foreach ($k in $keys) {
        $a = if ($Old.PSObject.Properties[$k]) { $Old.$k | ConvertTo-Json -Compress -Depth 10 } else { '(not set)' }
        $b = if ($New.PSObject.Properties[$k]) { $New.$k | ConvertTo-Json -Compress -Depth 10 } else { '(not set)' }
        if ($a -ne $b) { $lines.Add("$k`: $a -> $b") }
    }
    $mapOf = {
        param($list)
        $m = [ordered]@{}
        foreach ($e in (Split-ArgEntries $list)) {
            $v = if ($null -eq $e.Value) { '(on)' } else { $e.Value }
            if ($m.Contains($e.Flag)) { $m[$e.Flag] += " | $v" } else { $m[$e.Flag] = $v }
        }
        $m
    }
    $ma = & $mapOf $Old.args
    $mb = & $mapOf $New.args
    foreach ($f in @($ma.Keys) + @($mb.Keys) | Select-Object -Unique) {
        $a = if ($ma.Contains($f)) { $ma[$f] } else { '(not set)' }
        $b = if ($mb.Contains($f)) { $mb[$f] } else { '(not set)' }
        if ($a -ne $b) { $lines.Add("$f`: $a -> $b") }
    }
    return , $lines
}

function Update-CfgChanges {
    if ($script:cfgLoading -or -not $script:cfgEdit) { return }
    $r = Build-Config
    $diff = Get-ConfigDiff $script:cfgEdit.Cfg $r.Cfg
    $script:cfgEdit.Dirty = $diff.Count -gt 0
    foreach ($f in $script:cfgEdit.Fields) {
        if ($f.Mark) {
            $p = Get-FieldText $f
            $ok = $f.NoCheck -or -not $p -or (Test-Path -LiteralPath $p)
            $f.Mark.Text = $(if ($p -and -not $f.NoCheck) { if ($ok) { [char]0x2713 } else { [char]0x2717 } } else { '' })
            $f.Mark.Foreground = $(if ($ok) { '#FF2E7D32' } else { '#FFC62828' })
        }
    }
    $text = if ($r.Errors.Count) { 'Cannot save: ' + ($r.Errors -join ';  ') }
        elseif ($diff.Count) { "Unsaved changes ($($diff.Count)):  " + ($diff -join ';  ') }
        else { 'No changes.' }
    $ui.CfgChanges.Text = $text
    $ui.CfgChanges.Foreground = $(if ($r.Errors.Count) { '#FFC62828' } else { '#FF444444' })
    $ui.CfgSaveBtn.IsEnabled = $diff.Count -gt 0 -and $r.Errors.Count -eq 0
    if ($ui.CfgTabs.SelectedIndex -eq 4 -and -not $ui.CfgJson.IsKeyboardFocusWithin) { $ui.CfgJson.Text = Get-ConfigText $r.Cfg }
}

function Sync-RopeToContext($Field) {
    # Changing the context sets rope scaling the way Strata's setup does (Set-ContextArgs): nothing
    # inside the trained window, yarn with a covering factor past it. Both stay editable.
    if ($script:cfgLoading -or -not $script:cfgEdit) { return }
    $t = Get-FieldText $Field
    if ($t -notmatch '^\d+$') { return }
    $ctx = [int64]$t
    $scaling = $script:cfgEdit.Fields | Where-Object { $_.Key -eq '--rope-scaling' }
    $scale = $script:cfgEdit.Fields | Where-Object { $_.Key -eq '--rope-scale' }
    if ($ctx -le $TrainedContext) {
        Set-FieldValue $scaling $null; Set-FieldValue $scale $null
    } else {
        if (-not (Get-FieldText $scaling)) { Set-FieldValue $scaling 'yarn' }
        $need = Get-RopeScale $ctx
        $have = Get-FieldText $scale
        $d = 0.0
        if (-not $have -or -not [double]::TryParse($have, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -or $d -lt $need) {
            Set-FieldValue $scale $need.ToString([Globalization.CultureInfo]::InvariantCulture)
        }
    }
}

function Save-ConfigEditor {
    $ed = $script:cfgEdit
    if (-not $ed) { return }
    $r = Build-Config
    if ($r.Errors.Count) { [System.Windows.MessageBox]::Show(($r.Errors -join "`n"), 'Strata: cannot save') | Out-Null; return }
    $diff = Get-ConfigDiff $ed.Cfg $r.Cfg
    if ($diff.Count -eq 0) { Set-Status 'No changes to save.'; return }
    # Someone else (setup, Strata's Settings page) may have written the file since it was loaded.
    $onDisk = try { Get-ConfigText (Get-Content -LiteralPath $ed.Row.Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { '' }
    if ($onDisk -ne $ed.OriginalJson) {
        $a = [System.Windows.MessageBox]::Show("$($ed.Row.File) changed on disk since it was opened here. Overwrite those changes?", 'Strata', 'YesNo')
        if ($a -ne 'Yes') { return }
    }
    $msg = "Save these changes to $($ed.Row.File)?`n`n" + ($diff -join "`n") + "`n`nThe current file is kept as $($ed.Row.File).bak."
    if (Test-RowRunning $ed.Row) { $msg += "`n`nThe server is running: it uses the new config from its next start." }
    if ([System.Windows.MessageBox]::Show($msg, 'Strata', 'YesNo') -ne 'Yes') { return }
    if (-not (Write-ConfigFile $ed.Row.Path $r.Cfg)) { return }
    $path = $ed.Row.Path
    Read-Configs
    $row = $script:configs | Where-Object { $_.Path -eq $path } | Select-Object -First 1
    if ($row) { $ui.ConfigList.SelectedItem = $row; Open-ConfigEditor $row -Force }
    Set-Status "Saved $(Split-Path $path -Leaf) (the previous version is $(Split-Path $path -Leaf).bak)$(if ($row -and (Test-RowRunning $row)) { '; restart the server to use it' })."
}

function Write-ConfigFile([string]$Path, $Cfg) {
    # Through Strata's runconfig.save when the venv has it (.bak + atomic replace), else the same by hand.
    $tmp = Join-Path $TempDir ('config-' + [Guid]::NewGuid().ToString('N') + '.json')
    if (-not (Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Path $TempDir | Out-Null }
    [IO.File]::WriteAllText($tmp, (Get-ConfigText $Cfg), (New-Object Text.UTF8Encoding $false))
    try {
        $py = Get-Python
        $script = Join-Path $TempDir 'runconfig-gui.py'
        Set-Content -LiteralPath $script -Value $ConfigPy -Encoding ascii
        if ($py -and (Test-Path -LiteralPath (Join-Path (Get-Root) 'serve\runconfig.py'))) {
            if (-not (Test-Path -LiteralPath $Path)) { Copy-Item -LiteralPath $tmp -Destination $Path }   # save needs a file to back up
            $out = & $py -I $script save (Join-Path (Get-Root) 'serve') $Path $tmp 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw $out.Trim() }
        } else {
            if (Test-Path -LiteralPath $Path) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force }
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        }
        return $true
    } catch {
        [System.Windows.MessageBox]::Show("Could not save $Path`n`n$($_.Exception.Message)", 'Strata') | Out-Null
        return $false
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

function Save-ConfigAs {
    $ed = $script:cfgEdit
    if (-not $ed) { return }
    $r = Build-Config
    if ($r.Errors.Count) { [System.Windows.MessageBox]::Show(($r.Errors -join "`n"), 'Strata: cannot save') | Out-Null; return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $base = [IO.Path]::GetFileNameWithoutExtension($ed.Row.File) -replace '^strata-', ''
    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        "A name for the new config (saved as strata-<name>.json beside the others). It starts as the form shows it now; give it its own model_name and port in the form afterwards if both should run.",
        'Save as new config', "$base-variant")
    $name = $name.Trim() -replace '^strata-', '' -replace '\.json$', ''
    if (-not $name) { return }
    if ($name -notmatch '^[\w\.\-]+$') { [System.Windows.MessageBox]::Show('Use letters, digits, ., - and _ only.', 'Strata') | Out-Null; return }
    $path = Join-Path (Get-Root) "strata-$name.json"
    if (Test-Path -LiteralPath $path) { [System.Windows.MessageBox]::Show("$(Split-Path $path -Leaf) exists already.", 'Strata') | Out-Null; return }
    [IO.File]::WriteAllText($path, (Get-ConfigText $r.Cfg), (New-Object Text.UTF8Encoding $false))
    $script:cfgEdit.Dirty = $false
    Read-Configs
    $row = $script:configs | Where-Object { $_.Path -eq $path } | Select-Object -First 1
    if ($row) { $ui.ConfigList.SelectedItem = $row; Open-ConfigEditor $row -Force }
    Update-ServicePicker
    Set-Status "Created $(Split-Path $path -Leaf)."
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
$ui.ConfigList.Add_SelectionChanged({
    Update-CtxHint
    Update-SessionList
    if ($ui.Tabs.SelectedItem -eq $ui.ConfigTab) { Open-ConfigEditor (@(Get-SelectedConfigs) | Select-Object -First 1) }
})
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
    if ($row.Log -and (Test-Path -LiteralPath $row.Log)) { Show-TextWindow $row.Log "Engine log - $($row.Model)" }
    else { Set-Status "No engine log yet: $($row.Log)" }
})
$ui.ConfigBtn.Add_Click({
    $row = Get-Selected
    if (-not $row) { return }
    $ui.Tabs.SelectedItem = $ui.ConfigTab
    Open-ConfigEditor $row
})
$ui.ClineBtn.Add_Click({
    $row = Get-Selected
    if (-not $row) { return }
    $launcher = Clean-Path $ui.ClineScriptBox.Text
    $folder = Clean-Path $ui.FolderBox.Text
    if (-not (Test-Path -LiteralPath $launcher)) { [System.Windows.MessageBox]::Show("Launcher script not found: $launcher", 'Strata') | Out-Null; return }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { [System.Windows.MessageBox]::Show('Choose a project folder.', 'Strata') | Out-Null; return }
    if ($ui.ResumeChk.IsChecked -and (Get-SessionDir $row) -and (Test-Path -LiteralPath (Join-Path (Get-SessionDir $row) (Get-LatestSessionName $row)))) {
        [void](Start-Resume $row -Cline)
        return
    }
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
    if (Test-Path -LiteralPath $readme) { Show-TextWindow $readme "Benchmark report - $($row.Name)" }
})
$ui.ResFolderBtn.Add_Click({
    $row = $ui.ResultList.SelectedItem
    if ($row) { Start-Process explorer.exe -ArgumentList "`"$($row.Path)`"" }
})
$ui.ResCompareBtn.Add_Click({ Compare-Results })

$ui.Tabs.Add_SelectionChanged({
    param($sender, $e)
    if ($e.OriginalSource -eq $ui.Tabs -and $ui.Tabs.SelectedItem -eq $ui.ServiceTab) { Update-ServiceStatus }
    if ($e.OriginalSource -eq $ui.Tabs -and $ui.Tabs.SelectedItem -eq $ui.ConfigTab) { Open-ConfigEditor (@(Get-SelectedConfigs) | Select-Object -First 1) }
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

$ui.CfgSaveBtn.Add_Click({ Save-ConfigEditor })
$ui.CfgRevertBtn.Add_Click({ if ($script:cfgEdit) { Open-ConfigEditor $script:cfgEdit.Row -Force } })
$ui.CfgSaveAsBtn.Add_Click({ Save-ConfigAs })
$ui.CfgFileBtn.Add_Click({ if ($script:cfgEdit) { Open-External $script:cfgEdit.Row.Path } })
$ui.CfgFolderBtn.Add_Click({ if ($script:cfgEdit) { Start-Process explorer.exe -ArgumentList "/select,$(QPath $script:cfgEdit.Row.Path)" } })
$ui.CfgArgAddBtn.Add_Click({
    $r = New-Object StrataCfgArg -Property @{ Flag = '--'; Value = '' }
    $script:cfgArgs.Add($r)
    $ui.CfgArgsGrid.SelectedItem = $r
    $ui.CfgArgsGrid.ScrollIntoView($r)
    Update-CfgChanges
})
$ui.CfgArgDelBtn.Add_Click({
    $r = $ui.CfgArgsGrid.SelectedItem
    if ($r -is [StrataCfgArg]) { [void]$script:cfgArgs.Remove($r); Update-CfgChanges }
})
$ui.CfgArgsGrid.Add_CellEditEnding({ $window.Dispatcher.BeginInvoke([action]{ Update-CfgChanges }) | Out-Null })
$ui.CfgJsonApplyBtn.Add_Click({
    if (-not $script:cfgEdit) { return }
    try { $j = $ui.CfgJson.Text | ConvertFrom-Json } catch { Set-Status "JSON: $($_.Exception.Message)"; return }
    if ($j -isnot [pscustomobject] -or -not $j.args) { Set-Status 'JSON: expected an object with "args".'; return }
    Open-ConfigEditor $script:cfgEdit.Row -Override $j
    Set-Status 'Loaded the JSON into the form; Save writes it.'
})
$ui.CfgTabs.Add_SelectionChanged({
    param($s, $e)
    if ($e.OriginalSource -eq $ui.CfgTabs -and $ui.CfgTabs.SelectedIndex -eq 4 -and $script:cfgEdit) { $ui.CfgJson.Text = Get-ConfigText (Build-Config).Cfg }
})

$ui.ResumeChk.IsChecked = [bool]$settings.ResumeFirst
$ui.SvcHibernateChk.IsChecked = [bool]$settings.SvcHibernate
$ui.SessionBox.AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.Controls.TextChangedEventHandler]{ Update-SessionHint })
$ui.SessSaveBtn.Add_Click({
    $row = Get-Selected; if (-not $row) { return }
    $name = $ui.SessionBox.Text.Trim()
    $dir = Get-SessionDir $row
    if ($dir -and (Test-Path -LiteralPath (Join-Path $dir $name))) {
        if ([System.Windows.MessageBox]::Show("Replace $name?", 'Strata', 'YesNo') -ne 'Yes') { return }
    }
    Start-SlotAction $row 'save' $name ''
})
$ui.SessRestoreBtn.Add_Click({
    $row = Get-Selected; if (-not $row) { return }
    $name = $ui.SessionBox.Text.Trim()
    $dir = Get-SessionDir $row
    if (-not $dir -or -not (Test-Path -LiteralPath (Join-Path $dir $name))) { Set-Status "No session file $name."; return }
    $msg = "Restore $name? The conversation the engine holds now is replaced (save it first if you want it back)."
    if ([System.Windows.MessageBox]::Show($msg, 'Strata', 'YesNo') -ne 'Yes') { return }
    Start-SlotAction $row 'restore' $name ''
})
$ui.SessDeleteBtn.Add_Click({
    $row = Get-Selected; if (-not $row) { return }
    $name = $ui.SessionBox.Text.Trim()
    $path = Join-Path (Get-SessionDir $row) $name
    if (-not (Test-SessionName $name) -or -not (Test-Path -LiteralPath $path)) { Set-Status "No session file $name."; return }
    if ([System.Windows.MessageBox]::Show("Delete $name ($([int]((Get-Item -LiteralPath $path).Length / 1MB)) MiB)? This cannot be undone.", 'Strata', 'YesNo') -ne 'Yes') { return }
    Remove-Item -LiteralPath $path
    Set-Status "Deleted $name."
    Update-SessionList
})
$ui.SessFolderBtn.Add_Click({
    $row = Get-Selected; if (-not $row) { return }
    $dir = Get-SessionDir $row
    if (Test-Path -LiteralPath $dir) { Start-Process explorer.exe -ArgumentList (QPath $dir) } else { Set-Status "$dir does not exist yet (the server creates it)." }
})
$ui.HibernateBtn.Add_Click({
    $row = Get-Selected; if (-not $row) { return }
    if (-not (Test-RowReady $row)) { Set-Status "$($row.Model) is not loaded: nothing to hibernate."; return }
    Start-SlotAction $row 'save' (Get-LatestSessionName $row) 'stop'
})
$ui.ResumeBtn.Add_Click({
    $row = Get-Selected; if (-not $row) { return }
    [void](Start-Resume $row)
})

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
    if (Test-Path -LiteralPath $ServiceLog) { Show-TextWindow $ServiceLog 'Strata on-demand service log' } else { Set-Status 'No service log yet.' }
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
        Update-SlotOp
        Update-ResumePending
        $script:svcTick++
        if ($script:svcTick % 5 -eq 0 -and $ui.Tabs.SelectedItem -eq $ui.ServiceTab) { Update-ServiceStatus }
    } catch {
        Set-Status "Error: $($_.Exception.Message)"
    }
})

$window.Add_Closing({
    param($sender, $e)
    if ($script:cfgEdit -and $script:cfgEdit.Dirty) {
        $answer = [System.Windows.MessageBox]::Show("$($script:cfgEdit.Row.File) has unsaved changes. Close anyway?", 'Strata', 'YesNo')
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
    }    if ($script:job) {
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
        ResumeFirst  = [bool]$ui.ResumeChk.IsChecked
        SvcHibernate = [bool]$ui.SvcHibernateChk.IsChecked
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
Update-SessionList
Update-ServicePicker
Read-Results
Update-Health
$timer.Start()
[void]$window.ShowDialog()
