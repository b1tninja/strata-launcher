# Troubleshooting

**"Windows protected your PC" when opening the setup file.** The file is not code-signed, so
SmartScreen does not know it. Choose **More info › Run anyway**, or use the one-line install in
PowerShell instead. The setup file only runs that same line.

**A setup step failed.** Its window stays open with the reason, and the Setup tab's status line
repeats it and offers the step again. Each window's full output is in
`%TEMP%\strata-launcher\setup-<step>.log`.

**"No NVIDIA or AMD graphics card found."** Strata needs one: an NVIDIA RTX 20 series or newer with
driver 580 or newer, or a supported Radeon, with 12 GB of VRAM or more. Install the driver from the
link in the Setup tab, then press **Check again**. A virtual machine or Windows Sandbox has no
graphics card for Strata.

**The PC check is slow.** Python through uv takes seconds. If uv cannot be downloaded (a proxy, or
GitHub blocked), the step says so and Strata's `START-HERE.bat` installs Python its own way:
winget, or python.org's installer, which on a new PC can take 10-15 minutes and prints nothing while
it works. Strata's packages (NVIDIA's CUDA libraries among them) are several GB either way.

**Strata says it is behind GitHub, or Update is missing.** A zip copy of Strata cannot update
itself: install Git in the Setup tab, then **Make it updatable**.

**Cline: "context window exceeded", or it never compacts.** Open Cline from Strata Launcher (or
`cline-strata.ps1`) rather than on its own, so it is given the running server's real limit. Raise
the **Headroom** setting if a long conversation still overflows. [Details](using.md#cline)

**Cline compacts long before the context is full.** Expected, and not the launcher's limit: Cline
compacts at 90% of the limit by its own estimate (characters / 3), which runs ~30% high on code with
Qwen, so a 512K window compacts around 330-360K real tokens. The Headroom setting (2%) is already the
smallest that is safe; the rest is Cline's estimate.

**A server will not stop, or another one stops.** Strata Launcher only stops servers it recognises
(its own, or one whose `/health` names the selected config's model). A server started elsewhere on
the same port with another model is left alone; stop it where it was started.

**The window does not open.** Run it from PowerShell to see the error:

```powershell
powershell -STA -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\strata-launcher\strata-launcher.ps1"
```

Still stuck? [Open an issue](https://github.com/b1tninja/strata-launcher/issues) with the error and
the setup log.
