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
    [string]$SessionName,
    # -FirstRun: ask again whether to use an existing Strata folder or set up a fresh one.
    [switch]$FirstRun
)

$ErrorActionPreference = 'Continue'
$AppVersion = '0.2.0'   # install.ps1 reads this line for the Settings > Apps entry
$SettingsPath = Join-Path $PSScriptRoot 'strata-launcher.settings.json'
# Named strata-gui before: carry its settings over once.
$oldSettings = Join-Path $PSScriptRoot 'strata-gui.settings.json'
if (-not (Test-Path -LiteralPath $SettingsPath) -and (Test-Path -LiteralPath $oldSettings)) { Copy-Item -LiteralPath $oldSettings -Destination $SettingsPath }
$TempDir = Join-Path $env:TEMP 'strata-launcher'
$ThinkingLevels = @('none', 'low', 'medium', 'high', 'xhigh')
$LoadTimeoutMinutes = 30
# Tokens held back from the context Cline is told about - see Get-ClineContext.
$ClineContextReserve = 4096
$ClineReservePercent = 2      # the Headroom box
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
    StrataRoot    = ''
    ClineScript   = (Join-Path $PSScriptRoot 'cline-strata.ps1')
    ClineFolder   = [Environment]::GetFolderPath('UserProfile')
    Thinking      = ''
    Context       = ''
    ExtraArgs     = ''
    VramReserve   = ''
    FitMaxTokens  = $true
    ResumeFirst   = $false
    SvcHibernate  = $false
    ReservePercent = '2'
    HeadroomV2    = $false   # a saved 10 is the old default: moved to 2 once (see Get-ClineContext)
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
        Title="Strata Launcher" Height="760" Width="1040" MinHeight="600" MinWidth="820"
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
            <GridViewColumn Header="Model" Width="260" DisplayMemberBinding="{Binding Model}"/>
            <GridViewColumn Header="Quant" Width="80" DisplayMemberBinding="{Binding Quant}"/>
            <GridViewColumn Width="70" DisplayMemberBinding="{Binding Disk}">
              <GridViewColumn.Header><TextBlock Text="Disk GB" ToolTip="What the model's files take on disk (Strata's own count), with the files it shares with other models, such as the MTP draft layer. Remove model frees the part that is its alone."/></GridViewColumn.Header>
            </GridViewColumn>
            <GridViewColumn Width="70" DisplayMemberBinding="{Binding Ram}">
              <GridViewColumn.Header><TextBlock Text="RAM GB" ToolTip="System RAM it needs to keep every expert in RAM, from Strata's model catalog (a range: it runs with less, reading the rest from the SSD). ~ : not in the catalog; the closest entry's figure."/></GridViewColumn.Header>
            </GridViewColumn>
            <GridViewColumn Header="Context" Width="80" DisplayMemberBinding="{Binding Context}"/>
            <GridViewColumn Header="KV" Width="50" DisplayMemberBinding="{Binding Kv}"/>
            <GridViewColumn Header="Port" Width="50" DisplayMemberBinding="{Binding Port}"/>
            <GridViewColumn Width="230" DisplayMemberBinding="{Binding Status}">
              <GridViewColumn.Header><TextBlock Text="Server" ToolTip="The server's state. While a model runs: its context, and the share of drafted tokens it accepted since it started (speculative decoding with the MTP draft layer and prompt lookup; higher is faster)."/></GridViewColumn.Header>
            </GridViewColumn>
          </GridView>
        </ListView.View>
      </ListView>

      <TabControl Grid.Row="3" x:Name="Tabs">
        <TabItem Header="  Launch  ">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="12">
            <TextBlock Text="Overrides (leave empty to use the config as it is; a changed config is written to %TEMP%\strata-launcher)" FontWeight="SemiBold" Margin="0,0,0,8"/>
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
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="110"/>
                <ColumnDefinition Width="200"/>
                <ColumnDefinition Width="24"/>
                <ColumnDefinition Width="110"/>
                <ColumnDefinition Width="90"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Grid.Column="0" Text="MTP drafting" Style="{StaticResource Label}"/>
              <ComboBox Grid.Column="1" x:Name="MtpBox" ToolTip="Speculative decoding with the model's MTP draft layer: it guesses tokens ahead and one pass checks them, so answers are the same, only faster. Off: drafts come from prompt lookup only, and the layer's ~0.7-1 GiB of VRAM goes to the expert cache. Benchmark both to compare."/>
              <TextBlock Grid.Column="3" Text="Draft depth" Style="{StaticResource Label}"/>
              <ComboBox Grid.Column="4" x:Name="SpecBox" ToolTip="--spec: tokens the draft layer proposes per check (setup writes 4). Deeper pays off when most drafts are accepted (see the Server column)."/>
              <TextBlock Grid.Column="5" Text="  The Server column shows the share of drafted tokens accepted while a model runs." Style="{StaticResource Hint}" VerticalAlignment="Center"/>
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
              <Button x:Name="RemoveModelBtn" Content="Remove model..." ToolTip="Delete this model's files and config to free the disk space (Strata decides what is safe to delete; files another model uses stay)"/>
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
                        ToolTip="Share of the context Cline is not told about (at least 4096 tokens). Cline compacts at 90% of what it is told, and counts characters / 3, which runs ~30% over Qwen's real count on code - so it compacts early anyway; it corrects an undercount by itself after each request. 2% keeps the most of the window; raise it only if a prompt is ever refused as too long."/>
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
                  <GridViewColumn Header="Results folder" Width="290" DisplayMemberBinding="{Binding Name}"/>
                  <GridViewColumn Header="Model" Width="170" DisplayMemberBinding="{Binding Model}"/>
                  <GridViewColumn Header="Context" Width="65" DisplayMemberBinding="{Binding Context}"/>
                  <GridViewColumn Width="75" DisplayMemberBinding="{Binding Mtp}">
                    <GridViewColumn.Header><TextBlock Text="MTP" ToolTip="The run's speculative decoding, from the engine arguments it ran with: spec N (the MTP draft layer, N tokens per check), lookup N (no draft layer, prompt lookup only) or off."/></GridViewColumn.Header>
                  </GridViewColumn>
                  <GridViewColumn Width="70" DisplayMemberBinding="{Binding Drafts}">
                    <GridViewColumn.Header><TextBlock Text="Drafts %" ToolTip="Drafted tokens accepted, over all of the run's chat requests."/></GridViewColumn.Header>
                  </GridViewColumn>
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
              <Button x:Name="CatRemoveBtn" DockPanel.Dock="Right" Content="Remove..." Margin="8,0,0,0" VerticalAlignment="Top" IsEnabled="False"
                      ToolTip="Delete the selected installed model's files and config to free the disk space (Strata decides what is safe to delete; files another model uses stay)"/>
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

        <TabItem Header="  Setup  " x:Name="SetupTab">
          <DockPanel Margin="12">
            <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Foreground="#FF444444" Margin="0,0,0,10"
                       Text="Everything Strata and Strata Launcher need, one step at a time. Nothing is installed until you press a step's button; it says what it will do first, and long steps run in their own window. Strata's own setup (START-HERE.bat) installs Python, the engine and the model; this tab gets what it does not: Git, Strata itself, Node.js and Cline."/>
            <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="120"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="Strata folder" Style="{StaticResource Label}"/>
              <TextBox Grid.Column="1" x:Name="SetupRootBox" ToolTip="Where Strata is (or goes). An existing checkout is used as it is."/>
              <Button Grid.Column="2" x:Name="SetupRootBrowse" Content="Browse..." Margin="8,0,0,0"/>
            </Grid>
            <Grid DockPanel.Dock="Top" Margin="0,0,0,10">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="120"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="Model files" Style="{StaticResource Label}"/>
              <TextBox Grid.Column="1" x:Name="SetupDataBox" ToolTip="Where setup puts the 60-190 GB of model files (its --data-dir). Default: Strata-data next to the Strata folder."/>
              <Button Grid.Column="2" x:Name="SetupDataBrowse" Content="Browse..." Margin="8,0,0,0"/>
            </Grid>
            <DockPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
              <Button x:Name="SetupRefreshBtn" DockPanel.Dock="Right" Content="Check again" Margin="8,0,0,0"/>
              <TextBlock x:Name="SetupNote" TextWrapping="Wrap" Foreground="#FF444444" VerticalAlignment="Center"/>
            </DockPanel>
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="SetupSteps"/>
            </ScrollViewer>
          </DockPanel>
        </TabItem>
      </TabControl>
    </Grid>
  </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$AppIcon = Join-Path $PSScriptRoot 'assets\strata-launcher.ico'
if (Test-Path -LiteralPath $AppIcon) { try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$AppIcon) } catch {} }
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
$script:draftTasks = @{}    # port -> pending /metrics/prometheus read, for the MTP acceptance
$script:drafts = @{}        # port -> @{ Offered; Accepted } since the server started
$script:draftAt = @{}       # port -> when it was last asked
$script:started = @{}       # port -> the cmd.exe process this GUI started
$script:startedRow = @{}    # port -> the config path that process serves
$script:startedCfg = @{}    # port -> the config file it was started with (a %TEMP% copy when overridden)
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

