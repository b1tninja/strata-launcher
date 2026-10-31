# Model archive

How the Models tab's archive works (built from this design; `strata-archive.ps1`, tested by `tests\archive-tests.ps1`).

A model can be **Downloaded** (kept in an archive on a big, slower drive, each unique file stored once) separately from
**Installed** (on the fast drive Strata runs it from, with its `strata-*.json` config). Installing from the archive is a
local copy instead of a 60-190 GB download, and removing an installed model no longer means downloading it again later.

## Why

- Models are large and several share files byte for byte: Unsloth's UD-Q5_K_XL, UD-Q6_K_XL and Q8_0 share shards 2 and 3
  (the 0.7 GB output head and the 54 GB PLE table); NVFP4 and NVFP4-NVIDIA share `ple-fp8.gguf` (51 GB) and
  `token-embd-bf16.gguf` (1.3 GB); every Qwen3.8 model shares the MTP draft layer and the vision encoder.
- The fast drive is small (here a 2 TB Gen5 drive holds Windows and the models) and a big drive is slow (4 TB).
  Strata should run from the fast one; the big one is fine for keeping.
- Strata NVFP4-QAD needs 110 GB of preparation beside its 102 GB download; the prepared result is worth keeping.

## States

| State | Meaning | Where |
| --- | --- | --- |
| Available | in Strata's catalog (`setup.py`), not on this PC | - |
| Downloaded | every file of the model is in the archive, checked by SHA-256 | archive drive |
| Installed | a `strata-*.json` config whose files are on the install drive | Strata's model files folder (`--data-dir`) |
| Running | Installed and its server is up | |

A model can be Downloaded and Installed at once. The Models tab shows both, with the space each takes.

## Archive layout

One folder on one drive (a setting; default `<biggest other drive>:\Strata-archive`):

```
Strata-archive\
  blobs\<sha256>                 every unique file once (the content decides the name)
  models\<tag>\model.json        the model: its files (path relative to the model files folder, size, SHA-256),
                                 its config with paths written as {data}\..., where it came from, when
  models\<tag>\files\...         hard links to the blobs, laid out as under the model files folder (readable as is)
```

Hard links only work inside one volume, which is why the archive is one folder on one drive. A file two models share is
one blob with two links: it takes its space once, and deleting one model leaves the other's link (and the blob).

The SHA-256 of most files is already known: Strata's setup pins every published file's size and SHA-256 and writes it
into the file's `.done` mark when it checks a download (`sha256 <hash>`). Only files Strata made on this PC (a prepared
pack, the MTP draft layer) are hashed by the archive, at about 2 GB/s on an NVMe drive.

## Actions (Models tab, and Launch tab beside Remove model...)

- **Archive** (an Installed model; the everyday one): take the model off the fast drive but keep it on this PC. It is
  **Copy to archive** followed by Strata's removal of the installed copy, and the removal only starts once every file
  is in the archive and checked. The model then shows as Downloaded, and **Install from archive** brings it back in
  minutes. The confirmation says how much the fast drive gets back and how much the archive grows (often less: shared
  files are already there).
- **Copy to archive** (an Installed model): the same without the removal: the model stays installed and is also kept.
  Ask Strata which files and folders the model uses (the same list its removal plan works from: `model_paths` +
  `with_shards` in `tools/strata_mcp.py`, through the launcher's helper), copy each file whose content the archive lacks
  into `blobs\`, check the copy's SHA-256, link it under `models\<tag>\files\`, and write `model.json`. Files already in
  the archive are only linked: nothing is copied twice.
- **Remove...** (as today): delete the installed model for good. When the model is also Downloaded, the confirmation
  says it stays in the archive. The archive is never touched by a removal: its files are not under Strata's folders.
  (Not "Unload": the Service tab already uses that for freeing the GPU.)
- **Install from archive**: copy the model's files from the archive to the model files folder on the install drive,
  check every copy's SHA-256 (a copy goes through RAM, and unstable RAM corrupts copies: this PC did), write the `.done`
  marks setup reads, and write the config from `model.json` with `{data}` set to this PC's folder. Files the install
  drive already has with the same SHA-256 (a shared shard of another installed model) are linked there, not copied.
  Nothing is downloaded and setup does not run.
- **Download to archive** (an Available model): run Strata's setup with `--data-dir` and `--models-dir` inside the
  archive and `--no-start`, so the download and any preparation (QAD's 110 GB) happen on the archive drive. Then
  **Copy to archive** in place (same drive: a file is moved into `blobs\` and linked back, no copy) and remove the config
  setup wrote, so the model shows as Downloaded, not Installed.
- **Delete from archive**: remove the model's links and `model.json`; a blob no other model links to is deleted.
  Asks first and lists what is freed, like **Remove...** does today.

The Models tab gets a **State** column (Available / Downloaded / Installed / Installed + Downloaded), the archive's size
and what deduplication saved, and the buttons above for the selected row.

## What Strata already gives, and what the launcher adds

| Needed | From |
| --- | --- |
| The files of a model, and which are shared | Strata (`strata_mcp.py` removal plan's `model_paths`) |
| Published files' size and SHA-256 | Strata (`setup.py` pins; `.done` marks) |
| Downloading, resuming, repairing damaged parts | Strata's setup |
| Preparing a model (packs, QAD conversion) | Strata's setup |
| The archive: blobs, links, `model.json`, the states, copying with checks, install without setup | Strata Launcher (new) |

## Limits

- One archive folder, on one drive (hard links). A second archive drive would be a second archive.
- An archived config records the Strata engine arguments of the day; installing it into a much newer Strata can need
  setup run once more (offered when the config's engine version is older than the installed engine's).
- Files of a model that are outside Strata's folders (a `--gguf-dir` of your own) are archived too, but **Uninstall**
  leaves them where they are, as Strata's removal does today.
- The archive is plain files: deleting the folder by hand is safe; the launcher then shows the models as not Downloaded.

## Tests

The file list, deduplication (two models sharing a file make one blob), install of a shared file as a link, and
deleting one of two models that share a blob, all on small dummy files in a temporary folder; and the state of each
catalog row from a dummy archive and dummy configs.
