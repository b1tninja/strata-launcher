# Contributing

Issues and pull requests are welcome. Strata Launcher is plain Windows PowerShell 5.1 with WPF:
no build step, nothing to install. Keep it that way: no modules, and nothing beyond what Windows 10
and 11 ship.

## Layout

- `strata-launcher.ps1`: the whole app (window, tabs, setup steps).
- `cline-strata.ps1`: opens Cline against a running Strata server; the app starts it, and it works
  on its own.
- `install.ps1`: the one-line installer (also `-Uninstall`); `strata-launcher-setup.cmd` runs it for
  people who would rather double-click.
- `assets/`: the logo, the icon and `make-icons.ps1`, which draws them.

## Tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\context-tests.ps1   # Cline limits, contexts, rope scaling
powershell -NoProfile -ExecutionPolicy Bypass -File tests\session-tests.ps1   # session files, stopping servers
powershell -NoProfile -ExecutionPolicy Bypass -File tests\check-paths.ps1     # shortcuts, no machine paths, no hidden code
powershell -NoProfile -ExecutionPolicy Bypass -File tests\sandbox\run-sandbox.ps1 [-Local]
```

The last one is the **first-time-user test**. In Windows Sandbox (a clean Windows with no winget,
Git, Python, Node.js or graphics driver) it installs Strata Launcher with the setup file, goes
through the first start, downloads Strata, installs Git, runs the PC check (Python through uv),
makes Strata updatable, installs Node.js and Cline and sets up winget, checking each step and saving
a log and screenshots (`window-setup.png` is the README's screenshot). Without `-Local` it installs
from GitHub's `main`, so push first; `-Local` uses your working copy. While it runs,
`tests\sandbox\peek-sandbox.ps1` shows what is happening inside. It needs Windows 11 24H2 or newer
with the Windows Sandbox feature (as administrator, then restart):

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

## Implementation notes

- It only ever stops servers it recognises (its own, or a `/health` answer naming the config's
  model), and then their whole launch chain, so no window is left at "Press any key".
- Downloads use PowerShell's own `Invoke-WebRequest` with its progress bar hidden. In Windows
  PowerShell 5.1 that matters: the same 39 MB file took 0.5 s hidden (as fast as `curl.exe`), 26 s
  with the bar shown, and 30 MB took over 10 minutes in Windows Sandbox.
- Python comes from uv (its release zip, checked against its published SHA-256), which creates
  Strata's `.venv` with the Python version `START-HERE.bat` pins. `START-HERE.bat` skips its own
  Python install when `.venv` exists. Its own route (winget or python.org's installer) is a set of
  Windows Installer packages; in Windows Sandbox each one waited two minutes on Windows Installer's
  policy check, about 15 minutes in all. It stays as the fallback when uv cannot be had.
- Every setup window records how it ended (`ok`, or `failed:` with the reason or exit code), so the
  Setup tab reports a failed step at once instead of waiting on it.
- Files Node reads (Cline's settings) are written as UTF-8 without a byte-order mark; scripts
  Windows PowerShell runs are written with one, so it reads them as UTF-8.
- Quoted paths handed to child processes are escaped so a trailing `\` can't swallow the closing
  quote (`QPath`).
