# Setting up a PC

The **Setup** tab checks the PC and fetches what is missing. Nothing is installed until you press
a step's button, each one says what it will do first, and long steps run in a window of their own
while the list re-checks itself. No step needs administrator rights, `gh` or a Hugging Face
command-line tool.

| Step | What it does |
| --- | --- |
| **winget** | The easiest way to get Git and Node.js. A new Windows account gets it a few minutes after its first sign-in; Windows without the Store (Windows Sandbox, LTSC) has none. **Set up winget** registers Windows' own App Installer, or installs it the way Microsoft documents for those. Every step below also works without it. |
| **Graphics card, memory, CPU, disk** | Checked against what Strata needs: an NVIDIA RTX 20 series or newer (driver 580+) or a supported Radeon, 32 GB of RAM, 60-190 GB of disk. Drivers are linked, never installed for you. |
| **Git** | What lets Strata update itself. Git for Windows through winget, or MinGit, the portable Git, for your account only. |
| **Strata** | A `git clone` of Strata, or its zip without Git. A clone shows how far it is behind GitHub, and **Update** runs Strata's own `UPDATE.bat`. A zip copy can be **made updatable** once Git is there. |
| **Python and a PC check** | Python through [uv](https://github.com/astral-sh/uv): one small program that downloads a standalone copy of the Python version Strata pins and creates Strata's `.venv` with it, in seconds and without an installer. Then Strata's own `START-HERE.bat --check` installs its packages and reports what this PC can run. |
| **A model** | Pick one from the **Models** tab, with what each needs and whether it fits this PC, or let Strata choose the recommended size for your RAM. Strata downloads it from Hugging Face itself (58-190 GB, resumable). |
| **Node.js and Cline** | For **Open Cline**: Node.js through winget or its portable zip, then `npm install -g cline`. |
| **Shortcuts** | Desktop and Start menu. |

On first start, Strata Launcher lists the Strata folders it finds on the PC. Choose an empty or new
folder instead and it offers to download Strata there.

## What goes where

| What | Where |
| --- | --- |
| Strata Launcher | `%LOCALAPPDATA%\Programs\strata-launcher` (or the clone you run it from) |
| Its folders (Strata, models, itself) | `HKCU\Software\StrataLauncher` |
| Window settings | `strata-launcher.settings.json` next to the script |
| Setup windows' logs, changed configs for a launch | `%TEMP%\strata-launcher` |
| uv | `%LOCALAPPDATA%\Programs\uv` (its Python under `%APPDATA%\uv\python`) |
| MinGit (without winget) | `%LOCALAPPDATA%\Programs\MinGit`, on your PATH |
| Node.js (without winget) | `%LOCALAPPDATA%\Programs\nodejs`, on your PATH; Cline under `%APPDATA%\npm` |
| Strata, its `.venv`, configs | the Strata folder you chose |
| Models | the model folder you chose (`Strata-data` by default) |

A copy of this tool from before its rename (`strata-gui`) carries its settings, registry values and
shortcuts over on first start.

## Updating

Run the setup file or the one-line install again. Strata itself updates from the **Setup** tab
(**Update**), through Strata's own `UPDATE.bat`.

## Removing models

Models are what take the space (58-190 GB each). In the **Models** tab, select an installed model
(**Installed: yes**) and press **Remove...**; or select it in the list at the top and press **Launch
› Remove model...**. Strata itself works out what belongs to that model alone: all parts of its
files, their download marks and partial downloads, its config, `.bak`, log and `run-*.bat`. Files
another installed model still uses stay, and so do files of your own outside Strata's folders. The
confirmation lists what is deleted and kept, and how much it frees. A running model, or the
**Service** tab's model, has to be stopped or removed from the service first. Session files are
kept. This needs a Strata from late October 2026 or newer: update an older one in the Setup tab
first.

## Uninstall

**Settings › Apps › Installed apps › Strata Launcher › Uninstall**, or in PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/b1tninja/strata-launcher/main/install.ps1))) -Uninstall
```

That closes Strata Launcher and removes its folder in `%LOCALAPPDATA%\Programs`, its shortcuts, its
registry key and the **Service** tab's background task. Strata, the models and the tools from the
Setup tab stay: remove models in the app first if you want the space back, and the rest from the
table above (Git and Node.js from winget through **Settings › Apps**, Strata by deleting its folder).