# Strata's own answers about installed models, from tools/strata_mcp.py (the code its desktop and terminal apps
# use): "usage", what each model takes on disk; "plan", what removing one deletes - the files that are its alone
# (a file another installed model's config names stays, and so does a file outside Strata's folders that Strata
# did not download) plus its config, .bak, log and run-*.bat; "delete", that removal carried out.
$StrataHelperPy = @'
import importlib.util, json, sys
from pathlib import Path
root, tag, action = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
out, sys.stdout = sys.stdout, sys.stderr          # only the JSON answer goes to stdout
try:
    sys.path.insert(0, str(root))
    spec = importlib.util.spec_from_file_location("strata_mcp_for_launcher", root / "tools" / "strata_mcp.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    try:
        s = mod.Strata(root, root)
    except TypeError:                             # an older Strata: Strata(root) only
        s = mod.Strata(root)
    if action == "usage":
        r = s.disk_usage() if hasattr(s, "disk_usage") else {"error": "this Strata is too old to report disk use"}
    elif not hasattr(s, "removal_plan") or not hasattr(mod, "Tools"):
        r = {"error": "this Strata is too old to remove models from here: update it first (Setup tab)"}
    elif action == "plan":
        r = s.removal_plan(s.find_config(tag))
    else:
        r = mod.Tools(s).strata_remove(tag, confirm=True)
except Exception as e:
    r = {"error": str(e) or type(e).__name__}
out.write(json.dumps(r))
'@

function Invoke-StrataHelper([string]$Tag, [string]$Action) {
    # -> Strata's answer (usage, plan, or what was deleted), or @{ error } when it could not be asked.
    # $Tag is a config's name without strata- and .json ('-' for usage: Windows PowerShell drops an empty argument).
    $py = Get-Python
    if (-not $py) { return [pscustomobject]@{ error = "Strata's Python environment (.venv) is not set up: run the PC check in the Setup tab" } }
    if (-not (Test-Path -LiteralPath (Join-Path (Get-Root) 'tools\strata_mcp.py'))) { return [pscustomobject]@{ error = 'this Strata is too old for that: update it first (Setup tab)' } }
    if (-not (Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Path $TempDir | Out-Null }
    $script = Join-Path $TempDir 'strata-helper.py'
    [IO.File]::WriteAllText($script, $StrataHelperPy, (New-Object Text.UTF8Encoding $false))
    $old = $env:PYTHONUTF8; $env:PYTHONUTF8 = '1'
    try { $json = & $py $script (Get-Root) $Tag $Action 2>$null | Out-String } finally { $env:PYTHONUTF8 = $old }
    try { return ($json | ConvertFrom-Json) } catch { return [pscustomobject]@{ error = "Strata gave no answer ($($json.Trim()))" } }
}

function Remove-Model($Row) {
    if (Test-RowRunning $Row) { Set-Status "$($Row.Model) is running: stop it first, then remove it."; return }
    if (Test-ServiceRow $Row) { Set-Status "$($Row.Model) is the Service tab's model: remove the service first, then the model."; return }
    $tag = [IO.Path]::GetFileNameWithoutExtension($Row.File) -replace '^strata-', ''
    Set-Status "Asking Strata what removing $($Row.Model) deletes..."
    $plan = Invoke-StrataHelper $tag 'plan'
    if ($plan.error) { Set-Status "Cannot remove $($Row.Model): $($plan.error)"; return }
    $fmt = { param($b) if ($b -ge 1GB) { '{0:n1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:n0} MB' -f ($b / 1MB) } else { '{0:n0} KB' -f ($b / 1KB) } }
    $lines = @($plan.remove | Sort-Object bytes -Descending | ForEach-Object { "  $(& $fmt $_.bytes)`t$($_.path)" })
    if ($lines.Count -gt 14) { $lines = $lines[0..12] + "  ... and $($lines.Count - 13) more" }
    $kept = @($plan.keep | ForEach-Object { "  $($_.path)`n      ($($_.reason))" })
    $msg = "Remove $($Row.Model) ($($Row.File))? This frees $(& $fmt $plan.bytes) and cannot be undone.`n`nDeleted:`n$($lines -join "`n")" +
        $(if ($kept) { "`n`nKept:`n$($kept -join "`n")" } else { '' }) +
        $(if (Get-SessionDir $Row) { "`n`nIts session files (in $(Get-SessionDir $Row)) are kept." } else { '' })
    if ([System.Windows.MessageBox]::Show($msg, 'Remove model', 'OKCancel', 'Warning') -ne 'OK') { Set-Status 'Nothing was removed.'; return }
    $window.Cursor = [System.Windows.Input.Cursors]::Wait
    try { $r = Invoke-StrataHelper $tag 'delete' } finally { $window.Cursor = $null }
    if ($r.error) { Set-Status "Removing $($Row.Model) failed: $($r.error)"; return }
    $settings.LastConfig = ''
    Read-Configs; Update-ServicePicker; Update-SessionList
    Update-CatalogFit   # the Models tab's "installed" marks
    Set-Status ("Removed $($Row.Model) and freed $(& $fmt $plan.bytes)." + $(if (@($r.failed).Count) { ' Not removed (in use?): ' + (@($r.failed) -join '; ') } else { '' }))
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
    if (-not (Test-StrataFolder $root)) {
        Set-Status "No Strata in $root yet: the Setup tab downloads and sets it up."
        return
    }
    Set-StrataReg 'StrataRoot' $root
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
            Disk    = ''   # Update-ConfigSizes fills these in once the list is up
            Ram     = ''
            Port    = $port
            Log     = [string]$cfg.log
            Status  = '...'
            Cfg     = $cfg
        }
        $script:configs.Add($row)
    }
    if ($script:configs.Count) { [void]$window.Dispatcher.BeginInvoke([action]{ Update-ConfigSizes }, [System.Windows.Threading.DispatcherPriority]::Background) }
    foreach ($row in $script:configs) {
        if ($keep -contains $row.Path) { [void]$ui.ConfigList.SelectedItems.Add($row) }
    }
    if ($ui.ConfigList.SelectedItems.Count -eq 0 -and $script:configs.Count -gt 0) { $ui.ConfigList.SelectedIndex = 0 }
    if ($script:configs.Count -eq 0) {
        Set-Status "No model set up in $root yet: the Setup tab's model step chooses and downloads one."
    } else {
        Set-Status "$($script:configs.Count) model config(s) in $root"
    }
}

function Get-CatalogRamText($M, $Cat) {
    # A model's RAM need as the catalog states it: one figure, or for a RAM-budget model the range from its
    # minimum to every expert in RAM.
    if ($M.budget) { return '{0}-{1:n0}' -f $Cat.unsloth_min, ($M.arena_gb / 1.073741824 + $Cat.beside) }
    return [string]$M.ram_gb
}

