@echo off
rem Strata Launcher setup: double-click to install. It downloads Strata Launcher into
rem %LOCALAPPDATA%\Programs\strata-launcher, adds it to the Start menu and the desktop, and starts it.
rem No administrator rights needed. Run it again to update. It is the same as the one-line install:
rem   irm https://raw.githubusercontent.com/b1tninja/strata-launcher/main/install.ps1 | iex
title Strata Launcher setup
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; $ProgressPreference = 'SilentlyContinue'; irm https://raw.githubusercontent.com/b1tninja/strata-launcher/main/install.ps1 | iex; Start-Sleep 4"
if errorlevel 1 (
    echo.
    echo Setup did not finish; the message above says why.
    pause
    exit /b 1
)
