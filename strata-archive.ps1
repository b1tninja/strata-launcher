# Strata Launcher's model archive (docs/model-archive.md): every unique file once under blobs\<sha256>, each model as
# hard links under models\<tag>\files\ (laid out as under Strata's model files folder) and a models\<tag>\model.json.
# strata-launcher.ps1 dot-sources this for the quick parts (states, plans, deleting) and runs it in a console window
# for the long copies:
#   strata-archive.ps1 -ArcAction Copy|Ingest|Install|Delete -ArcRoot <archive> -ArcTag <tag> -ArcData <model files folder>
#                      [-ArcStrata <Strata folder>] [-ArcConfig <strata-*.json>] [-ArcFiles <json list of paths>]
# Copy: an installed model into the archive (the installed copy stays); Ingest: the same, moving the files (setup
# downloaded them into the archive drive); Install: from the archive into the model files folder, with its config.
# Parameter names are this script's own: dot-sourcing must not overwrite the launcher's variables.
param([string]$ArcAction, [string]$ArcRoot, [string]$ArcTag, [string]$ArcData, [string]$ArcStrata, [string]$ArcConfig,
      [string]$ArcFiles)

$ArchiveSkip = '\.(done|part|partial|chunks|src|bak)$'   # setup's marks and unfinished downloads are never archived

function Get-ArchiveSha([string]$Path) {
    # A file's SHA-256: from setup's finish mark when it has one (setup checked the file against the published hash and
    # wrote "sha256 <hash>" into <file>.done), else hashed here.
    $m = "$Path.done"
    if (Test-Path -LiteralPath $m) {
        $t = Get-Content -LiteralPath $m -Raw -ErrorAction SilentlyContinue
        if ($t -match 'sha256 ([0-9a-fA-F]{64})') { return $Matches[1].ToLower() }
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Get-RelPath([string]$Base, [string]$Path) {
    # $Path below $Base -> its relative path, else $null. Case-insensitive, as Windows paths are.
    $b = [IO.Path]::GetFullPath($Base).TrimEnd('\') + '\'
    $p = [IO.Path]::GetFullPath($Path)
    if ($p.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)) { return $p.Substring($b.Length) }
    return $null
}

function Get-ArchiveFiles([string[]]$Paths, [string]$DataDir, [string]$StrataRoot) {
    # The files to archive for a model, from the paths Strata says it uses (files and folders): those in the model files
    # folder, each with its path relative to it. Files in the Strata folder come with Strata (the engine, the expert
    # profile) and are left out; anything else is reported as External (kept where it is, named in model.json).
    $seen = @{}
    $out = @()
    foreach ($p in $Paths) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $items = if (Test-Path -LiteralPath $p -PathType Container) { @(Get-ChildItem -LiteralPath $p -Recurse -File -Force) } else { @(Get-Item -LiteralPath $p -Force) }
        foreach ($i in $items) {
            if ($i.Name -match $ArchiveSkip -or $seen[$i.FullName.ToLower()]) { continue }
            $seen[$i.FullName.ToLower()] = $true
            $rel = Get-RelPath $DataDir $i.FullName
            if ($rel) { $out += [pscustomobject]@{ Path = $i.FullName; Rel = $rel; Size = $i.Length; External = $false } }
            elseif ($StrataRoot -and (Get-RelPath $StrataRoot $i.FullName)) { continue }
            else { $out += [pscustomobject]@{ Path = $i.FullName; Rel = $null; Size = $i.Length; External = $true } }
        }
    }
    return $out
}

function Copy-Verified([string]$Src, [string]$Dst, [string]$Sha) {
    # Copy, then check the copy's SHA-256 before it takes its name: a copy goes through RAM, and unstable RAM corrupts
    # copies without an error. One retry; then it stops with the reason.
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dst) | Out-Null
    $tmp = "$Dst.partial"
    for ($try = 1; $try -le 2; $try++) {
        Copy-Item -LiteralPath $Src -Destination $tmp -Force
        $got = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
        if ($got -eq $Sha) {
            if (Test-Path -LiteralPath $Dst) { Remove-Item -LiteralPath $Dst -Force }
            Rename-Item -LiteralPath $tmp -NewName (Split-Path -Leaf $Dst)
            return
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    throw "the copy of $Src came out different from the original twice (SHA-256 $got, expected $Sha): check the RAM (memtest86+) and the drives"
}

function New-HardLink([string]$Link, [string]$Target) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Link) | Out-Null
    if (Test-Path -LiteralPath $Link) { Remove-Item -LiteralPath $Link -Force }
    New-Item -ItemType HardLink -Path $Link -Value $Target | Out-Null
}