function Update-ConfigSizes {
    # The installed list's Disk and RAM columns: disk from Strata's own count (disk_usage, the figure its apps
    # show), RAM from its catalog (setup.py). Either is left empty when this Strata cannot say.
    if (-not $script:configs.Count -or -not (Get-Python)) { return }
    $usage = Invoke-StrataHelper '-' 'usage'
    $cat = if ($script:catalog) { $script:catalog } else { $script:sizeCatalog }
    if (-not $cat) {
        if (-not (Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Path $TempDir | Out-Null }
        $file = Join-Path $TempDir 'catalog.py'
        Set-Content -LiteralPath $file -Value $CatalogPy -Encoding ascii
        Push-Location -LiteralPath (Get-Root)
        try { $cat = & (Get-Python) -I $file (Get-Root) 2>$null | Out-String | ConvertFrom-Json } catch { $cat = $null } finally { Pop-Location }
        $script:sizeCatalog = $cat
    }
    foreach ($row in $script:configs) {
        $tag = [IO.Path]::GetFileNameWithoutExtension($row.File) -replace '^strata-', ''
        $u = if (-not $usage.error -and $usage.models) { $usage.models.$tag } else { $null }
        $row.Disk = if ($u) { '{0:n1}' -f (([double]$u.bytes + [double]$u.shared_bytes) / 1e9) } else { '' }
        $row.Ram = ''
        if ($cat) {
            $name = $row.Model.ToLower()
            $m = $cat.models | Where-Object { ('{0}-{1}' -f $_.name, $_.quant).ToLower() -eq $name } | Select-Object -First 1
            if ($m) { $row.Ram = Get-CatalogRamText $m $cat }
            else {
                # a model of your own: the catalog entry whose base name it contains and whose quant it ends with
                $m = $cat.models | Where-Object { $name.Contains($_.name.ToLower()) -and $name.EndsWith('-' + $_.quant.ToLower()) } |
                    Sort-Object { $_.name.Length } -Descending | Select-Object -First 1
                if ($m) { $row.Ram = '~' + (Get-CatalogRamText $m $cat) }
            }
        }
    }
    $ui.ConfigList.Items.Refresh()
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

function Remove-Arg($List, [string]$Name, [switch]$Switch) {
    # the flag and its value; -Switch: a flag that takes none
    $i = $List.IndexOf($Name)
    if ($i -ge 0) { $List.RemoveRange($i, $(if ($Switch) { 1 } else { [Math]::Min(2, $List.Count - $i) })) }
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
    $mtp = [string]$ui.MtpBox.SelectedItem
    $spec = [string]$ui.SpecBox.SelectedItem
    if ($mtp -notmatch '^(on|off)') { $mtp = '' }
    if ($spec -notmatch '^\d+$') { $spec = '' }
    if (-not $ctx -and -not $extra -and -not $vram -and -not $fit -and -not $mtp -and -not $spec) { return $Row.Path }
    $cfg = Get-Content -LiteralPath $Row.Path -Raw | ConvertFrom-Json
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($a in $cfg.args) { $list.Add([string]$a) }
    if ($ctx) { Set-ContextArgs $list $ctx }
    if ($vram) { Set-ArgValue $list '--vram-reserve-mib' $vram }
    if ($mtp -like 'off*') {
        # no draft layer: --batch-mtp needs it; --spec stays for the prompt-lookup drafts
        Remove-Arg $list '--mtp'
        Remove-Arg $list '--batch-mtp' -Switch
    } elseif ($mtp -like 'on*' -and $list -notcontains '--mtp') {
        $dir = Join-Path (Clean-Path $ui.DataBox.Text) 'mtp\rt'
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'experts.bin'))) { throw "MTP on: no draft layer in $dir. Strata's setup downloads it with a model." }
        Set-ArgValue $list '--mtp' $dir
        if ($list -notcontains '--spec') { Set-ArgValue $list '--spec' '4' }
    }
    if ($spec) { Set-ArgValue $list '--spec' $spec }
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
    $script:startedCfg[$Row.Port] = $cfgPath   # with its overrides: what a benchmark of it records
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
    # The share of drafted tokens the model accepted (MTP and prompt lookup), from the server's own counters, every
    # 5 s while a model is loaded: the small Prometheus page, not /metrics with its request history.
    foreach ($port in @($script:configs | Select-Object -ExpandProperty Port -Unique)) {
        $h = $script:health[$port]
        if (-not ($h -and $h.Loaded)) { $script:drafts.Remove($port); continue }
        $task = $script:draftTasks[$port]
        if ($task) {
            if (-not $task.IsCompleted) { continue }
            if ($task.Status -eq 'RanToCompletion') {
                $o = [regex]::Match($task.Result, '(?m)^strata:drafts_offered_total\s+(\d+)')
                $a = [regex]::Match($task.Result, '(?m)^strata:drafts_accepted_total\s+(\d+)')
                if ($o.Success -and $a.Success) { $script:drafts[$port] = @{ Offered = [int64]$o.Groups[1].Value; Accepted = [int64]$a.Groups[1].Value } }
            }
            $script:draftTasks.Remove($port)
        } elseif (-not $script:draftAt[$port] -or ((Get-Date) - $script:draftAt[$port]).TotalSeconds -ge 5) {
            $script:draftAt[$port] = Get-Date
            $script:draftTasks[$port] = $script:http.GetStringAsync("http://127.0.0.1:$port/metrics/prometheus")
        }
    }
    $changed = $false
    foreach ($row in $script:configs) {
        $h = $script:health[$row.Port]
        $mine = Test-StartedHere $row
        $loading = $script:loadTasks[$row.Port] -and -not $script:loadTasks[$row.Port].IsCompleted
        $d = $script:drafts[$row.Port]
        $taken = if ($d -and $d.Offered -gt 0) { ', drafts {0:p0}' -f ($d.Accepted / $d.Offered) } else { '' }
        $status = if (-not $h) { '...' }
            elseif ($h.Up -and $h.Model -and $h.Model -ne $row.Model) { 'stopped (port in use)' }
            elseif ($h.Loaded) { "ready  ($(Format-Tokens $h.Context) ctx$taken)" }
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
    # The number Cline is told the window is: a little under what the server really has. Strata never
    # truncates (a prompt over the window is refused), so Cline must compact first. Cline CLI 3
    # (@cline/core) compacts once its estimate reaches 0.9x this number; the estimate is JSON chars / 3,
    # and it scales an undercount up by the prompt_tokens the server reported for the previous request
    # (never an overcount down). On Qwen and a code session that estimate runs ~30% high: told 471,859
    # of a 524,288 window, it compacted at 325,817 real tokens. So the reserve no longer has an
    # undercount to cover - Cline's own 10% and its overcount already hold the prompt well under the
    # window - and a large one only compacts earlier still. It is a small share ($ClineReservePercent,
    # the Headroom box, default 2), never under $ClineContextReserve. (The older Cline undercounted,
    # ~chars/4 with no correction, and sent prompts ~4.5% over a 4096 reserve: the reason it was 10%.)
    # cline-strata.ps1 runs the same formula (tests\context-tests.ps1 keeps the two in step) and the
    # status bar shows both numbers when Cline opens.
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
    # the config the server runs with: this run's overrides when the benchmark started it, the ones it was started
    # with from here, or the config as it is
    $cfgPath = if ($job.WeStarted) { Get-EffectiveConfig $Row }
        elseif ((Test-StartedHere $Row) -and $script:startedCfg[$Row.Port]) { $script:startedCfg[$Row.Port] }
        else { $Row.Path }
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
            $row = [pscustomobject]@{ Name = $d.Name; Path = $d.FullName; Model = '-'; Context = '-'; Mtp = '-'; Drafts = '-'; Decode = '-'; P4 = '-'; P16 = '-'; Hit = '-'; Json = $null }
            if ($bench) {
                $r = $j.results
                $row.Json = $j
                $row.Model = (@($j.machine.model, $j.machine.quant) | Where-Object { $_ }) -join ' '
                $row.Context = Format-Tokens $j.machine.context
                # the engine arguments the run had (strata_bench records the config it was given)
                $runArgs = @($j.machine.config.args | ForEach-Object { [string]$_ })
                if ($runArgs.Count) {
                    $depth = Get-ArgValue $runArgs '--spec'
                    $row.Mtp = if ($runArgs -contains '--mtp') { "spec $(if ($depth) { $depth } else { '?' })" } elseif ($depth) { "lookup $depth" } else { 'off' }
                }
                $reqs = @($r.chat.requests | Where-Object { $_.ok -and $null -ne $_.drafts_offered })
                $offered = ($reqs | Measure-Object drafts_offered -Sum).Sum
                if ($offered -gt 0) { $row.Drafts = '{0:n0}' -f (100 * ($reqs | Measure-Object drafts_accepted -Sum).Sum / $offered) }
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
                 Description = "Strata $($row.Model) on demand (port $($row.Port), unloads after $minutes min idle$(if ($hibernate) { ', saving the session first' })). Managed by strata-launcher.ps1." }
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

# ------------------------------------------------------------------------------------ setup (first run)
# Finds or fetches everything this GUI drives. Strata's own START-HERE.bat installs Python, the engine
# and the model (from Hugging Face, resumable); this gets what it does not: Git, the Strata checkout,
# Node.js and Cline. Long steps run in a console of their own; the step list re-checks itself.
$StrataRepo = 'https://github.com/Niko1221/Strata'
$script:hw = $null
$script:setupProcs = @{}

Add-Type -Namespace StrataLauncher -Name Cpu -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);'

function Update-EnvPath {
    # Programs installed from another window since this one started: pick up their PATH entries.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
    $npm = Join-Path $env:APPDATA 'npm'
    if (Test-Path -LiteralPath $npm) { $env:Path = "$npm;$env:Path" }
}

function Test-StrataFolder([string]$Path) {
    # [IO.Path]::Combine, not Join-Path: a remembered folder on a drive that is gone (a USB disk, a
    # mapped drive) is just "not here", where Join-Path throws
    return [bool]($Path -and (Test-Path -LiteralPath ([IO.Path]::Combine($Path, 'START-HERE.bat'))) -and
                  (Test-Path -LiteralPath ([IO.Path]::Combine($Path, 'serve\server.py'))))
}

# The folders this GUI uses are kept per user in the registry (no admin rights), where the Cline
# launcher and install.ps1 find them too: StrataRoot, DataDir, AppDir.
$RegKey = 'HKCU:\Software\StrataLauncher'
# Named strata-gui before (HKCU\Software\StrataGui, GuiDir): carry its values over once.
if (-not (Test-Path $RegKey) -and (Test-Path 'HKCU:\Software\StrataGui')) {
    try {
        $old = Get-ItemProperty 'HKCU:\Software\StrataGui'
        New-Item -Path $RegKey -Force | Out-Null
        foreach ($n in 'StrataRoot', 'DataDir') { if ($old.$n) { Set-ItemProperty -Path $RegKey -Name $n -Value $old.$n } }
    } catch {}
}

function Get-StrataReg([string]$Name) {
    try { return [string](Get-ItemProperty -Path $RegKey -Name $Name -ErrorAction Stop).$Name } catch { return '' }
}

function Set-StrataReg([string]$Name, [string]$Value) {
    if (-not $Value -or (Get-StrataReg $Name) -eq $Value) { return }
    try {
        if (-not (Test-Path $RegKey)) { New-Item -Path $RegKey -Force | Out-Null }
        Set-ItemProperty -Path $RegKey -Name $Name -Value $Value
    } catch {}
}

function Find-StrataRoots {
    # Strata checkouts in the usual places: $env:STRATA_ROOT, beside this GUI, the user's folders, and
    # <drive>:\Strata, <drive>:\*\Strata, <drive>:\*\*\Strata on every fixed drive (system folders skipped).
    # Listed with .NET and stopped after a few seconds: PowerShell wildcards took ~30 s on a full PC.
    $c = New-Object System.Collections.Generic.List[string]
    if ($env:STRATA_ROOT) { $c.Add($env:STRATA_ROOT) }
    if ($PSScriptRoot) { foreach ($n in 'Strata', 'strata') { $c.Add((Join-Path (Split-Path -Parent $PSScriptRoot) $n)) } }
    foreach ($base in @([Environment]::GetFolderPath('UserProfile'), [Environment]::GetFolderPath('MyDocuments'))) { if ($base) { $c.Add((Join-Path $base 'Strata')) } }
    $skip = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin', 'System Volume Information',
              'Recovery', 'PerfLogs', 'AppData', 'node_modules', '.git', 'Config.Msi', '$WinREAgent')
    $dirs = {
        param([string]$Path)
        try { @([IO.Directory]::EnumerateDirectories($Path) | Where-Object { $skip -notcontains [IO.Path]::GetFileName($_) }) } catch { @() }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        $c.Add((Join-Path $d.RootDirectory.FullName 'Strata'))
        foreach ($a in (& $dirs $d.RootDirectory.FullName)) {
            if ($clock.Elapsed.TotalSeconds -gt 4) { break }
            $c.Add((Join-Path $a 'Strata'))
            foreach ($b in (& $dirs $a)) { if ([IO.Directory]::Exists((Join-Path $b 'Strata'))) { $c.Add((Join-Path $b 'Strata')) } }
        }
    }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($p in $c) {
        if (Test-StrataFolder $p) {
            $r = (Resolve-Path -LiteralPath $p).Path
            if (-not ($found | Where-Object { $_ -eq $r })) { $found.Add($r) }
        }
    }
    return $found.ToArray()   # unrolled: callers wrap it in @()
}

function Find-StrataRoot { @(Find-StrataRoots) | Select-Object -First 1 }

