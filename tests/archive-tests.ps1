# Test the model archive (strata-archive.ps1, docs/model-archive.md) on small dummy files in a temporary folder:
# deduplication, install (copy, keep, link), delete with shared files, moving in (Ingest), and what gets archived.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'strata-archive.ps1')

$fails = 0
function Assert-Is($Got, $Want, [string]$What) {
    if ($Got -eq $Want) { "  ok   $What = $Got" }
    else { $script:fails++; "  FAIL $What : got $Got, want $Want" }
}
function Sha([string]$Text) { $b = [Text.Encoding]::UTF8.GetBytes($Text); ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b)) -replace '-', '').ToLower() }
function Put([string]$Path, [string]$Text, [switch]$Mark) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
    if ($Mark) { [IO.File]::WriteAllText("$Path.done", "sha256 $(Sha $Text)") }
}

$tmp = Join-Path $env:TEMP "strata-archive-test-$PID"
$data = Join-Path $tmp 'data'; $arc = Join-Path $tmp 'archive'; $strata = Join-Path $tmp 'strata'
try {
    # model A: a shard with setup's mark, a shard shared with B, a pack folder Strata made; plus files that must not go in
    Put "$data\models\m-a\a-1.gguf" 'shard of A' -Mark
    Put "$data\models\m-a\shared.gguf" 'the shared PLE table' -Mark
    Put "$data\packs\a\experts.bin" 'pack of A'
    Put "$data\models\m-a\a-1.gguf.part" 'unfinished'
    Put "$strata\data\expert-profile.bin" 'comes with Strata'
    Put "$tmp\elsewhere\mine.gguf" 'my own file'
    $cfgA = [pscustomobject]@{ model_name = 'model-a'; args = @('--native', "$data\models\m-a\a-1.gguf", '--pack', "$data\packs\a", '--expert-profile', "$strata\data\expert-profile.bin") }
    $pathsA = @("$data\models\m-a\a-1.gguf", "$data\models\m-a\shared.gguf", "$data\packs\a", "$strata\data\expert-profile.bin", "$tmp\elsewhere\mine.gguf")

    Write-Host '--- what gets archived'
    $fa = @(Get-ArchiveFiles $pathsA $data $strata)
    Assert-Is @($fa | Where-Object { -not $_.External }).Count 3 'the shards and the pack file (no .part, no Strata file)'
    Assert-Is @($fa | Where-Object { $_.External }).Count 1 'a file outside both folders is external'
    Assert-Is (@($fa | Where-Object { $_.Rel -eq 'packs\a\experts.bin' }).Count) 1 'pack folder expanded, path relative to the model files folder'

    Write-Host '--- copy A, then B sharing a file'
    $r = Add-ArchiveModel $arc 'a' $fa $cfgA $data
    Assert-Is @(Get-ChildItem "$arc\blobs" -File).Count 3 'three blobs'
    Assert-Is (Get-Content "$arc\models\a\files\models\m-a\a-1.gguf" -Raw) 'shard of A' 'the link reads as the file'
    $ma = Get-Content "$arc\models\a\model.json" -Raw | ConvertFrom-Json
    Assert-Is ($ma.config.args[1]) '{data}\models\m-a\a-1.gguf' 'the config names the model files folder as {data}'
    Assert-Is ($ma.config.args[5]) "$strata\data\expert-profile.bin" 'a path in the Strata folder stays as it is'
    Assert-Is @($ma.external).Count 1 'model.json names the external file'

    Put "$data\models\m-b\b-1.gguf" 'shard of B' -Mark
    Put "$data\models\m-b\shared.gguf" 'the shared PLE table' -Mark
    $fb = @(Get-ArchiveFiles @("$data\models\m-b\b-1.gguf", "$data\models\m-b\shared.gguf") $data $strata)
    $plan = Get-ArchivePlan $arc $fb
    Assert-Is $plan.Have ('the shared PLE table'.Length) 'the plan knows the shared file is already there (from its mark)'
    $r = Add-ArchiveModel $arc 'b' $fb ([pscustomobject]@{ model_name = 'model-b'; args = @() }) $data
    Assert-Is $r.Linked ('the shared PLE table'.Length) 'B''s shared file is linked, not copied'
    Assert-Is @(Get-ChildItem "$arc\blobs" -File).Count 4 'one more blob, not two'
    $sum = Get-ArchiveSummary $arc
    Assert-Is $sum.Models 2 'two models'
    Assert-Is ($sum.Logical - $sum.Bytes) ('the shared PLE table'.Length) 'deduplication saved the shared file'

    Write-Host '--- install A into an empty folder, and B beside it'
    $data2 = Join-Path $tmp 'data2'
    $i = Install-ArchiveModel $arc 'a' $data2 $strata
    Assert-Is (Get-Content "$data2\models\m-a\shared.gguf" -Raw) 'the shared PLE table' 'files restored'
    Assert-Is (Get-Content "$data2\models\m-a\shared.gguf.done" -Raw) "sha256 $(Sha 'the shared PLE table')" 'with the mark setup reads'
    Assert-Is $i.Copied ('shard of A'.Length + 'the shared PLE table'.Length + 'pack of A'.Length) 'everything copied (nothing there before)'
    $cfg = Get-Content "$strata\strata-a.json" -Raw | ConvertFrom-Json
    Assert-Is $cfg.args[1] "$data2\models\m-a\a-1.gguf" 'the config points at the new folder'
    $i = Install-ArchiveModel $arc 'b' $data2 $strata
    Assert-Is $i.Linked ('the shared PLE table'.Length) 'B''s shared file is linked to A''s installed one'
    Assert-Is $i.Copied ('shard of B'.Length) 'only B''s own shard is copied'
    [IO.File]::WriteAllText("$strata\strata-a.json", '{"mine":true}')
    $i = Install-ArchiveModel $arc 'a' $data2 $strata
    Assert-Is $i.Kept ('shard of A'.Length + 'the shared PLE table'.Length + 'pack of A'.Length) 'installing again keeps what is there'
    Assert-Is (Get-Content "$strata\strata-a.json" -Raw) '{"mine":true}' 'an existing config is never overwritten'

    Write-Host '--- delete from the archive'
    $freed = Remove-ArchiveModel $arc 'a'
    Assert-Is $freed ('shard of A'.Length + 'pack of A'.Length) 'deleting A frees only its own files'
    Assert-Is (Test-Path "$arc\blobs\$(Sha 'the shared PLE table')") $true 'the shared blob stays for B'
    Assert-Is (Get-Content "$arc\models\b\files\models\m-b\shared.gguf" -Raw) 'the shared PLE table' 'B still reads it'
    $freed = Remove-ArchiveModel $arc 'b'
    Assert-Is @(Get-ChildItem "$arc\blobs" -File).Count 0 'deleting B empties the archive'

    Write-Host '--- ingest: setup downloaded into the archive drive'
    Put "$tmp\arcdata\models\m-c\c-1.gguf" 'shard of C' -Mark
    $fc = @(Get-ArchiveFiles @("$tmp\arcdata\models\m-c\c-1.gguf") "$tmp\arcdata" $strata)
    $r = Add-ArchiveModel $arc 'c' $fc $null "$tmp\arcdata" -Move
    Assert-Is (Test-Path "$tmp\arcdata\models\m-c\c-1.gguf") $false 'the file was moved in'
    Assert-Is (Get-Content "$arc\models\c\files\models\m-c\c-1.gguf" -Raw) 'shard of C' 'and is in the archive'

    Write-Host '--- run on its own, as the launcher runs it (a JSON list of paths)'
    Put "$data\models\m-d\d-1.gguf" 'shard of D' -Mark
    $list = Join-Path $tmp 'paths.json'
    [IO.File]::WriteAllText($list, (ConvertTo-Json @("$data\models\m-d\d-1.gguf", "$data\packs\a")))
    $script = Join-Path (Split-Path -Parent $PSScriptRoot) 'strata-archive.ps1'
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $script -ArcAction Copy -ArcRoot $arc -ArcTag 'd' -ArcData $data -ArcStrata $strata -ArcFiles $list
    Assert-Is $LASTEXITCODE 0 'the console run succeeds'
    Assert-Is @((Get-Content "$arc\models\d\model.json" -Raw | ConvertFrom-Json).files).Count 2 'and archives both entries of the list'
    [IO.File]::WriteAllText($list, (ConvertTo-Json @("$data\nothing-here")))
    $null = 'x' | & powershell -NoProfile -ExecutionPolicy Bypass -File $script -ArcAction Copy -ArcRoot $arc -ArcTag 'e' -ArcData $data -ArcStrata $strata -ArcFiles $list
    Assert-Is $LASTEXITCODE 1 'no files: it stops with an error instead of archiving nothing'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails) { "`n$fails FAILED"; exit 1 }
"`nall good"