function Test-SameVolume([string]$A, [string]$B) {
    [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($A)) -eq [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($B))
}

function Get-ArchiveIndex([string]$Root) {
    # -> every archived model: model.json's content plus Tag and Bytes (the model's size, counting shared files).
    $dir = Join-Path $Root 'models'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    @(Get-ChildItem -LiteralPath $dir -Directory | ForEach-Object {
        $f = Join-Path $_.FullName 'model.json'
        if (Test-Path -LiteralPath $f) {
            try {
                $m = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
                $m | Add-Member -NotePropertyName Tag -NotePropertyValue $_.Name -Force
                $m | Add-Member -NotePropertyName Bytes -NotePropertyValue ([int64](@($m.files) | Measure-Object size -Sum).Sum) -Force
                $m
            } catch {}
        } })
}

function Get-ArchiveSummary([string]$Root) {
    # -> @{ Models; Bytes (on disk: each blob once); Logical (the models' sizes added up) }: Logical - Bytes is what
    # deduplication saves.
    $blobs = Join-Path $Root 'blobs'
    $bytes = if (Test-Path -LiteralPath $blobs) { [int64](Get-ChildItem -LiteralPath $blobs -File | Where-Object { $_.Name -notmatch $ArchiveSkip } | Measure-Object Length -Sum).Sum } else { 0 }
    $idx = @(Get-ArchiveIndex $Root)
    [pscustomobject]@{ Models = $idx.Count; Bytes = $bytes; Logical = [int64]($idx | Measure-Object Bytes -Sum).Sum }
}

function Get-ArchivePlan([string]$Root, $Files) {
    # -> @{ New; Have; Total } bytes: what copying these files would add to the archive and what it already holds.
    # Files without a finish mark are not hashed here (that is the copy's job) and count as new.
    $new = 0L; $have = 0L
    foreach ($f in @($Files | Where-Object { -not $_.External })) {
        $sha = $null
        $m = "$($f.Path).done"
        if (Test-Path -LiteralPath $m) { $t = Get-Content -LiteralPath $m -Raw -ErrorAction SilentlyContinue; if ($t -match 'sha256 ([0-9a-fA-F]{64})') { $sha = $Matches[1].ToLower() } }
        if ($sha -and (Test-Path -LiteralPath (Join-Path $Root "blobs\$sha"))) { $have += $f.Size } else { $new += $f.Size }
    }
    [pscustomobject]@{ New = $new; Have = $have; Total = $new + $have }
}