function Show-FirstRunDialog {
    # Shown when no Strata folder is registered. One location: a folder with Strata is used as it is;
    # an empty or new one is where the Setup tab downloads it. -> @{ Mode = 'existing'|'fresh'; Root; Data }
    # or $null for "later".
    [xml]$x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Set up Strata" Width="700" SizeToContent="Height" WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        FontFamily="Segoe UI" FontSize="13">
  <StackPanel Margin="18">
    <TextBlock TextWrapping="Wrap" Margin="0,0,0,12" Text="Where is Strata? Point at a folder that has it, or at an empty (or new) folder to download it there: the Setup tab then installs everything Strata needs."/>
    <TextBlock x:Name="FoundLabel" Text="Found on this PC:" FontWeight="SemiBold" Margin="0,0,0,4"/>
    <ListBox x:Name="FoundList" MaxHeight="96" Margin="0,0,0,12"/>
    <Grid Margin="0,0,0,4">
      <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions><RowDefinition/><RowDefinition Height="8"/><RowDefinition/></Grid.RowDefinitions>
      <TextBlock Text="Strata folder" VerticalAlignment="Center" FontWeight="SemiBold"/>
      <TextBox Grid.Column="1" x:Name="RootBox" Height="26" VerticalContentAlignment="Center"/>
      <Button Grid.Column="2" x:Name="RootBrowse" Content="Browse..." Padding="12,3" Margin="8,0,0,0"/>
      <TextBlock Grid.Row="2" Text="Model files" VerticalAlignment="Center"/>
      <TextBox Grid.Row="2" Grid.Column="1" x:Name="DataBox" Height="26" VerticalContentAlignment="Center"/>
      <Button Grid.Row="2" Grid.Column="2" x:Name="DataBrowse" Content="Browse..." Padding="12,3" Margin="8,0,0,0"/>
    </Grid>
    <TextBlock x:Name="Hint" Margin="110,4,0,16" TextWrapping="Wrap"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="Later" Content="Later" Padding="16,4" Margin="0,0,8,0" IsCancel="True"/>
      <Button x:Name="Go" Content="Continue" Padding="16,4" IsDefault="True" FontWeight="SemiBold" MinWidth="170"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    # The dialog's state lives in $script:frState: its event handlers run after this function returns.
    $f = @{ Window = $w }
    foreach ($n in 'FoundLabel', 'FoundList', 'RootBox', 'RootBrowse', 'DataBox', 'DataBrowse', 'Hint', 'Go') { $f[$n] = $w.FindName($n) }
    $found = @(Find-StrataRoots)
    foreach ($r in $found) { [void]$f.FoundList.Items.Add($r) }
    if (-not $found.Count) { $f.FoundLabel.Visibility = 'Collapsed'; $f.FoundList.Visibility = 'Collapsed' }
    $f.RootBox.Text = $(if ($found.Count) { $found[0] } else { Get-SuggestedStrataRoot })
    $f.DataBox.Text = Get-DefaultDataDir $f.RootBox.Text
    $script:frState = $f
    $script:frResult = $null
    $f.FoundList.Add_SelectionChanged({ if ($script:frState.FoundList.SelectedItem) { $script:frState.RootBox.Text = [string]$script:frState.FoundList.SelectedItem } })
    $f.RootBox.Add_TextChanged({ Update-FirstRunHints })
    $f.DataBox.Add_TextChanged({ Update-FirstRunHints })
    $f.RootBrowse.Add_Click({
        $cur = Clean-Path $script:frState.RootBox.Text
        $p = Select-Folder $(if (Test-Path -LiteralPath $cur) { $cur } else { Split-Path $cur -Parent }) 'Choose the Strata folder: one that has Strata, or an empty one to download it into'
        if ($p) {
            # a folder that already has other things in it gets a new Strata folder inside it
            $busy = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue).Count -and -not (Test-StrataFolder $p)
            $script:frState.RootBox.Text = $(if ($busy) { Join-Path $p 'Strata' } else { $p })
        }
    })
    $f.DataBrowse.Add_Click({
        $p = Select-Folder (Clean-Path $script:frState.DataBox.Text) 'Choose where the model files go (60-190 GB)'
        if ($p) { $script:frState.DataBox.Text = $p }
    })
    $f.Go.Add_Click({
        $s = $script:frState
        $r = Clean-Path $s.RootBox.Text
        $state = Get-FolderState $r
        if ($state -eq 'other') { return }
        $script:frResult = @{ Mode = $(if ($state -eq 'strata') { 'existing' } else { 'fresh' }); Root = $r; Data = Clean-Path $s.DataBox.Text }
        $s.Window.DialogResult = $true
    })
    Update-FirstRunHints
    [void]$w.ShowDialog()
    return $script:frResult
}

function Get-FolderState([string]$Path) {
    # strata: has Strata; empty: missing or empty (Strata can be downloaded into it); other: something else is there.
    if (-not $Path) { return 'other' }
    if (Test-StrataFolder $Path) { return 'strata' }
    if (-not (Test-Path -LiteralPath $Path) -or -not @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count) { return 'empty' }
    return 'other'
}

function Update-FirstRunHints {
    $s = $script:frState
    $r = Clean-Path $s.RootBox.Text
    $d = Clean-Path $s.DataBox.Text
    $free = if ($d) { Get-FreeGB $d } else { $null }
    $space = if ($null -ne $free) { " The model files need 60-190 GB; $free GB free for them." } else { '' }
    switch (Get-FolderState $r) {
        'strata' {
            $s.Go.Content = 'Use this folder'; $s.Go.IsEnabled = $true; $s.Hint.Foreground = '#FF2E7D32'
            $s.Hint.Text = "Strata is here$(if (Test-Path -LiteralPath (Join-Path $r '.venv')) { ' and set up' } else { '; the Setup tab runs its setup' })." + $space
        }
        'empty' {
            $s.Go.Content = 'Download Strata here'; $s.Go.IsEnabled = $true; $s.Hint.Foreground = '#FF1565C0'
            $s.Hint.Text = "No Strata here yet: the Setup tab downloads it into this folder (a few hundred MB)." + $space
        }
        default {
            $s.Go.Content = 'Continue'; $s.Go.IsEnabled = $false; $s.Hint.Foreground = '#FFC62828'
            $s.Hint.Text = $(if ($r) { 'This folder has other files and no Strata: choose a folder with Strata, or an empty one.' } else { 'Choose a folder.' })
        }
    }
}

function Get-SuggestedStrataRoot {
    # A new checkout goes to the fixed drive with the most free space (the models need 60-190 GB).
    $d = [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        Sort-Object AvailableFreeSpace -Descending | Select-Object -First 1
    return (Join-Path $d.RootDirectory.FullName 'Strata')
}

function Get-DefaultDataDir([string]$Root) {
    # Where Strata's setup puts the models: the folder it remembered (%APPDATA%\Strata\settings.json),
    # else Strata-data next to the Strata folder.
    try {
        $f = Join-Path $env:APPDATA 'Strata\settings.json'
        $s = if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json }
        if ($s.data_dir) { return [string]$s.data_dir }
    } catch {}
    if (-not $Root) { return '' }
    return (Join-Path (Split-Path -Parent $Root) 'Strata-data')
}

function Get-HardwareFacts {
    # The slow, unchanging checks: once per tab visit or "Check again".
    $f = [ordered]@{}
    $os = [Environment]::OSVersion.Version
    $f.Windows = "Windows build $($os.Build)"
    $f.WindowsOk = $os.Build -ge 19041
    $f.Gpus = @()
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        foreach ($l in @(& $smi.Source --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null)) {
            $name, $mib, $drv = ($l -split ',\s*')
            if ($name) { $f.Gpus += [pscustomobject]@{ Name = $name.Trim(); VramGB = [math]::Round([double]$mib / 1024); Driver = $drv.Trim(); Vendor = 'NVIDIA' } }
        }
    }
    if (-not $f.Gpus) {
        foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)) {
            if ($v.Name -match 'AMD|Radeon') { $f.Gpus += [pscustomobject]@{ Name = $v.Name; VramGB = 0; Driver = $v.DriverVersion; Vendor = 'AMD' } }
            elseif ($v.Name -match 'NVIDIA') { $f.Gpus += [pscustomobject]@{ Name = $v.Name; VramGB = 0; Driver = '(nvidia-smi missing)'; Vendor = 'NVIDIA' } }
        }
    }
    $f.RamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $f.Avx2 = [StrataLauncher.Cpu]::IsProcessorFeaturePresent(40)   # PF_AVX2_INSTRUCTIONS_AVAILABLE
    $f.Cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
    return [pscustomobject]$f
}

function Get-FreeGB([string]$Path) {
    try { return [math]::Round((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Path))).AvailableFreeSpace / 1GB) } catch { return $null }
}

function Get-ShortcutPaths {
    @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Strata Launcher.lnk'),
      (Join-Path ([Environment]::GetFolderPath('Programs')) 'Strata Launcher.lnk'))
}

