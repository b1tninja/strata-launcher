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
  — a patched config is written to `%TEMP%\strata-gui`, your config files are never modified:
  - **Max context**: steps up to the model's trained 262,144 run unscaled (a config's rope flags are
    dropped there); the 384K/512K/1M steps add `--rope-scaling yarn --rope-scale <ctx/262144>`, which
    Strata documents as experimental. A hint under the box shows the KV cache's RAM/VRAM cost
    (~13.7 KB per token at int8), the rope state and the number Cline will be told.
  - **VRAM reserve** (`--vram-reserve-mib`); the hint quotes the value the engine log asked for
    when GPU memory ran low.
  - **Shorten an answer that would not fit** (`fit_max_tokens`, on by default): the server caps
    `max_tokens` to the room left instead of refusing the request.
  - Extra engine args. Optionally unloads Ollama models first to free VRAM.
  **Open Cline** waits until the model is loaded, then starts `cline-strata.ps1` — the launcher
  that ships beside the GUI, taking `-Folder -Model -StrataBase -Context -StrataRoot [-Thinking]` —
  pointed at this server. Any script with that interface works; the path is a setting.
  **Sessions** save the conversation the engine holds (KV cache, recurrent state, its checkpoint)
  to a file and restore it, also into a freshly started engine — Strata's own session files
  (`POST /slots/0?action=save|restore`), on when the config has `slot_save_path` (Config > Files).
  **Hibernate** saves `<config>-latest.bin` and stops the server; **Resume** starts it (or loads the
  model), then restores that file; **Open Cline** can resume first. Measured here (NVFP4, RTX 5090,
  Windows): a 27.5K-token conversation read cold in 16.0 s, saved in 0.58-0.67 s (626 MiB, ~24 KB per
  token), restored in 0.48-0.56 s into a restarted engine, after which the next turn reused 27,545
  tokens and read 19 (0.58 s). A file restores only into the same engine version with the same
  context, KV and rope settings (the engine refuses others); Strata never deletes them. A save needs
  free RAM (~355 MiB plus a 2.5 GiB floor here) and is refused when the PC is short of it.
- **Benchmark** — runs `tools\strata_bench.py` against one or several selected models, one after
  another (starting their servers as needed, stopping them when done). Live output in the window.
- **Results** — lists the folders in `bench\results`, shows a table of medians (decode tok/s,
  prompt tok/s and TTFT at 4K/16K, agent cache hit %) for `strata_bench` `results.json` files,
  and compares two selected runs side by side via `strata_bench.py --compare`.
- **Models** — reads the model catalog from the Strata checkout's `setup.py` and shows, per
  quant, download size, disk need and RAM need against *this* PC (free space on the data drive,
  RAM, GPU), colour-coded green/yellow/red. "Install with setup..." opens `START-HERE.bat`
  pre-filled with that family/model.
- **Config** — an editor for the selected `strata-*.json` (Launch's **Open config** opens it here):
  - *Model and server*: `model_name`, `port`, `host`, `api_key`, `gpu`, then every setting Strata's
    own Settings page edits, read from the checkout's `serve\runconfig.py` with its help text.
  - *Engine*: the common engine flags with their own controls and help (context — which sets rope
    scaling the way the Launch override does — KV format and streaming, VRAM reserve, expert cache,
    prefill, speculative decoding, batching, caches, CPU threads).
  - *Files*: the engine, tokenizer and model paths with a browse button and a mark when one is missing.
  - *Other arguments*: every remaining engine flag as an editable Flag/Value table.
  - *JSON*: the file as Save would write it; edit it and load it back into the form.
  The changes are listed live and checked before saving (ranges, choices, no `host` beyond this PC
  without an `api_key`, no context past 262,144 without rope scaling, no `lazy_load` with images).
  Save confirms the list, keeps the previous file as `<name>.bak` and writes through Strata's
  `runconfig.save` (atomic replace, Strata's own format). **Save as new...** creates another
  `strata-<name>.json` — e.g. a 256K variant beside the original.
- Logs and benchmark reports open in a built-in viewer (with Follow for a live log); config files
  open in their default app. Nothing relies on Notepad, which can be a broken stub on Windows 11.
- **Service** — installs a per-user scheduled task that runs one config on demand, hidden:
  the server starts with `--lazy` (doesn't load the model), the first request loads it, and it
  unloads after N idle minutes (`--idle-unload`) so VRAM is free while nothing uses it. The GUI
  shows the task state and offers load/unload-now and its log. The task is re-entered on the
  same script with `-Service` — no second executable. With **Save the conversation before
  unloading** the runner does the idle unload itself (`-Hibernate`): after the idle time it saves
  `<config>-latest.bin`, then unloads, logging to `strata-service.hibernate.log`; Resume or Open
  Cline brings the conversation back (a request that reaches the lazy server first reads it cold).

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
  holds back the **Headroom** share of it — 10% by default, never under 4096 tokens (both are
  `Get-ClineContext`; `-ReservePercent` on the launcher). A flat 4096 was not enough: Cline's
  estimate runs ~4-5% under the engine's count, and its log showed 131,118-132,455-token prompts
  sent against a 131,072 window after it had been told 126,976. It writes the result into Cline's
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
- Stopping a server this GUI did not start ends its whole launch chain (the `cmd` of a `run-*.bat` or
  launch line, the venv's python and the interpreter it starts), so no window is left at
  "Press any key"; anything outside that chain is left alone.
- `tests\session-tests.ps1` checks the session-file helpers (file names, folder resolution, the
  launch-chain lookup).
- `tests\context-tests.ps1` checks that logic (it pulls the functions out of both scripts with the
  AST and drives them with stubs, so no GUI, no server and no Cline settings are touched):
  `powershell -NoProfile -ExecutionPolicy Bypass -File tests\context-tests.ps1`.
- Requires Windows PowerShell 5.1 (ships with Windows) — WPF comes from .NET Framework; no
  install step.