function Add-ArchiveModel([string]$Root, [string]$Tag, $Files, $Config, [string]$DataDir, [switch]$Move, [scriptblock]$Say = { param($t) }) {
    # Into the archive: each file's content once in blobs\, linked under models\<Tag>\files\<rel>, then model.json.
    # -Move takes the files instead of copying them (same drive only: setup downloaded them into the archive).
    # -> @{ Copied; Linked } bytes.
    $blobs = Join-Path $Root 'blobs'
    New-Item -ItemType Directory -Force -Path $blobs | Out-Null
    $copied = 0L; $linked = 0L
    $list = @()
    $inData = @($Files | Where-Object { $_ -and -not $_.External })   # (not $files: PowerShell names ignore case)
    if (-not $inData.Count) { throw "no model files found in $DataDir to archive" }
    $n = 0
    foreach ($f in $inData) {
        $n++
        & $Say ("[{0}/{1}] {2} ({3:n1} GB)" -f $n, $inData.Count, $f.Rel, ($f.Size / 1e9))
        $sha = Get-ArchiveSha $f.Path
        $blob = Join-Path $blobs $sha
        if (Test-Path -LiteralPath $blob) {
            $linked += $f.Size
            & $Say '        already in the archive: linked'
            if ($Move) { Remove-Item -LiteralPath $f.Path -Force }
        } elseif ($Move -and (Test-SameVolume $f.Path $blob)) {
            Move-Item -LiteralPath $f.Path -Destination $blob
            $copied += $f.Size
        } else {
            Copy-Verified $f.Path $blob $sha
            $copied += $f.Size
            & $Say '        copied and checked'
        }
        New-HardLink (Join-Path $Root "models\$Tag\files\$($f.Rel)") $blob
        $list += [ordered]@{ rel = $f.Rel; size = $f.Size; sha256 = $sha }
    }
    # The config with the model files folder written as {data}, so it installs into any folder.
    $cfgText = if ($Config) { ($Config | ConvertTo-Json -Depth 20) } else { '' }
    if ($cfgText -and $DataDir) {
        $esc = ([IO.Path]::GetFullPath($DataDir).TrimEnd('\')) -replace '\\', '\\'
        $cfgText = [regex]::Replace($cfgText, [regex]::Escape($esc), '{data}', 'IgnoreCase')
    }
    $doc = [ordered]@{
        schema = 1; tag = $Tag; model_name = $(if ($Config) { [string]$Config.model_name } else { $Tag })
        archived = (Get-Date).ToString('s'); files = $list
        external = @($Files | Where-Object { $_.External } | ForEach-Object { $_.Path })
        config = $(if ($cfgText) { $cfgText | ConvertFrom-Json } else { $null })
    }
    [IO.File]::WriteAllText((Join-Path $Root "models\$Tag\model.json"), ($doc | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding $false))
    return [pscustomobject]@{ Copied = $copied; Linked = $linked }
}

function Get-LocalShaIndex([string]$DataDir) {
    # sha256 -> a file under the model files folder that setup or the archive checked (its .done mark says so).
    $map = @{}
    if (-not (Test-Path -LiteralPath $DataDir)) { return $map }
    foreach ($m in Get-ChildItem -LiteralPath $DataDir -Recurse -File -Filter '*.done' -ErrorAction SilentlyContinue) {
        $f = $m.FullName.Substring(0, $m.FullName.Length - 5)
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $t = Get-Content -LiteralPath $m.FullName -Raw -ErrorAction SilentlyContinue
        if ($t -match 'sha256 ([0-9a-fA-F]{64})') { $map[$Matches[1].ToLower()] = $f }
    }
    return $map
}

function Install-ArchiveModel([string]$Root, [string]$Tag, [string]$DataDir, [string]$StrataRoot, [scriptblock]$Say = { param($t) }) {
    # From the archive into the model files folder: a file already there with the same content is kept; one another
    # installed model has (same content, same drive) is hard-linked; the rest is copied and checked. Each gets the
    # .done mark setup reads. Then the config, with {data} set to this folder. -> @{ Copied; Linked; Kept; Config }.
    $m = @(Get-ArchiveIndex $Root | Where-Object { $_.Tag -eq $Tag }) | Select-Object -First 1
    if (-not $m) { throw "$Tag is not in the archive $Root" }
    $local = Get-LocalShaIndex $DataDir
    $copied = 0L; $linked = 0L; $kept = 0L
    $n = 0
    foreach ($f in @($m.files)) {
        $n++
        $dst = Join-Path $DataDir $f.rel
        $blob = Join-Path $Root "blobs\$($f.sha256)"
        & $Say ("[{0}/{1}] {2} ({3:n1} GB)" -f $n, @($m.files).Count, $f.rel, ($f.size / 1e9))
        if ((Test-Path -LiteralPath $dst) -and (Get-Item -LiteralPath $dst).Length -eq $f.size -and (Get-ArchiveSha $dst) -eq $f.sha256) {
            $kept += $f.size; & $Say '        already installed'
        } elseif ($local[$f.sha256] -and (Test-SameVolume $local[$f.sha256] $dst)) {
            New-HardLink $dst $local[$f.sha256]; $linked += $f.size; & $Say "        linked to $(Split-Path -Leaf $local[$f.sha256]) (the same file)"
        } else {
            if (-not (Test-Path -LiteralPath $blob)) { throw "the archive is missing $($f.rel) (blobs\$($f.sha256))" }
            Copy-Verified $blob $dst $f.sha256; $copied += $f.size; & $Say '        copied and checked'
        }
        [IO.File]::WriteAllText("$dst.done", "sha256 $($f.sha256)", (New-Object Text.UTF8Encoding $false))
        $local[$f.sha256] = $dst
    }
    $cfgPath = $null
    if ($m.config -and $StrataRoot) {
        $esc = ([IO.Path]::GetFullPath($DataDir).TrimEnd('\')) -replace '\\', '\\'
        $text = ($m.config | ConvertTo-Json -Depth 20).Replace('{data}', $esc)
        $cfgPath = Join-Path $StrataRoot "strata-$Tag.json"
        if (Test-Path -LiteralPath $cfgPath) { & $Say "$(Split-Path -Leaf $cfgPath) is already there: left as it is"; $cfgPath = $null }
        else { [IO.File]::WriteAllText($cfgPath, $text, (New-Object Text.UTF8Encoding $false)) }
    }
    return [pscustomobject]@{ Copied = $copied; Linked = $linked; Kept = $kept; Config = $cfgPath }
}

function Remove-ArchiveModel([string]$Root, [string]$Tag) {
    # The model's links and model.json; then every blob no remaining model names. -> bytes freed.
    $dir = Join-Path $Root "models\$Tag"
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    $used = @{}
    foreach ($m in Get-ArchiveIndex $Root) { foreach ($f in @($m.files)) { $used[$f.sha256] = $true } }
    $freed = 0L
    $blobs = Join-Path $Root 'blobs'
    if (Test-Path -LiteralPath $blobs) {
        foreach ($b in Get-ChildItem -LiteralPath $blobs -File) {
            if (-not $used[$b.Name.ToLower()]) { $freed += $b.Length; Remove-Item -LiteralPath $b.FullName -Force }
        }
    }
    return $freed
}

# ---------------------------------------------------------------------------------------- run on its own
if ($ArcAction) {
    $ErrorActionPreference = 'Stop'
    $Host.UI.RawUI.WindowTitle = "Strata archive: $ArcAction $ArcTag"
    $say = { param($t) Write-Host $t }
    $ok = $false
    try {
        $t0 = Get-Date
        switch ($ArcAction) {
            { $_ -in 'Copy', 'Ingest' } {
                # (Windows PowerShell's ConvertFrom-Json hands a JSON array on as one object: enumerate it)
                $paths = @(Get-Content -LiteralPath $ArcFiles -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
                $cfg = if ($ArcConfig -and (Test-Path -LiteralPath $ArcConfig)) { Get-Content -LiteralPath $ArcConfig -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
                $files = Get-ArchiveFiles $paths $ArcData $ArcStrata
                Write-Host ("{0} into the archive {1}: {2} files, {3:n1} GB" -f $ArcTag, $ArcRoot, @($files | Where-Object { -not $_.External }).Count, ((@($files) | Measure-Object Size -Sum).Sum / 1e9))
                $r = Add-ArchiveModel $ArcRoot $ArcTag $files $cfg $ArcData -Move:($ArcAction -eq 'Ingest') -Say $say
                Write-Host ("Done: {0:n1} GB {1}, {2:n1} GB already in the archive (linked)." -f ($r.Copied / 1e9), $(if ($ArcAction -eq 'Ingest') { 'moved in' } else { 'copied and checked' }), ($r.Linked / 1e9))
            }
            'Install' {
                $r = Install-ArchiveModel $ArcRoot $ArcTag $ArcData $ArcStrata -Say $say
                Write-Host ("Done: {0:n1} GB copied and checked, {1:n1} GB linked to files already installed, {2:n1} GB already there." -f ($r.Copied / 1e9), ($r.Linked / 1e9), ($r.Kept / 1e9))
                if ($r.Config) { Write-Host "Config: $($r.Config)" }
            }
            'Delete' {
                $freed = Remove-ArchiveModel $ArcRoot $ArcTag
                Write-Host ("Done: {0} removed from the archive, {1:n1} GB freed (files another model still uses stay)." -f $ArcTag, ($freed / 1e9))
            }
            default { throw "unknown action $ArcAction" }
        }
        Write-Host ("Took {0:n0} s." -f ((Get-Date) - $t0).TotalSeconds)
        $ok = $true
    } catch {
        Write-Host ''
        Write-Host "Stopped: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Nothing that was already in place was changed. Press Enter to close.'
        [void](Read-Host)
    }
    if ($ok) { Start-Sleep -Seconds 3; exit 0 } else { exit 1 }
}