function Get-SetupSteps {
    if (-not $script:hw) { $script:hw = Get-HardwareFacts }
    Update-EnvPath
    $hw = $script:hw
    $root = Clean-Path $ui.SetupRootBox.Text
    $data = Clean-Path $ui.SetupDataBox.Text
    $steps = New-Object System.Collections.Generic.List[object]
    $add = { param($key, $name, $state, $detail, $action, $action2)
        $running = Test-SetupRunning $key
        $steps.Add([pscustomobject]@{ Key = $key; Name = $name; State = $(if ($running) { 'running' } else { $state })
                                      Detail = $(if ($running) { 'Running in its own window...' } else { $detail }); Action = $action; Action2 = $action2 }) }

    $winget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    & $add 'winget' 'Windows and winget' $(if (-not $hw.WindowsOk) { 'bad' } elseif ($winget) { 'ok' } else { 'warn' }) `
        "$($hw.Windows); winget $(if ($winget) { 'is installed' } else { 'is missing. It is the easiest way to get Git and Node.js below (and Strata''s setup uses it for Python); without it they come as portable downloads. A new Windows account can take a few minutes to get it; Set up winget registers it now' })." `
        $(if (-not $winget) { 'Set up winget' }) $(if (-not $winget) { 'Get App Installer' })

    $g = $hw.Gpus | Select-Object -First 1
    if (-not $g) {
        & $add 'gpu' 'Graphics card and driver' 'bad' 'No NVIDIA or AMD graphics card found. Strata needs one (NVIDIA RTX 20 series or newer, or a supported Radeon), 12 GB of VRAM or more.' $null $null
    } else {
        $major = 0; [void][int]::TryParse(([string]$g.Driver -split '\.')[0], [ref]$major)
        $state = if ($g.Vendor -eq 'NVIDIA' -and $major -lt 580) { 'bad' } elseif ($g.VramGB -and $g.VramGB -lt 12) { 'warn' } else { 'ok' }
        $detail = "$($g.Name)$(if ($g.VramGB) { ", $($g.VramGB) GB VRAM" }), driver $($g.Driver)."
        if ($g.Vendor -eq 'NVIDIA' -and $major -lt 580) { $detail += ' Strata needs NVIDIA driver 580 or newer: update it, restart, then check again.' }
        elseif ($g.VramGB -and $g.VramGB -lt 12) { $detail += ' Under 12 GB of VRAM Strata runs, slowly.' }
        if (@($hw.Gpus).Count -gt 1) { $detail += " ($(@($hw.Gpus).Count) cards)" }
        & $add 'gpu' 'Graphics card and driver' $state $detail $(if ($state -eq 'bad') { 'Get the driver' }) $null
    }

    $free = if ($data) { Get-FreeGB $data } elseif ($root) { Get-FreeGB $root } else { $null }
    $state = if (-not $hw.Avx2 -or $hw.RamGB -lt 32) { 'warn' } else { 'ok' }
    if ($null -ne $free -and $free -lt 70) { $state = 'warn' }
    $detail = "$($hw.RamGB) GB RAM, $($hw.Cpu)$(if (-not $hw.Avx2) { ' (no AVX2: setup builds a slow experimental engine)' })" +
        $(if ($null -ne $free) { ", $free GB free for the model files" }) + '.'
    if ($hw.RamGB -lt 32) { $detail += ' Strata wants 32 GB of RAM or more.' }
    if ($null -ne $free -and $free -lt 70) { $detail += ' The smallest model needs ~70 GB of disk: choose a folder on a bigger drive.' }
    & $add 'pc' 'Memory, CPU and disk' $state $detail $null $null

    $git = Get-Command git -ErrorAction SilentlyContinue
    & $add 'git' 'Git' $(if ($git) { 'ok' } else { 'todo' }) `
        $(if ($git) { "$((& $git.Source --version) -replace 'git version ', 'Git ')." } else { "Not installed. It fetches and updates Strata (without it, Strata comes as a zip that cannot update itself). $(if ($winget) { 'Installs Git for Windows with winget.' } else { 'Without winget: MinGit, the portable Git from git-for-windows, for your account only.' })" }) `
        $(if (-not $git) { $(if ($winget) { 'Install Git' } else { 'Install Git (portable)' }) }) $null

    if (Test-StrataFolder $root) {
        $detail = "In $root."
        $isRepo = Test-Path -LiteralPath (Join-Path $root '.git')
        $state = 'ok'
        if ($isRepo -and $git) {
            $last = & $git.Source -C $root log -1 --format='%cd, %h' --date=short 2>$null
            if ($last) { $detail += " Last commit $last." }
            $u = Get-StrataUpdateInfo $root $git.Source
            if ($u.Behind -gt 0) { $state = 'todo'; $detail += " $($u.Behind) new commit(s) on GitHub (newest $($u.Newest)): Update runs Strata's UPDATE.bat (git pull, then the engine, Python packages and model settings it needs)." }
            elseif ($u.Checked) { $detail += ' Up to date with GitHub.' }
            elseif ($u.Error) { $detail += " Could not check GitHub for updates ($($u.Error))." }
        } elseif (-not $isRepo) {
            $detail += if ($git) { ' This copy came as a zip, so it cannot update itself: Make it updatable turns it into a git clone of Strata in place (models, settings and .venv stay as they are) and brings it up to date.' }
                else { ' This copy came as a zip, so it cannot update itself: with Git installed (below) it can be made updatable.' }
            if ($git) { $state = 'todo' }
        }
        & $add 'strata' 'Strata' $state $detail $(if ($isRepo -and $git) { 'Update' } elseif ($git) { 'Make it updatable' }) $null
    } elseif ($root -and (Test-Path -LiteralPath $root) -and @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue).Count) {
        & $add 'strata' 'Strata' 'bad' "$root exists and is not a Strata folder: choose an empty or new folder above." $null $null
    } else {
        & $add 'strata' 'Strata' 'todo' "Not downloaded. It goes to $(if ($root) { $root } else { 'the folder above' }) ($StrataRepo)." 'Download Strata' $null
    }

    $haveStrata = Test-StrataFolder $root
    $venv = $haveStrata -and (Test-Path -LiteralPath (Join-Path $root '.venv\Scripts\python.exe'))
    & $add 'check' 'Python and a PC check' $(if ($venv) { 'ok' } elseif ($haveStrata) { 'todo' } else { 'wait' }) `
        $(if ($venv) { 'Strata''s Python environment is ready.' } elseif ($haveStrata) { 'Strata''s setup installs Python for your account (if needed) and checks this PC. Nothing else is installed.' } else { 'After Strata is downloaded.' }) `
        $(if ($haveStrata) { $(if ($venv) { 'Check again' } else { 'Check this PC' }) }) $null

    $configs = if ($haveStrata) { @(Get-ChildItem -LiteralPath $root -Filter 'strata-*.json' -File | Where-Object { $_.Name -notlike '*.shared-settings.json' }) } else { @() }
    & $add 'model' 'A model' $(if ($configs.Count) { 'ok' } elseif ($venv) { 'todo' } else { 'wait' }) `
        $(if ($configs.Count) { "$($configs.Count) installed: $(($configs | ForEach-Object { $_.BaseName -replace '^strata-', '' }) -join ', ')." }
          elseif ($venv) { "Not installed. Setup downloads 58-190 GB from Hugging Face (resumable) to $(if ($data) { $data } else { 'Strata-data' }). Choose one in the catalog, or let setup pick the recommended size for this PC's RAM." }
          else { 'After the PC check.' }) `
        $(if ($venv) { 'Choose a model...' }) $(if ($venv) { 'Recommended for this PC' })

    $node = Get-Command node -ErrorAction SilentlyContinue
    $cline = Get-Command cline -ErrorAction SilentlyContinue
    if (-not $cline) { $cline = Get-Item -Path (Join-Path $env:APPDATA 'npm\cline.cmd') -ErrorAction SilentlyContinue }
    & $add 'cline' 'Node.js and Cline (optional)' $(if ($cline) { 'ok' } else { 'todo' }) `
        $(if ($cline) { "Cline is installed$(if ($node) { ", Node.js $((& $node.Source --version))" })." }
          elseif ($node) { "Node.js $((& $node.Source --version)) is installed; Cline (the coding agent Open Cline starts) is not." }
          else { 'Not installed. Open Cline needs Node.js and Cline, the coding agent it starts against the local model.' }) `
        $(if (-not $cline) { 'Install Cline' }) $null

    $lnks = @(Get-ShortcutPaths | Where-Object { Test-Path -LiteralPath $_ })
    & $add 'shortcut' 'Shortcut' $(if ($lnks.Count) { 'ok' } else { 'todo' }) `
        $(if ($lnks.Count) { "Strata Launcher is on the $(($lnks | ForEach-Object { if ($_ -like "$([Environment]::GetFolderPath('Desktop'))*") { 'desktop' } else { 'Start menu' } }) -join ' and ')." } else { 'A Strata Launcher shortcut on the desktop and in the Start menu.' }) `
        $(if (-not $lnks.Count) { 'Create shortcuts' }) $null
    return $steps
}

function Show-SetupSteps {
    $panel = $ui.SetupSteps
    $panel.Children.Clear()
    $marks = @{ ok = @([char]0x2713, '#FF2E7D32'); warn = @('!', '#FFE65100'); bad = @([char]0x2717, '#FFC62828')
                todo = @([char]0x2022, '#FF1565C0'); wait = @([char]0x2022, '#FF9E9E9E'); running = @([char]0x2026, '#FF1565C0') }
    $todo = $null
    foreach ($st in (Get-SetupSteps)) {
        if (-not $todo -and $st.State -in 'todo', 'bad') { $todo = $st }
        $g = New-Object System.Windows.Controls.Grid
        $g.Margin = '0,0,0,10'
        foreach ($w in @(26, 200)) { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $w; $g.ColumnDefinitions.Add($c) }
        $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = [System.Windows.GridLength]::new(1, 'Star'); $g.ColumnDefinitions.Add($c)
        $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = [System.Windows.GridLength]::Auto; $g.ColumnDefinitions.Add($c)
        $m = New-Object System.Windows.Controls.TextBlock
        $m.Text = $marks[$st.State][0]; $m.Foreground = $marks[$st.State][1]; $m.FontWeight = 'Bold'; $m.FontSize = 16; $m.VerticalAlignment = 'Top'
        $n = New-Object System.Windows.Controls.TextBlock
        $n.Text = $st.Name; $n.FontWeight = 'SemiBold'; $n.VerticalAlignment = 'Top'; $n.Margin = '0,2,0,0'
        [System.Windows.Controls.Grid]::SetColumn($n, 1)
        $d = New-Object System.Windows.Controls.TextBlock
        $d.Text = $st.Detail; $d.TextWrapping = 'Wrap'; $d.Margin = '0,2,12,0'; $d.Foreground = '#FF444444'
        [System.Windows.Controls.Grid]::SetColumn($d, 2)
        $bp = New-Object System.Windows.Controls.StackPanel
        $bp.Orientation = 'Horizontal'; $bp.VerticalAlignment = 'Top'
        [System.Windows.Controls.Grid]::SetColumn($bp, 3)
        foreach ($label in @($st.Action, $st.Action2)) {
            if (-not $label) { continue }
            $b = New-Object System.Windows.Controls.Button
            $b.Content = $label; $b.Tag = "$($st.Key)|$label"; $b.IsEnabled = $st.State -ne 'running'
            [System.Windows.Automation.AutomationProperties]::SetName($b, $label)
            $b.Add_Click({ param($s, $e) $k, $l = ([string]$s.Tag).Split('|', 2); Invoke-SetupAction $k $l })
            [void]$bp.Children.Add($b)
        }
        foreach ($x in @($m, $n, $d, $bp)) { [void]$g.Children.Add($x) }
        [void]$panel.Children.Add($g)
    }
    $ui.SetupNote.Text = if ($todo) { "Next: $($todo.Name)." } else { 'Everything is in place. Start a model on the Launch tab.' }
}

# Put into every setup console: the no-winget routes install portable builds for the user (no admin
# rights) and put them on the user's PATH.
$SetupConsoleHelpers = @(
    '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12'
    '$ProgressPreference = ''SilentlyContinue''   # Invoke-WebRequest is many times slower with its progress bar'
    'function Add-UserPath([string]$Dir) {'
    '    $u = [Environment]::GetEnvironmentVariable(''Path'', ''User'')'
    '    if (($u -split '';'') -notcontains $Dir) { [Environment]::SetEnvironmentVariable(''Path'', ((@($Dir) + @($u -split '';'' | Where-Object { $_ })) -join '';''), ''User''); Write-Host "Added $Dir to your PATH." }'
    '    Update-EnvPath'
    '}'
    'function Get-File([string]$Url, [string]$To) {'
    '    # Windows PowerShell''s own downloader; with its progress bar hidden ($ProgressPreference above) it is as fast as'
    '    # curl.exe (0.5 s for 39 MB here) - with the bar shown, 30 MB took over 10 minutes in a clean Windows Sandbox.'
    '    Write-Host "> download $Url"'
    '    Invoke-WebRequest -UseBasicParsing $Url -OutFile $To'
    '    Write-Host ("  {0:n1} MB" -f ((Get-Item -LiteralPath $To).Length / 1MB))'
    '}'
    'function Get-Zip([string]$Url, [string]$Into) {'
    '    $zip = Join-Path $env:TEMP ([IO.Path]::GetFileName($Url))'
    '    Get-File $Url $zip'
    '    Remove-Item -LiteralPath $Into -Recurse -Force -ErrorAction SilentlyContinue'
    '    Expand-Archive -LiteralPath $zip -DestinationPath $Into'
    '    Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue'
    '}'
)

