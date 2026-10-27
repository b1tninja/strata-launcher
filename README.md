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
  **Open Cline** waits until the model is loaded, then starts your Cline launcher script
  (`cline-strata.ps1`-style, taking `-Folder -Model -StrataBase -Context -StrataRoot [-Thinking]`)
  pointed at this server.
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
- Requires Windows PowerShell 5.1 (ships with Windows) — WPF comes from .NET Framework; no
  install step.
