# strata-gui

A single-file WPF GUI (Windows PowerShell 5.1, no dependencies) for working with a
[Strata](https://github.com/niko1221/strata) local-LLM folder: launch its model servers,
benchmark them, compare the results, install new models, and open Cline against a running one.

Run it:

```powershell
powershell -STA -ExecutionPolicy Bypass -File strata-gui.ps1
# or point it at a folder at startup:
powershell -STA -ExecutionPolicy Bypass -File strata-gui.ps1 -StrataRoot D:\strata
```

It expects a Strata checkout that has already been set up (i.e. it has `.venv`, `serve\server.py`,
`tools\strata_bench.py`, and `strata-*.json` model configs — run `START-HERE.bat` there first).

## Tabs

- **Launch** — lists every `strata-*.json` config with its model, quant, context, port and live
  server status (polled from `http://127.0.0.1:<port>/health`). Start/stop a model's server
  (its own console window), open its web page, open its log/config. Optional per-launch overrides
  for `--max-context` and extra engine args — a patched config is written to `%TEMP%\strata-gui`,
  your config files are never modified. Optionally unloads Ollama models first to free VRAM.
  **Open Cline** waits until the model is loaded, then starts `cline-strata.ps1` — the launcher
  that ships beside the GUI, taking `-Folder -Model -StrataBase -Context -StrataRoot [-Thinking]` —
  pointed at this server. Any script with that interface works; the path is a setting.
- **Benchmark** — runs `tools\strata_bench.py` against one or several selected models, one after
  another (starting their servers as needed, stopping them when done). Live output in the window.
- **Results** — lists the folders in `bench\results`, shows a table of medians (decode tok/s,
  prompt tok/s and TTFT at 4K/16K, agent cache hit %) for `strata_bench` `results.json` files,
  and compares two selected runs side by side via `strata_bench.py --compare`.
- **Models** — reads the model catalog from the Strata checkout's `setup.py` and shows, per
  quant, download size, disk need and RAM need against *this* PC (free space on the data drive,
  RAM, GPU), colour-coded green/yellow/red. "Install with setup..." opens `START-HERE.bat`
  pre-filled with that family/model.
- **Service** — installs a per-user scheduled task that runs one config on demand, hidden:
  the server starts with `--lazy` (doesn't load the model), the first request loads it, and it
  unloads after N idle minutes (`--idle-unload`) so VRAM is free while nothing uses it. The GUI
  shows the task state and offers load/unload-now and its log. The task is re-entered on the
  same script with `-Service` — no second executable.

Settings (folder paths, Cline launcher, last selection, …) persist to
`strata-gui.settings.json` next to the script; that file is machine-local and not part of the repo.

## Notes

- Paths typed with trailing `\` (or wrapped in quotes) are normalized; quoted arguments handed to
  servers, the benchmark, Cline, and the scheduled task are escaped so a trailing `\` can't eat
  the closing quote (this needs `QPath` — see the comment by its definition).
- The GUI only ever stops servers it recognizes (its own, or a `/health` answer matching the
  config's model); a port taken by anything else is reported, never killed.
- **Open Cline** hands Cline the context the model really has — the running server's `/health`
  `max_context`, else the `--max-context` this GUI would launch with, else the config's — and
  refuses to open rather than guess. The launcher then clamps that to what the server reports and
  holds 4096 tokens back (both are `Get-ClineContext`), and writes the result into Cline's
  `models.json`, `providers.json` and legacy `globalState.json` *every* time, not only when the
  model is first registered — Cline re-imports `globalState.json` into its settings whenever it
  starts, so a stale window left there quietly undoes the other two (seen on a real machine: the
  number went straight back to 262144 on the next Cline run).
  Why so strict: an agent only compacts against the window it was told. Cline compacts at 0.9 of
  the number in its model entry, and since cline/cline#14867 it skips automatic compaction
  altogether for a custom model that declares no limit — so a model with no number just keeps
  growing. A Strata server never truncates: a prompt past the engine's window gets
  `400 ... leaves no room to answer`, and so does every request after it. Cline does recognise that
  reply and compacts and retries when there is history to compact; what it cannot come back from is
  a first request whose system prompt, tools and input are already too large. A guessed or stale
  number (the old 262144 default, or the same value parked in `globalState.json`, which Cline
  re-imports into `providers.json`) is therefore the one setting that cannot be too high.
- `tests\context-tests.ps1` checks that logic (it pulls the functions out of both scripts with the
  AST and drives them with stubs, so no GUI, no server and no Cline settings are touched):
  `powershell -NoProfile -ExecutionPolicy Bypass -File tests\context-tests.ps1`.
- Requires Windows PowerShell 5.1 (ships with Windows) — WPF comes from .NET Framework; no
  install step.