$script:updInfo = @{}

function Get-StrataUpdateInfo([string]$Root, [string]$Git) {
    # How far the checkout is behind GitHub: a git fetch (network), so at most every 15 minutes per folder,
    # or when "Check again" clears the cache. -> @{ Checked; Behind; Newest; Error }
    $c = $script:updInfo[$Root]
    if ($c -and ((Get-Date) - $c.At).TotalMinutes -lt 15) { return $c }
    $r = @{ At = Get-Date; Checked = $false; Behind = 0; Newest = ''; Error = '' }
    $err = & $Git -C $Root fetch --quiet 2>&1 | Out-String
    if ($LASTEXITCODE) { $r.Error = ($err.Trim() -split "`n" | Select-Object -Last 1) }
    else {
        $n = & $Git -C $Root rev-list --count 'HEAD..@{u}' 2>$null
        if ($LASTEXITCODE -eq 0) {
            $r.Checked = $true; $r.Behind = [int]$n
            if ($r.Behind) { $r.Newest = (& $Git -C $Root log -1 --format=%cd --date=short '@{u}' 2>$null) }
        } else { $r.Error = 'the branch follows no remote branch' }
    }
    $script:updInfo[$Root] = $r
    return $r
}

function Get-SetupDoneFile([string]$Key) { Join-Path $TempDir "setup-$Key.done" }

function Test-SetupRunning([string]$Key) {
    # Its window is open and it has not written its done marker (the window stays open afterwards).
    $p = $script:setupProcs[$Key]
    return ($p -and -not $p.HasExited -and -not (Test-Path -LiteralPath (Get-SetupDoneFile $Key)))
}

