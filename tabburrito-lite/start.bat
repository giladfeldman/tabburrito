@echo off
setlocal

:: Tabburrito Lite — Firefox-based multi-service launcher
:: Uses a dedicated Firefox profile with optimized settings

set "PROFILE_DIR=%APPDATA%\TabburritoLite\profile"
set "FIREFOX=C:\Program Files\Mozilla Firefox\firefox.exe"
set "SCRIPT_DIR=%~dp0"

:: Check Firefox exists
if not exist "%FIREFOX%" (
    echo ERROR: Firefox not found at %FIREFOX%
    echo Please install Firefox from https://www.mozilla.org/firefox/
    pause
    exit /b 1
)

:: Create profile directory if first run
if not exist "%PROFILE_DIR%" (
    echo First run — setting up Tabburrito Lite profile...
    mkdir "%PROFILE_DIR%"

    :: Copy optimized user.js
    copy "%SCRIPT_DIR%user.js" "%PROFILE_DIR%\user.js" >nul

    :: Create pinned tabs handler — on first launch, open all services
    :: After that, session restore (browser.startup.page=3) handles it
    echo Starting Firefox with initial tabs...
    start "" "%FIREFOX%" --profile "%PROFILE_DIR%" --no-remote ^
        "https://web.whatsapp.com" ^
        "https://www.messenger.com" ^
        "https://www.linkedin.com/feed/" ^
        "https://bsky.app" ^
        "https://accounts.google.com/ServiceLogin?continue=https://calendar.google.com/calendar/u/0/r?hl%%3Den&hl=en"

    echo.
    echo ================================================================
    echo  FIRST RUN SETUP:
    echo  1. Firefox is opening with your 5 services
    echo  2. Right-click each tab and select "Pin Tab" to keep them
    echo  3. Install uBlock Origin: visit addons.mozilla.org/addon/ublock-origin
    echo  4. Close and re-run this script — tabs will be restored
    echo ================================================================
    echo.
    pause
    exit /b 0
)

:: Normal launch — just open Firefox with our profile
:: Session restore will bring back all pinned tabs
:: --no-remote ensures this is a separate Firefox instance
start "" "%FIREFOX%" --profile "%PROFILE_DIR%" --no-remote

exit /b 0
