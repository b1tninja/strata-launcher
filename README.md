<p align="center">
  <img src="assets/logo.svg" width="128" height="128" alt="Strata Launcher logo">
</p>

<h1 align="center">Strata Launcher</h1>

<p align="center">
  Set up, run, benchmark and tune <a href="https://github.com/Niko1221/Strata">Strata</a> on Windows —<br>
  from a brand-new PC to Cline coding against your local model.
</p>

<p align="center">
  <img src="assets/screenshot-setup.png" width="820" alt="The Setup tab on a clean Windows install">
</p>

Strata runs the Qwen3.8-Flash-Next family of models locally on one graphics card plus system RAM.
Strata Launcher is a single PowerShell script with a native Windows window around it: it gets
everything Strata needs onto a new PC, starts and stops its model servers, benchmarks them, edits
their configs, saves and resumes conversations, and opens [Cline](https://github.com/cline/cline)
pointed at a running model with the right context limits. Nothing to build and nothing to install
first — it runs on the Windows PowerShell 5.1 that every Windows 10 and 11 has.

## Quick start

In PowerShell (no administrator rights needed):

```powershell
irm https://raw.githubusercontent.com/b1tninja/strata-launcher/main/install.ps1 | iex
```

That puts Strata Launcher in `%LOCALAPPDATA%\Programs\strata-launcher`, adds it to the Start menu
and the desktop, and starts it. Run the same line again to update it.

On first start it asks **where Strata is**. It lists the Strata folders it finds on the PC; pick
one, or choose an **empty or new folder** and it downloads Strata there. The **Setup** tab then
walks through everything else, one step at a time.

Already have a clone of this repository? `powershell -ExecutionPolicy Bypass -File install.ps1`
adds the shortcuts for it, or run it directly:

```powershell
powershell -STA -ExecutionPolicy Bypass -File strata-launcher.ps1 [-StrataRoot <folder>] [-FirstRun]
```

## Setting up a new PC

The **Setup** tab checks the PC and fetches what is missing. Nothing is installed until you press
a step's button, each one says what it will do first, and long steps run in a window of their own
while the list re-checks itself.

| Step | What it does |
| --- | --- |
| **winget** | The easiest way to get the tools below. A new Windows account gets it a few minutes after its first sign-in, and Windows without the Store (Windows Sandbox, LTSC) has none: **Set up winget** registers Windows' own App Installer, or installs it the way Microsoft documents for Sandbox. Every step below also works without it. |
| **Graphics card, memory, CPU, disk** | Checked against what Strata needs (an NVIDIA RTX 20 series or newer, or a supported Radeon; driver 580+ for NVIDIA; 32 GB of RAM; 60-190 GB of disk). Drivers are linked, never installed for you. |
| **Git** | What lets Strata update itself. Git for Windows through winget, or without winget MinGit, the portable Git, for your account only. |
| **Strata** | `git clone` of Strata (or its zip without Git). A clone shows how far it is behind GitHub, and **Update** runs Strata's own `UPDATE.bat`. A zip copy can be **made updatable** once Git is there. |
| **Python and a PC check** | Strata's own `START-HERE.bat --check`, which installs the Python version Strata pins for your account and creates its environment. |
| **A model** | Pick one from the catalog — with what each needs and whether it fits this PC — or let Strata choose the recommended size for your RAM. Strata downloads it from Hugging Face itself (58-190 GB, resumable). |
| **Node.js and Cline** | For **Open Cline**: Node.js through winget or its portable zip, then `npm install -g cline`. |
| **Shortcuts** | Desktop and Start menu. |

No administrator rights are needed for any of it, and no `gh` or Hugging Face command-line tool.

## Everyday use

| Tab | |
| --- | --- |
| **Launch** | Every installed model with its quant, context, port and live server status. Start and stop servers, open the web chat, the engine log (in a built-in viewer with live follow) or the config. Per-launch overrides for the context (with the rope scaling longer contexts need), the VRAM reserve and more — your config files are never changed. **Sessions**: save the conversation the engine holds to disk and restore it later, even into a restarted engine (**Hibernate** / **Resume**). **Open Cline** in any folder against the selected model. |
| **Benchmark** | Runs Strata's `strata_bench.py` against one or several models in turn, starting and stopping their servers, with live output. |
| **Results** | Every benchmark run as a table (decode and prompt speed, time to first token, cache hits); compare two side by side. |
| **Models** | Strata's model catalog with download size, disk and RAM needs against this PC, colour-coded by fit, and an install button. |
| **Service** | Runs one model on demand in the background: the server starts without loading the model, the first request loads it, and it unloads after an idle time so the graphics card is free. Optionally saves the conversation before unloading. |
| **Config** | A full editor for a model's `strata-*.json`: server settings (read from Strata's own settings schema), engine options with explanations, model files, any other engine arguments, and the raw JSON. Changes are listed and checked before saving, and the previous file is kept as `.bak`. **Save as new** makes a variant. |
| **Setup** | See above; also the place to update Strata. |