function Start-SetupConsole([string]$Key, [string]$Title, [string]$Body) {
    # A visible PowerShell window that shows each command, runs it, and stays open with the result.
    if (-not (Test-Path -LiteralPath $TempDir)) { New-Item -ItemType Directory -Path $TempDir | Out-Null }
    $file = Join-Path $TempDir "setup-$Key.ps1"
    $done = Get-SetupDoneFile $Key
    Remove-Item -LiteralPath $done -ErrorAction SilentlyContinue
    $transcript = Join-Path $TempDir "setup-$Key.log"
    $text = "`$Host.UI.RawUI.WindowTitle = '$($Title -replace "'", "''")'`r`n`$ErrorActionPreference = 'Continue'`r`n" +
        "try { Start-Transcript -LiteralPath '$($transcript -replace "'", "''")' -Force | Out-Null } catch {}`r`n" +
        "function Update-EnvPath { `$m = [Environment]::GetEnvironmentVariable('Path', 'Machine'); `$u = [Environment]::GetEnvironmentVariable('Path', 'User'); `$env:Path = (@(`$m, `$u) | Where-Object { `$_ }) -join ';' }`r`n" +
        ($SetupConsoleHelpers -join "`r`n") + "`r`n" +
        # the done marker is written whatever happens, so the tab never waits on a step that failed:
        # "ok" or "failed: <reason>", which the tab shows in its status line
        "`$stepResult = 'ok'`r`ntry {`r`n" + $Body + "`r`n    if (`$LASTEXITCODE) { throw ""exit code `$LASTEXITCODE"" }`r`n} catch {`r`n    `$stepResult = 'failed: ' + `$_.Exception.Message`r`n" +
        "    Write-Host ''`r`n    Write-Host `$stepResult -ForegroundColor Red`r`n} finally {`r`n" +
        "    Set-Content -LiteralPath '$($done -replace "'", "''")' -Value `$stepResult`r`n    try { Stop-Transcript | Out-Null } catch {}`r`n}`r`n" +
        "Write-Host ''`r`nWrite-Host `$(if (`$stepResult -eq 'ok') { 'Done. This window can be closed; the Setup tab checks again by itself.' } else { 'This step failed (above). The window can be closed; the Setup tab offers it again.' }) -ForegroundColor `$(if (`$stepResult -eq 'ok') { 'Green' } else { 'Yellow' })`r`n"
    [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding $true))   # with a BOM: Windows PowerShell reads it as UTF-8
    $script:setupProcs[$Key] = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -File $(QPath $file)" -PassThru
    Show-SetupSteps
}

function Confirm-Setup([string]$Text) { return ([System.Windows.MessageBox]::Show($Text, 'Strata setup', 'OKCancel') -eq 'OK') }

function Use-SetupFolders {
    # The Setup tab's folders become the GUI's: the Strata folder everything else reads, and the model folder.
    $root = Clean-Path $ui.SetupRootBox.Text
    $data = Clean-Path $ui.SetupDataBox.Text
    if ($data) { $ui.DataBox.Text = $data; Set-StrataReg 'DataDir' $data }
    # also when it is the same folder: Strata may have just arrived in it (or its configs with a model)
    if (Test-StrataFolder $root) {
        if ($root -ne (Clean-Path $ui.RootBox.Text)) { $ui.RootBox.Text = $root }
        Read-Configs; Update-CtxHint; Update-SessionList; Update-ServicePicker; Read-Results
        $script:catalog = $null
    }
}

function Invoke-SetupAction([string]$Key, [string]$Label) {
    $root = Clean-Path $ui.SetupRootBox.Text
    $data = Clean-Path $ui.SetupDataBox.Text
    $winget = 'winget install --exact --source winget --accept-package-agreements --accept-source-agreements --id'   # script text, run as written
    switch ("$Key|$Label") {
        'winget|Get App Installer' { Start-Process 'ms-windows-store://pdp/?productid=9NBLGGH4NNS1' }
        'winget|Set up winget' {
            # Microsoft's two documented routes (learn.microsoft.com/windows/package-manager/winget): register the
            # App Installer that Windows ships (a new account gets it a few minutes after its first sign-in), and on
            # Windows without the Store (Windows Sandbox, LTSC) install it with the Microsoft.WinGet.Client module.
            if (-not (Confirm-Setup "Set up winget for your account?`n`n1. Register Windows' own App Installer (Add-AppxPackage -RegisterByFamilyName).`n2. If that does not do it: install Microsoft's Microsoft.WinGet.Client module from the PowerShell Gallery for your account and run its Repair-WinGetPackageManager, which downloads winget from Microsoft.")) { return }
            Start-SetupConsole 'winget' 'Setting up winget' (@(
                'Write-Host ''> Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'''
                'try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }'
                'Update-EnvPath'
                'if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {'
                '    Write-Host ''> Install-Module Microsoft.WinGet.Client -Scope CurrentUser; Repair-WinGetPackageManager'''
                '    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null'
                '    Install-Module -Name Microsoft.WinGet.Client -Force -Scope CurrentUser -Repository PSGallery -AllowClobber'
                '    Import-Module Microsoft.WinGet.Client'
                '    Repair-WinGetPackageManager -Latest -Force'
                '    Update-EnvPath'
                '}'
                'if (Get-Command winget -ErrorAction SilentlyContinue) { Write-Host "winget $(winget --version) is ready." -ForegroundColor Green }'
                'else { Write-Host ''winget is still not available: install App Installer from the Microsoft Store, or use the portable downloads in the Setup tab.'' -ForegroundColor Yellow }'
            ) -join "`r`n")
        }
        'gpu|Get the driver' {
            $vendor = ($script:hw.Gpus | Select-Object -First 1).Vendor
            Start-Process $(if ($vendor -eq 'AMD') { 'https://www.amd.com/en/support/download/drivers.html' } else { 'https://www.nvidia.com/en-us/drivers/' })
        }
        'git|Install Git' {
            if (-not (Confirm-Setup "Install Git for Windows with winget (Git.Git, ~60 MB)?`n`nWindows may ask for permission.")) { return }
            Start-SetupConsole 'git' 'Installing Git' "Write-Host '> $winget Git.Git'`r`n$winget Git.Git"
        }
        'git|Install Git (portable)' {
            if (-not (Confirm-Setup "Install MinGit, the portable Git from git-for-windows (GitHub, ~40 MB), for your account?`n`nIt goes to $env:LOCALAPPDATA\Programs\MinGit and onto your PATH; no administrator rights, no installer.")) { return }
            Start-SetupConsole 'git' 'Installing Git (portable)' (@(
                '$rel = Invoke-RestMethod -UseBasicParsing https://api.github.com/repos/git-for-windows/git/releases/latest'
                '$asset = $rel.assets | Where-Object { $_.name -match ''^MinGit-[\d\.]+-64-bit\.zip$'' } | Select-Object -First 1'
                'if (-not $asset) { throw ''No MinGit 64-bit zip in the latest Git for Windows release.'' }'
                'Write-Host "MinGit $($rel.tag_name)"'
                '$dir = Join-Path $env:LOCALAPPDATA ''Programs\MinGit'''
                'Get-Zip $asset.browser_download_url $dir'
                'Add-UserPath (Join-Path $dir ''cmd'')'
                'git --version'
            ) -join "`r`n")
        }
        'strata|Download Strata' {
            if (-not $root) { Set-Status 'Choose a folder for Strata first.'; return }
            $git = Get-Command git -ErrorAction SilentlyContinue
            $how = if ($git) { "git clone $StrataRepo.git" } else { 'the zip of its main branch (Git is not installed, so it cannot update itself later)' }
            if (-not (Confirm-Setup "Download Strata into`n$root`n`nusing $how. It is a few hundred MB; the model comes later.")) { return }
            $q = $root -replace "'", "''"
            $body = if ($git) {
                "Write-Host '> git clone $StrataRepo.git `"$q`"'`r`n& git clone '$StrataRepo.git' '$q'"
            } else {
                "`$zip = Join-Path `$env:TEMP 'strata-main.zip'; `$tmp = Join-Path `$env:TEMP 'strata-main'`r`n" +
                "Get-File '$StrataRepo/archive/refs/heads/main.zip' `$zip`r`n" +
                "Remove-Item `$tmp -Recurse -Force -ErrorAction SilentlyContinue; Expand-Archive `$zip `$tmp`r`n" +
                "New-Item -ItemType Directory -Force '$q' | Out-Null`r`n" +
                "Get-ChildItem (Get-ChildItem `$tmp -Directory | Select-Object -First 1).FullName -Force | Move-Item -Destination '$q'`r`n" +
                "Remove-Item `$zip, `$tmp -Recurse -Force -ErrorAction SilentlyContinue; Write-Host 'Unpacked into $q'"
            }
            Start-SetupConsole 'strata' 'Downloading Strata' $body
        }
        'strata|Make it updatable' {
            $msg = "Make $root a git clone of $StrataRepo, then update it?`n`n" +
                "Its Strata files become the newest version from GitHub; files git does not track (models, strata-*.json configs, .venv, logs) are left as they are. Then Strata's UPDATE.bat brings the engine and packages up to date. Stop its servers first."
            if (-not (Confirm-Setup $msg)) { return }
            $script:updInfo.Remove($root)
            Start-SetupConsole 'strata' 'Making Strata updatable' (@(
                "Set-Location -LiteralPath '$($root -replace "'", "''")'"
                'Write-Host ''> git init; git remote add origin; git fetch origin main; git reset origin/main; git checkout -- .'''
                '& git init --quiet --initial-branch=main'
                "& git remote add origin '$StrataRepo.git'"
                '& git fetch --quiet origin main; if ($LASTEXITCODE) { throw ''git fetch failed'' }'
                '# the branch and index become origin/main; tracked files are then brought to it, untracked ones stay'
                '& git reset --quiet origin/main'
                '& git branch --quiet --set-upstream-to=origin/main main'
                '& git checkout -- .'
                'Write-Host ''> UPDATE.bat'''
                '$null | & cmd.exe /c UPDATE.bat | Out-Host'
            ) -join "`r`n")
        }
        'strata|Update' {
            if (-not (Confirm-Setup "Update Strata in $root with its own UPDATE.bat?`n`nIt runs git pull, then gets the engine, Python packages and model settings the new version needs. The model files are not touched. Stop its servers first.")) { return }
            $script:updInfo.Remove($root)
            # stdin from nothing: UPDATE.bat ends with "pause", which then returns at once
            Start-SetupConsole 'strata' 'Updating Strata' "Set-Location -LiteralPath '$($root -replace "'", "''")'`r`nWrite-Host '> UPDATE.bat'`r`n`$null | & cmd.exe /c UPDATE.bat | Out-Host"
        }
        { $_ -in 'check|Check this PC', 'check|Check again' } {
            if (-not (Confirm-Setup "Run Strata's setup check (START-HERE.bat --check) in`n$root`n`nWithout a Python for Strata yet, it first gets uv (astral.sh, one small program, into $env:LOCALAPPDATA\Programs\uv), which downloads a standalone Python and creates Strata's .venv with it: no installer, nothing system-wide. Then START-HERE.bat installs Strata's packages and prints what this PC can run. It downloads no model.")) { return }
            # The Python version Strata pins, read from this START-HERE.bat so a new pin is followed.
            $pyVer = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'START-HERE.bat') -Raw -ErrorAction SilentlyContinue),
                'python-(3\.\d+\.\d+)-amd64\.exe').Groups[1].Value
            if (-not $pyVer) { $pyVer = '3.12' }
            # START-HERE.bat skips its own Python install when .venv\Scripts\python.exe exists (or the python\ folder
            # of Strata's Terminal archive). Its own route - winget, or python.org's installer - is many Windows
            # Installer packages, each one waiting minutes on a new PC; uv fetches a standalone Python in seconds.
            # When uv does not work out, the half-made .venv goes and START-HERE.bat installs Python its own way.
            $pre = @(
                "Set-Location -LiteralPath '$($root -replace "'", "''")'"
                'if (-not (Test-Path ''python\python.exe'') -and -not (Test-Path ''.venv\Scripts\python.exe'')) {'
                '    try {'
                '        $uv = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source'
                '        if (-not $uv) {'
                '            $uvDir = Join-Path $env:LOCALAPPDATA ''Programs\uv'''
                '            $uv = Join-Path $uvDir ''uv.exe'''
                '            if (-not (Test-Path -LiteralPath $uv)) {'
                '                Write-Host ''Getting uv (astral.sh), which sets up Python for Strata:'''
                '                $url = ''https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip'''
                '                $zip = Join-Path $env:TEMP ''uv-x86_64-pc-windows-msvc.zip'''
                '                Get-File $url $zip'
                '                Invoke-WebRequest -UseBasicParsing "$url.sha256" -OutFile "$zip.sha256"'
                '                $want = ((Get-Content -LiteralPath "$zip.sha256" -Raw).Trim() -split ''\s+'')[0]'
                '                if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $want) { throw ''the uv download does not match its published SHA-256'' }'
                '                Expand-Archive -LiteralPath $zip -DestinationPath $uvDir -Force'
                '                Remove-Item -LiteralPath $zip, "$zip.sha256" -ErrorAction SilentlyContinue'
                '            }'
                '        }'
                "        Write-Host '> uv venv --seed --python $pyVer .venv'"
                "        & `$uv venv --seed --python '$pyVer' .venv"
                '        if ($LASTEXITCODE) { throw "uv ended with $LASTEXITCODE" }'
                '    } catch {'
                '        Write-Host "uv could not set up Python ($($_.Exception.Message)); START-HERE.bat installs it its own way." -ForegroundColor Yellow'
                '        Remove-Item -LiteralPath ''.venv'' -Recurse -Force -ErrorAction SilentlyContinue'
                '    }'
                '}'
            ) -join "`r`n"
            Start-SetupConsole 'check' 'Strata: checking this PC' ($pre + "`r`nWrite-Host '> START-HERE.bat --check'`r`n`$null | & cmd.exe /c START-HERE.bat --check | Out-Host")
        }
        'model|Choose a model...' {
            Use-SetupFolders
            $ui.Tabs.SelectedItem = $ui.ModelsTab
            Read-Catalog
        }
        'model|Recommended for this PC' {
            $extra = if ($data -and $data -ne $root) { " --data-dir `"$data`"" } else { '' }
            $extraPs = if ($extra) { " --data-dir '$($data -replace "'", "''")'" } else { '' }
            $msg = "Run Strata's setup with its recommended model for this PC's RAM (START-HERE.bat --yes --no-start$extra)?`n`n" +
                "It downloads 58-190 GB from Hugging Face into $(if ($data) { $data } else { 'Strata-data' }); that can take hours, and it continues where it stopped if interrupted."
            if (-not (Confirm-Setup $msg)) { return }
            Use-SetupFolders
            Start-SetupConsole 'model' 'Strata: installing the recommended model' "Set-Location -LiteralPath '$($root -replace "'", "''")'`r`nWrite-Host '> START-HERE.bat --yes --no-start$($extra -replace "'", "''")'`r`n`$null | & cmd.exe /c START-HERE.bat --yes --no-start$extraPs | Out-Host"
        }
        'cline|Install Cline' {
            $node = Get-Command node -ErrorAction SilentlyContinue
            $haveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
            $nodeHow = if ($node) { '' } elseif ($haveWinget) { 'Node.js LTS (winget, OpenJS.NodeJS.LTS) and ' }
                else { "Node.js LTS (the portable zip from nodejs.org, into $env:LOCALAPPDATA\Programs\nodejs and onto your PATH) and " }
            if (-not (Confirm-Setup "Install $($nodeHow)Cline (npm install -g cline) for your account?")) { return }
            $body = ''
            if (-not $node -and $haveWinget) { $body += "Write-Host '> $winget OpenJS.NodeJS.LTS'`r`n$winget OpenJS.NodeJS.LTS`r`nUpdate-EnvPath`r`n" }
            elseif (-not $node) {
                $body += (@(
                    '# the newest LTS release, as nodejs.org lists it'
                    '# into a variable first: piped straight on, Windows PowerShell passes the whole JSON array as one object'
                    '$releases = Invoke-RestMethod -UseBasicParsing https://nodejs.org/dist/index.json'
                    '$v = ($releases | Where-Object { $_.lts } | Select-Object -First 1).version'
                    'if ($v -notmatch ''^v\d+\.\d+\.\d+$'') { throw "Unexpected Node.js version from nodejs.org: $v" }'
                    'Write-Host "Node.js $v (LTS)"'
                    '$base = Join-Path $env:LOCALAPPDATA ''Programs'''
                    'Get-Zip "https://nodejs.org/dist/$v/node-$v-win-x64.zip" (Join-Path $base ''nodejs-unpack'')'
                    'Remove-Item -LiteralPath (Join-Path $base ''nodejs'') -Recurse -Force -ErrorAction SilentlyContinue'
                    'Move-Item -LiteralPath (Join-Path $base "nodejs-unpack\node-$v-win-x64") -Destination (Join-Path $base ''nodejs'')'
                    'Remove-Item -LiteralPath (Join-Path $base ''nodejs-unpack'') -Recurse -Force'
                    'Add-UserPath (Join-Path $base ''nodejs'')'
                    'Add-UserPath (Join-Path $env:APPDATA ''npm'')   # where npm install -g puts cline'
                    'node --version'
                ) -join "`r`n") + "`r`n"
            }
            $body += "Write-Host '> npm install -g cline'`r`n& npm install -g cline | Out-Host"
            Start-SetupConsole 'cline' 'Installing Cline' $body
        }
        'shortcut|Create shortcuts' {
            $ws = New-Object -ComObject WScript.Shell
            foreach ($path in (Get-ShortcutPaths)) {
                $l = $ws.CreateShortcut($path)
                $l.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                $l.Arguments = "-NoProfile -WindowStyle Hidden -STA -ExecutionPolicy Bypass -File $(QPath $PSCommandPath)"
                $l.WorkingDirectory = $PSScriptRoot
                $l.WindowStyle = 7
                $l.Description = 'Launch, benchmark and set up Strata models'
                $l.IconLocation = $(if (Test-Path -LiteralPath $AppIcon) { "$AppIcon,0" } else { "$env:SystemRoot\System32\imageres.dll,144" })
                $l.Save()
                # the same shortcut under this tool's earlier name
                Remove-Item -LiteralPath (Join-Path (Split-Path $path -Parent) 'Strata GUI.lnk') -ErrorAction SilentlyContinue
            }
            Set-Status 'Created Strata Launcher shortcuts on the desktop and in the Start menu.'
        }
    }
    Show-SetupSteps
}

function Update-SetupWatch {
    # Re-check when a setup window finishes, and now and then while the tab is open.
    $done = @($script:setupProcs.Keys | Where-Object { -not (Test-SetupRunning $_) })
    $failed = $null
    foreach ($k in $done) {
        $script:setupProcs.Remove($k)
        $result = Get-Content -LiteralPath (Get-SetupDoneFile $k) -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($result -like 'failed:*') { $failed = "Setup step '$k' $result (its window has the details)." }
        # a look at GitHub taken while the step ran (no clone or upstream yet) is out of date now
        if ($k -eq 'strata') { $script:updInfo = @{} }
    }
    if ($done.Count -or ($ui.Tabs.SelectedItem -eq $ui.SetupTab -and $script:svcTick % 10 -eq 0)) {
        if ($done -contains 'strata' -or $done -contains 'check' -or $done -contains 'model') { Use-SetupFolders }
        if ($ui.Tabs.SelectedItem -eq $ui.SetupTab) { Show-SetupSteps }
    }
    if ($failed) { Set-Status $failed }   # after the re-read above, which sets its own status
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
    @{ Flag = '--suffix-draft'; Kind = 'int'; Min = 0; Max = 16; Help = 'Prompt lookup: also draft from an earlier repeat of the last N+ tokens of context, which pays off on code edits and quoted text (engine default 3; 0 = MTP drafts only).' }
    @{ Flag = '--lookup-chain'; Kind = 'int'; Min = 0; Max = 8; Help = 'Opt-in: after the MTP drafts, add up to K prompt-lookup drafts that continue them (the window grows to at most 8; default 0 = off).' }
    @{ Flag = '--lookup-chain-min'; Kind = 'int'; Min = 1; Help = 'The shortest context match --lookup-chain extends on (default 3).' }
    @{ Flag = '--mtp-max-t'; Kind = 'int'; Min = 0; Max = 8; Help = 'Cap the MTP draft windows at M tokens (0 = --spec); longer windows then come from prompt lookup only.' }
    @{ Flag = '--mtp-window'; Kind = 'int'; Min = 0; Help = 'Cells of context the draft layer attends to (default 32768). Smaller saves VRAM; Strata measured that it costs acceptance on faster cards.' }
    @{ Flag = '--mtp-hnorm'; Kind = 'enum'; Choices = @('pooled', 'stream'); Help = 'The draft layer''s input norm: pooled (default, one over all four streams) or stream (one per stream, as llama.cpp does; Strata measured +4% decode on a DGX Spark).' }
    @{ Flag = '--mtp-q4'; Kind = 'enum'; Choices = @('all', 'proj', 'head'); Help = 'Opt-in: the draft layer''s projections and/or head as 4-bit copies, for less VRAM. Every draft is still checked, so answers do not change (+3.5% decode on a DGX Spark, neutral on a Radeon 780M).' }
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
    @{ Flag = '--mtp-draft-vocab'; Help = 'The draft head''s token subset (default: draft_vocab.bin in the --mtp folder). Strata''s tools\draft_vocab.py builds others; English and code only saves ~110 MiB of VRAM.' }
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
            Ram       = Get-CatalogRamText $m $cat
            RamFit    = $ramFit
            DiskFit   = $diskFit
            Installed = $(if ($isInstalled) { 'yes' } else { '' })
            Key       = ('{0}-{1}' -f $m.name, $m.quant).ToLower()   # the installed config's model name
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

# The Strata folder: -StrataRoot when given, then the registered one (HKCU\Software\StrataLauncher) while it
# is still a checkout, then the one an older version saved in its settings file; with none, the first-run
# dialog asks: an existing checkout, or a fresh install that the Setup tab carries out.
$firstChoice = $null
$foundRoot = foreach ($c in @($StrataRoot, (Get-StrataReg 'StrataRoot'), [string]$settings.StrataRoot)) { if ($c -and (Test-StrataFolder (Clean-Path $c))) { Clean-Path $c; break } }
if ($FirstRun) { $foundRoot = $null }
if (-not $foundRoot -and -not $StrataRoot) {
    $firstChoice = Show-FirstRunDialog
    if ($firstChoice -and $firstChoice.Mode -eq 'existing') { $foundRoot = $firstChoice.Root }
}
$ui.SetupRootBox.Text = $(if ($foundRoot) { $foundRoot } elseif ($firstChoice) { $firstChoice.Root } else { Get-SuggestedStrataRoot })
$ui.RootBox.Text = $ui.SetupRootBox.Text   # never empty: everything joins paths onto it
$ui.FolderBox.Text = $settings.ClineFolder
$ui.ClineScriptBox.Text = $settings.ClineScript
$ui.ExtraBox.Text = $settings.ExtraArgs
$ui.VramBox.Text = $settings.VramReserve
$ui.FitChk.IsChecked = [bool]$settings.FitMaxTokens
# MTP overrides start at the config's own settings every time: a forgotten "off" would quietly slow every run
$ui.MtpBox.ItemsSource = @('(config)', 'on', 'off (prompt lookup only)'); $ui.MtpBox.SelectedIndex = 0
$ui.SpecBox.ItemsSource = @('(config)') + @(1..8 | ForEach-Object { [string]$_ }); $ui.SpecBox.SelectedIndex = 0
foreach ($v in @('2', '5', '10', '15', '20')) { [void]$ui.ReserveBox.Items.Add($v) }
if (-not $settings.HeadroomV2) {
    if ([string]$settings.ReservePercent -eq '10') { $settings.ReservePercent = '2' }   # the old default, not a choice
    $settings.HeadroomV2 = $true
}
$ui.ReserveBox.SelectedItem = $(if (@('2', '5', '10', '15', '20') -contains [string]$settings.ReservePercent) { [string]$settings.ReservePercent } else { '2' })
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
    $p = Select-Folder (Get-Root) 'Select the Strata folder: one with Strata, or an empty one to download it into'
    if (-not $p) { return }
    switch (Get-FolderState $p) {
        'strata' { $ui.RootBox.Text = $p; $ui.SetupRootBox.Text = $p; Read-Configs; Update-ServicePicker; Read-Results }
        'empty' {
            # no Strata there yet: the Setup tab downloads it into this folder
            $ui.SetupRootBox.Text = $p
            $ui.Tabs.SelectedItem = $ui.SetupTab
            Invoke-SetupAction 'strata' 'Download Strata'
        }
        default { [System.Windows.MessageBox]::Show("$p has other files and no Strata. Choose a folder with Strata, or an empty one to download it into.", 'Strata') | Out-Null }
    }
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
$ui.RemoveModelBtn.Add_Click({
    $row = Get-Selected
    if ($row) { Remove-Model $row }
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
    if ($e.OriginalSource -eq $ui.Tabs -and $ui.Tabs.SelectedItem -eq $ui.SetupTab) { Show-SetupSteps }
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
    $ui.CatRemoveBtn.IsEnabled = [bool]($row -and $row.Installed)
})
$ui.InstallBtn.Add_Click({ Install-CatalogModel })
$ui.CatRemoveBtn.Add_Click({
    $row = $ui.CatalogList.SelectedItem
    if (-not $row -or -not $row.Installed) { return }
    $cfg = $script:configs | Where-Object { $_.Model.ToLower() -eq $row.Key } | Select-Object -First 1
    if (-not $cfg) { Set-Status "No config for $($row.Title) $($row.Quant) in this Strata folder; press Refresh."; return }
    Remove-Model $cfg
})

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

$ui.SetupRootBrowse.Add_Click({
    $p = Select-Folder (Clean-Path $ui.SetupRootBox.Text) 'Choose the Strata folder (an existing checkout, or an empty folder for a new one)'
    if ($p) { $ui.SetupRootBox.Text = $p; if (-not $ui.SetupDataBox.Text.Trim()) { $ui.SetupDataBox.Text = Get-DefaultDataDir $p }; Use-SetupFolders; Show-SetupSteps }
})
$ui.SetupDataBrowse.Add_Click({
    $p = Select-Folder (Clean-Path $ui.SetupDataBox.Text) 'Choose where the model files go (60-190 GB)'
    if ($p) { $ui.SetupDataBox.Text = $p; Use-SetupFolders; Show-SetupSteps }
})
$ui.SetupRootBox.Add_LostFocus({ Use-SetupFolders; Show-SetupSteps })
$ui.SetupDataBox.Add_LostFocus({ Use-SetupFolders; Show-SetupSteps })
$ui.SetupRefreshBtn.Add_Click({ $script:hw = $null; $script:updInfo = @{}; Show-SetupSteps })

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
        Update-SetupWatch
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

$ui.SetupDataBox.Text = $(if ($firstChoice -and $firstChoice.Data) { $firstChoice.Data } elseif (Get-StrataReg 'DataDir') { Get-StrataReg 'DataDir' }
    elseif ($settings.DataFolder) { [string]$settings.DataFolder } else { Get-DefaultDataDir (Clean-Path $ui.SetupRootBox.Text) })
if (-not $ui.DataBox.Text.Trim()) { $ui.DataBox.Text = $ui.SetupDataBox.Text }
if ($foundRoot) { Set-StrataReg 'StrataRoot' $foundRoot }
Set-StrataReg 'AppDir' $PSScriptRoot
if (-not $foundRoot) {
    $ui.Tabs.SelectedItem = $ui.SetupTab
    Set-Status 'No Strata folder found yet: the Setup tab gets everything it needs.'
}
Read-Configs
Update-CtxHint
Update-SessionList
Update-ServicePicker
Read-Results
Update-Health
if ($firstChoice -and $firstChoice.Mode -eq 'fresh') {
    # "Download Strata here": start that step once the window is up (it confirms first, as always)
    $window.Add_ContentRendered({
        if ($script:freshPending) { $script:freshPending = $false; Invoke-SetupAction 'strata' 'Download Strata' }
    })
    $script:freshPending = $true
}
$timer.Start()
[void]$window.ShowDialog()
