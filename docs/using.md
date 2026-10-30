# Using Strata Launcher

The list at the top shows every model config in the Strata folder (`strata-*.json`) with its quant,
disk use, RAM need, context, port and live server status. **Disk GB** is Strata's own count of the
model's files, including files it shares with other models (the MTP draft layer). **RAM GB** is the
system RAM Strata's catalog gives for keeping every expert in RAM (a range for a RAM-budget model, which
runs with less by reading the rest from the SSD); `~` marks a model of your own, shown with the closest
catalog entry's figure. Select one to launch it, or several to benchmark them in turn.

| Tab | |
| --- | --- |
| **Launch** | Start and stop the selected model's server (only that one), open the web chat, the engine log (a built-in viewer with live follow) or the config. Per-launch overrides for the context (with the rope scaling longer contexts need), the VRAM reserve, [MTP drafting and its depth](#mtp-speculative-decoding) and more; your config files are never changed. **Remove model...** deletes a model's files and config ([details](setup.md#removing-models)). **Sessions** and **Open Cline** are here too (below). |
| **Benchmark** | Runs Strata's `strata_bench.py` against one or several models in turn, starting and stopping their servers, with live output. |
| **Results** | Every benchmark run as a table (its MTP setting and draft acceptance, decode and prompt speed, time to first token, cache hits); compare two side by side. |
| **Models** | Strata's model catalog with download size, disk and RAM needs against this PC, colour-coded by fit. **Install with setup...** downloads one; **Remove...** deletes an installed one ([details](setup.md#removing-models)). |
| **Service** | Runs one model on demand in the background: the server starts without loading the model, the first request loads it, and it unloads after an idle time so the graphics card is free. Optionally saves the conversation before unloading. |
| **Config** | A full editor for a model's `strata-*.json`: server settings (from Strata's own settings schema), engine options with explanations, model files, other engine arguments, and the raw JSON. Changes are listed and checked before saving, and the previous file is kept as `.bak`. **Save as new** makes a variant. |
| **Setup** | Everything a new PC needs, and the place to update Strata. See [Setting up a PC](setup.md). |

## MTP speculative decoding

Strata's models have an MTP (multi-token prediction) draft layer: it guesses the next few tokens, and
one pass of the full model checks them all. The answer is the same as without it, only faster, and
faster still the more of the guesses are right. Strata's setup turns it on (`--mtp`, `--spec 4`), and
it also drafts from earlier repeats in the context (prompt lookup), which pays off on code edits.

- **While a model runs**, the Server column shows the share of drafted tokens it accepted since it
  started, from the server's own counters (`ready (512K ctx, drafts 78%)`).
- **To compare**, set the Launch tab's **MTP drafting** (on, or off: prompt lookup only, which frees
  the draft layer's ~0.7-1 GiB of VRAM for the expert cache) and **Draft depth** (`--spec`, 1-8), then
  benchmark. A benchmark uses the same overrides, and **Results** shows each run's setting (`spec 4`,
  `lookup 4`) and its acceptance next to its speed. Both boxes start at the config's own setting each
  time Strata Launcher opens.
- The **Config** tab has the finer settings, each with what Strata measured: `--spec-min-p`,
  `--suffix-draft`, `--lookup-chain`, `--mtp-max-t`, `--mtp-window`, `--mtp-hnorm`, `--mtp-q4` and
  `--mtp-draft-vocab`.

## Cline

Strata never truncates a prompt: once a conversation outgrows the model's context, every request
fails. Cline only compacts a conversation against the limit it was told, and its own token count
runs a few percent under Strata's. **Open Cline** therefore tells Cline a limit with headroom (10%
of the context by default, the **Headroom** setting, never under 4,096 tokens) taken from what the
running server reports, and writes it everywhere Cline reads it, every time.

- Cline compacts at 90% of the limit in its model entry, and skips automatic compaction entirely for
  a custom model with no limit.
- With a flat 4,096-token reserve, Cline's log still showed prompts of 131,118-132,455 tokens sent
  to a 131,072-token server after it had been told 126,976: its estimate is ~4-5% low, so the reserve
  is a share of the context.
- Cline re-imports its legacy `globalState.json` into `providers.json` at every start, so the limit is
  written to `models.json`, `providers.json` and `globalState.json` on every launch.
- Those files are written as plain UTF-8: Windows PowerShell 5.1 adds a byte-order mark that Node's
  JSON parser rejects, and Cline then silently rebuilt its settings without any limit.

`cline-strata.ps1` does this on its own too, for use without the window:

```powershell
powershell -ExecutionPolicy Bypass -File cline-strata.ps1 [-Model <id>] [-StrataBase http://127.0.0.1:8080]
```

## Sessions

Strata can write the engine's state for a conversation (KV cache, recurrent state, its checkpoint)
to a file and read it back. **Hibernate** saves it, **Resume** restores it, even into a restarted
engine. Measured on an RTX 5090: a 27.5K-token conversation took 16.0 s to read cold, saved in 0.6 s
(626 MiB) and restored in 0.5 s, after which the next turn reused 27,545 tokens and read 19.

Session files need a session folder in the model's config (**Config › Files › `slot_save_path`**). A
file restores only into the same Strata version with the same context, KV and rope settings, and
Strata never deletes them (~24 KB per token).

## Command line

```powershell
powershell -STA -ExecutionPolicy Bypass -File strata-launcher.ps1 [-StrataRoot <folder>] [-FirstRun]
```

`-FirstRun` shows the first-start dialog again.
