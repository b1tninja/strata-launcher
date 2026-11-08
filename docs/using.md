# Using Strata Launcher

The list at the top shows every model config in the Strata folder (`strata-*.json`) with its quant,
disk use, RAM need, context, port and live server status. **Disk GB** is Strata's own count of the
model's files, including files it shares with other models (the MTP draft layer). **RAM GB** is the
system RAM Strata's catalog gives for keeping every expert in RAM (a range for a RAM-budget model, which
runs with less by reading the rest from the SSD); `~` marks a model of your own, shown with the closest
catalog entry's figure. Select one to launch it, or several to benchmark them in turn.

| Tab | |
| --- | --- |
| **Launch** | Start and stop the selected model's server (only that one), open the web chat, the engine log (a built-in viewer with live follow) or the config. Per-launch overrides for the context (with the rope scaling longer contexts need), the VRAM reserve, [MTP drafting and its depth](#mtp-speculative-decoding) and more; your config files are never changed. **Remove model...** deletes a model's files and config ([details](setup.md#removing-models)). **Open VS Code** and **Open Continuous CLI** ([coding with Continuous](#coding-with-continuous)) and **Sessions** are here too. |
| **Benchmark** | Runs Strata's `strata_bench.py` against one or several models in turn, starting and stopping their servers, with live output. |
| **Results** | Every benchmark run as a table (its MTP setting and draft acceptance, decode and prompt speed, time to first token, cache hits); compare two side by side. |
| **Models** | Strata's model catalog with download size, disk and RAM needs against this PC, colour-coded by fit. **Install with setup...** downloads one; **Remove...** deletes an installed one ([details](setup.md#removing-models)). The **archive** keeps models on another drive without installing them ([below](#the-model-archive)). |
| **Service** | Runs one model on demand in the background: the server starts without loading the model, the first request loads it, and it unloads after an idle time so the graphics card is free. Optionally saves the conversation before unloading. |
| **Config** | A full editor for a model's `strata-*.json`: server settings (from Strata's own settings schema), engine options with explanations, model files, other engine arguments, and the raw JSON. Changes are listed and checked before saving, and the previous file is kept as `.bak`. **Save as new** makes a variant; **Uncensored variant...** makes one with an optional control vector ([below](#an-uncensored-variant-optional-not-included)). |
| **Setup** | Everything a new PC needs, and the place to update Strata. See [Setting up a PC](setup.md). |
| **PC** | What sets Strata's speed on this PC, with what to do about it ([below](#the-pc-tab)). |

## The model archive

A model is **Installed** when it is in the data folder with its config, ready to run; it is **Downloaded** when it is
kept in the archive folder (Models tab), typically on a bigger, slower drive. The **State** column shows which. Each
unique file is stored once in the archive however many models share it (Unsloth's Q5/Q6/Q8 share 55 GB, the NVFP4
versions 52 GB, every Qwen3.8 model the MTP draft layer), and every copy into or out of it is checked by SHA-256.

| Button | What it does |
| --- | --- |
| **Archive...** (also on the Launch tab) | Copies the model into the archive, then removes it from the data folder: the fast drive gets the space back, and the model stays on this PC. |
| **Copy to archive** | The same, but the model stays installed. |
| **Install from archive** | Copies it back into the data folder and writes its config: minutes, no download. Files another installed model already has are linked, not copied. |
| **Download to archive...** | Strata's setup downloads (and prepares) the model on the archive drive; it shows as Downloaded. |
| **Delete from archive...** | Deletes it from the archive; files another archived model uses stay. |
| **Remove...** | As before: deletes the installed model. The archive is never touched by it. |

The long copies run in their own window. The archive is plain files and hard links (`blobs\` and `models\`); deleting
the folder by hand is safe. Design and limits: [model-archive.md](model-archive.md).

## The PC tab

Strata's speed depends on three parts of the PC, and the PC tab shows each one against what it could be:

- **RAM speed.** Generating text reads the experts the GPU does not hold from RAM, so it runs at about the RAM's
  bandwidth. Each stick is listed with the speed it runs at, its standard (JEDEC) speed and the speed in its part number
  (what EXPO or XMP runs it at). RAM well below its rated speed usually means EXPO/XMP is off in the BIOS. Four large
  sticks at a high speed is flagged too: many boards cannot hold it, and unstable RAM corrupts downloads and model files
  without an error.
- **The GPU's PCIe link.** Reading a prompt streams model weights to the GPU, so prompt speed follows the link: Gen5 x8
  is half of Gen5 x16. A card below its full width is usually sharing lanes with an M.2 slot or a second x16 slot; the
  tab lists the NVMe drives connected to the same CPU lanes as the card, and the board's manual says which slot shares
  them. Some cards slow the link while idle, so check again with a model loaded.
- **The drive the models are on.** Experts that do not fit in RAM are read from it while Strata answers; its link and
  free space are shown, and the drive with the models is marked.

The tab also shows Windows' **commit limit** (RAM plus the page file). Strata keeps experts in RAM only as far as the
commit limit allows, whatever RAM is free, and a model that fills RAM can end without a message when the limit runs out.
A limit under 1.5 times the RAM is flagged. Measured on 94 GB of RAM: a 22 GB system-managed page file capped Q5's
experts in RAM at 56 GiB with 20 GB of RAM unused; a fixed 64 GB page file on another drive raised it to 66 GiB and made
Q5 18-32% faster. The page file is mostly reserved space, so the drive it is on matters little; keeping it off the models'
drive keeps it out of the way of their reads.

Everything is read from Windows without admin rights. Each benchmark run from the Benchmark tab saves the same facts as
`launcher-pc.json` next to `results.json` (parts and links only: no serial numbers or paths), and the **Results** tab's
**PC** column shows them (`2x48@6000, 5.0 x8/16`). Comparing two runs from different hardware says so first. Runs from
before this show what `strata_bench` recorded itself: the RAM size and the GPU's link read near idle.

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

## Coding with Continuous

**Open VS Code** (Launch tab) is the way to code against the local model. It uses
[Continuous](https://github.com/b1tninja/continuous), the Continue fork, from the VS Code Marketplace
(`b1tninja.continuous`). It:

1. installs Continuous when it is missing, with `code --install-extension b1tninja.continuous`. VS Code picks the
   build for this PC and keeps it up to date from the Marketplace;
2. writes `configs/strata.yaml` in Continuous's global folder: a config named **Strata** with two entries for the
   selected model, a **plan** entry with the **Plan thinking** level and an **act** entry with the **Thinking** level
   (sent as `reasoning_effort` in each request), tool use on, pictures on when the server reads them (its `/health`
   says `images`; without `image_input` in the capabilities list Continuous turns them off), the server's real
   context, and Qwen's thinking-mode sampling. The reply cap (`maxTokens`) is 32,768 tokens (a quarter of a smaller
   context): Strata counts the thinking in it and ends thinking when a quarter is left, so an 8,192 cap stopped
   `xhigh` plans at about 6K tokens. An **autocomplete** entry gives Tab the same server, over chat (Strata has no
   `/v1/completions`) with thinking off (`chat_template_kwargs.enable_thinking: false`) and a `modelTimeout` of
   1,000 ms, since the 150 ms default stops a completion at 375 ms and a cold Strata Tab request takes about a second;
3. starts the server if it is not running, then opens VS Code in the **Project folder**.

In Continuous, pick **Strata** in the configs dropdown, then the plan or act model. It loads every YAML file in
`configs` beside your own `config.yaml`, which the launcher never touches. **Open Strata config** opens the file.

**Install dev build...** is for testing a build of the fork: it installs a `.vsix` you pick (a local
`npm run package` in its `extensions\vscode`, or a CI artifact) over the Marketplace one, and saves nothing. The
Marketplace version replaces it when a newer one comes out; uninstall it in VS Code to go back sooner.

Continuous has its own settings and commands (`continuous.*`), so it sits beside upstream
[Continue](https://github.com/continuedev/continue) without clashing. The fork's earlier extensions
(`b1tninja.continued`, `b1tninja.continuing`) are replaced by it: when one is installed, Open VS Code offers to
uninstall it, once each time the launcher runs. Your settings and `~/.continue` are kept.

The global folder is `~/.continuous` (`CONTINUOUS_GLOBAL_DIR`, or the older `CONTINUE_GLOBAL_DIR`, moves it).
Continuous's first start copies `~/.continue` there only when `~/.continuous` does not exist yet, so until then the
launcher writes the file in `~/.continue`, and the copy carries it over along with your own config. Making
`~/.continuous` first would skip that copy.

### The Continuous CLI

**Open Continuous CLI** runs Continuous in a terminal instead: its command line, `continuous`, has a full terminal UI
with plan mode, task lists and steering. It writes the same `strata.yaml`, starts the server if needed, then opens a
PowerShell window in the project folder running `continuous --config <that file>`.

The Setup tab's **Continuous CLI** step installs it from the newest
[release](https://github.com/b1tninja/continuous/releases): its `continuous-cli-<version>.tgz`, with `npm install -g`
(the CLI is not on npm's registry). It needs Node.js 22 or newer, which the step installs first when it is missing.
The step compares the installed version (`continuous --version`) with the newest release and offers **Update** when a
newer one is out. Its command is `continuous`, not upstream's `cn`, so both can be installed.

### Thinking levels

The plan and act entries each carry their own level, so switching between them in Continuous changes how much the
model thinks. Strata passes `low` and `medium` to the model as they are; `high` and `xhigh` are both the model's top
level. Measured on NVFP4 with 12 Python problems (checked on ~155 cases each): thinking off solved 11, low, medium and
xhigh all solved 12; low took about twice off's time, xhigh 5.6x low's, with one problem thinking for 135 s. So
`low` (or `medium`) suits acting and `xhigh` planning.

### Tab and the conversation cache

Strata serves one request at a time and keeps only conversations of at least `--conversation-cache-min-tokens` in its
conversation cache (the bundled configs say 50,000). A Tab request replaces the conversation the engine holds, so with Tab
on, an agent conversation under that size is read again on its next turn: measured on qwen3.8-flash-next-nvfp4, an
18,609-token conversation took 0.22 s cached and 3.9 s after one Tab request, while a 74,210-token one stayed cached
(0.45 s). Tab prompts are about 2,000 tokens (1,992 measured), so `--conversation-cache-min-tokens 4096` (in
**Extra args** or the config) lets Strata park agent conversations while Tab prompts stay out. Measured with the same
18.6K-token conversation, as the agent turn after Tab requests:

| Agent turn | min-tokens 50000 | min-tokens 4096 |
| --- | --- | --- |
| after 1 Tab request | 4.05 s, nothing cached | 0.46 s, 18,644 tokens cached |
| after 5 Tab requests | 4.06 s, nothing cached | 0.31 s, 18,669 tokens cached |

The first Tab request after an agent turn took about 0.7 s longer at 4096 (2.1 s against 1.4 s), and up to four
conversations are parked at a time, so short side requests of 4096 tokens or more now compete with a long one for those
places. Parking also needs free RAM: the snapshot (834 MiB for that conversation) plus `--conversation-cache-min-free-mib`
(2,560 MiB). With about 2 GiB available, 4096 changed nothing: the engine log said `skip parking (physical RAM admission
...)` and every agent turn after a Tab request took over 4 s. The Monitor tab's **Conversation cache** card (or
`/metrics`) shows parks and restores.
To keep Tab off, disable the autocomplete model in Continuous.

## An uncensored variant (optional, not included)

Neither this launcher nor Strata ships one. Another Strata fork, [sergqwer/strata-nvfp4](https://github.com/sergqwer/strata-nvfp4)
(MIT), publishes a control vector that stops Qwen3.8-Flash-Next from declining requests: `data/uncensor/` there, with its
README (how it was made, what it does to quality, licence) and a JSON of its scores. With it on, what the model writes is
your responsibility.

The **Models** tab's **Uncensor** column marks it `optional` for the model it fits and `licence` for NVIDIA's NVFP4
and FP4-Local; installing never adds it. In the model list a config that runs it shows `uncensored` after its quant
(Strata's own `data/experimental-speed-projection` vector removes refusals too and is shown the same way).

**Uncensored variant...** (Config tab) makes one from the open config:

1. It is offered only for the NVFP4 GPTQ pack (`Maximilian228--Qwen3.8-Flash-Next-NVFP4-GPTQ-Strata`), the Qwen-licensed
   model the vector was made and measured on. NVIDIA's NVFP4 and FP4-Local are refused (their licence does not allow
   bypassing the model's safety guardrails), and so are other weights.
2. It downloads the three files from commit `a1ad5954` into `<data folder>\uncensor\` and checks each against its
   SHA-256 sum; a file that does not match is deleted and nothing is written. Files already there that match are not
   fetched again.

   | File | SHA-256 |
   | --- | --- |
   | `qwen-nvfp4-gptq-uncensored.gguf` | `a2ec3e999724022a55d48d30822bd10b1b25916ccc221013a119a674d06a46b5` |
   | `qwen-nvfp4-gptq-uncensored.json` | `83858b5db79b78e8790fc9e0c05bf7ae2681640b1248372dffda517a038d89c1` |
   | `README.md` | `7fb4156ba62d9c6d49faa826b5300e9992c2e3e88f947fe839f90163d754a273` |

3. It writes `strata-<name>-uncensored.json`: the open config with its own `model_name` (`...-uncensored`), the next
   free port and its own log, and these engine arguments in place of any control vector the original had:

   ```
   --control-vector-scaled <data folder>\uncensor\qwen-nvfp4-gptq-uncensored.gguf:1.0
   --control-vector-layer-range 8 33 --cvec-mode project --cvec-dir per-layer
   ```

   The original config is not changed. Used on the variant itself (or again on the original), it rebuilds the variant
   from the saved config and keeps its port.

In this Strata the vector is on for every request of that config; the per-request `"uncensored"` switch the other fork's
README describes is that fork's own server code. To do it by hand, download the files from
`https://raw.githubusercontent.com/sergqwer/strata-nvfp4/a1ad595440468ededd8b87cf46a6906310930170/data/uncensor/<file>`,
check the sums, and add the arguments above to a copy made with **Save as new**. That README describes how the vector
was made (the refusal direction of Arditi et al. 2024, from 320 harmful and 320 harmless prompts), but the scripts that
built it are not published, so it cannot be rebuilt from that repository.

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