## Cline, done right

Strata never truncates a prompt: once a conversation outgrows the model's context, every request
fails. Cline only compacts a conversation against the limit it was told, and its own token count
runs a few percent under Strata's. **Open Cline** therefore tells Cline a limit with headroom —
10% of the context by default (the **Headroom** setting), never under 4,096 tokens — taken from what
the running server actually reports, and writes it everywhere Cline reads it, every time.

<details>
<summary>Why each of those details matters</summary>

- Cline compacts at 90% of the limit in its model entry, and skips automatic compaction entirely for
  a custom model with no limit. A guessed or stale limit is the one setting that can never be too high.
- With a flat 4,096-token reserve, Cline's log still showed prompts of 131,118-132,455 tokens sent
  to a 131,072-token server after it had been told 126,976: its estimate is ~4-5% low, so the reserve
  is a share of the context.
- Cline re-imports its legacy `globalState.json` into `providers.json` at every start, so the limit is
  written to `models.json`, `providers.json` and `globalState.json` on every launch.
- Those files are written as plain UTF-8: Windows PowerShell 5.1 adds a byte-order mark that Node's
  JSON parser rejects, and Cline then silently rebuilt its settings without any limit and with a
  30-second timeout.
</details>

## Sessions

Strata can write the engine's state for a conversation — KV cache, recurrent state, its
checkpoint — to a file and read it back. Measured on an RTX 5090 under Windows: a 27.5K-token
conversation took 16.0 s to read cold, saved in 0.6 s (626 MiB) and restored in 0.5 s into a
restarted engine, after which the next turn reused 27,545 tokens and read 19.

Session files need a session folder in the model's config (Config › Files › `slot_save_path`). A
file restores only into the same Strata version with the same context, KV and rope settings, and
Strata never deletes them (~24 KB per token).

## Where things are kept

- The Strata folder, model folder and this tool's folder: `HKCU\Software\StrataLauncher` (per user).
- Window settings: `strata-launcher.settings.json` next to the script (not part of the repository).
- Changed configs for a launch: `%TEMP%\strata-launcher`.
- Formerly named `strata-gui`: an existing install carries its settings, registry values and
  shortcuts over on first start.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\context-tests.ps1   # Cline limits, contexts, rope scaling
powershell -NoProfile -ExecutionPolicy Bypass -File tests\session-tests.ps1   # session files, stopping servers
powershell -NoProfile -ExecutionPolicy Bypass -File tests\check-paths.ps1     # shortcuts, no machine paths, no hidden code
powershell -NoProfile -ExecutionPolicy Bypass -File tests\sandbox\run-sandbox.ps1
```

The last one is the **first-time-user test**. In Windows Sandbox — a clean Windows with no winget,
Git, Python, Node.js or graphics driver — it installs Strata Launcher with the one-line installer,
goes through the first start, downloads Strata, installs Git, runs Strata's PC check (Python),
installs Node.js and Cline and sets up winget, checking each step and saving a log and
screenshots. It needs the Windows Sandbox feature (as administrator, then restart):

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

<details>
<summary>Implementation notes</summary>

- Everything is one file, `strata-launcher.ps1`, plus `cline-strata.ps1` (the Cline launcher it
  starts, usable on its own) and `install.ps1`.
- It only ever stops servers it recognises (its own, or a `/health` answer naming the config's
  model), and then their whole launch chain, so no window is left at "Press any key".
- Everything is downloaded with PowerShell's own `Invoke-WebRequest`, with its progress bar hidden.
  That matters in Windows PowerShell 5.1: the same 39 MB file took 0.5 s hidden (as fast as
  `curl.exe`), 26 s with the bar shown, and 30 MB took over 10 minutes in a clean Windows Sandbox. For
  that reason the PC check fetches the Python installer Strata's `START-HERE.bat` pins (its URL read
  from that file) when winget is missing, and installs it with Strata's own unattended options,
  before handing over to Strata — whose own download keeps the bar on.
- Installs follow each project's own unattended route: python.org's `/quiet InstallAllUsers=0
  PrependPath=1` (plus `InstallLauncherAllUsers=0`: otherwise the `py` launcher installs for all users,
  which needs an administrator and can leave a quiet install waiting, and `Include_doc=0
  Include_tcltk=0`: Strata uses neither, and in Windows Sandbox each Windows Installer package
  waits about two minutes on its signature check), MinGit (the Git that git-for-windows offers for tools), Node.js's prebuilt zip,
  `npm install -g cline`, and Microsoft's `Microsoft.WinGet.Client` module for winget itself.
- Every setup window records how it ended (`ok`, or `failed:` with the reason or exit code), so the
  Setup tab reports a failed step at once instead of waiting on it.
- Quoted paths handed to child processes are escaped so a trailing `\` can't swallow the closing
  quote (`QPath`).
- `assets\make-icons.ps1` draws the logo into `logo.png` and the window icon.
</details>
