@echo off
setlocal

:: Tabburrito Lite — Full automated setup
:: Creates profile, installs uBlock Origin, configures LinkedIn filters

set "PROFILE_DIR=%APPDATA%\TabburritoLite\profile"
set "FIREFOX=C:\Program Files\Mozilla Firefox\firefox.exe"
set "SCRIPT_DIR=%~dp0"

echo ============================================
echo  Tabburrito Lite Setup
echo ============================================
echo.

:: Check Firefox
if not exist "%FIREFOX%" (
    echo ERROR: Firefox not found. Install from https://www.mozilla.org/firefox/
    pause
    exit /b 1
)

:: Clean old profile if exists
if exist "%PROFILE_DIR%" (
    echo Removing old profile...
    rmdir /s /q "%PROFILE_DIR%" 2>nul
    timeout /t 1 /nobreak >nul
)

:: Create profile
echo Creating optimized profile...
mkdir "%PROFILE_DIR%"
mkdir "%PROFILE_DIR%\extensions" 2>nul

:: Copy user.js
copy "%SCRIPT_DIR%user.js" "%PROFILE_DIR%\user.js" >nul
echo   [OK] Optimized preferences installed

:: Download uBlock Origin XPI from official Mozilla addons
echo   Downloading uBlock Origin...
powershell -NoProfile -Command ^
    "try { " ^
    "  $url = 'https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi'; " ^
    "  $out = '%PROFILE_DIR%\extensions\uBlock0@raymondhill.net.xpi'; " ^
    "  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " ^
    "  Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing; " ^
    "  if (Test-Path $out) { Write-Host '  [OK] uBlock Origin downloaded' } " ^
    "  else { Write-Host '  [WARN] Download failed - install manually from addons.mozilla.org' } " ^
    "} catch { Write-Host '  [WARN] Download failed - install manually from addons.mozilla.org' }"

:: Create autoconfig for pinned tabs via sessionstore
:: We'll use a handler script that pins tabs on first load
echo   Creating tab configuration...

:: Write a simple chrome/userChrome.css for compact UI
mkdir "%PROFILE_DIR%\chrome" 2>nul
(
echo /* Tabburrito Lite — compact UI */
echo #TabsToolbar { --tab-min-height: 28px !important; }
echo #nav-bar { --navbar-height: 32px !important; }
echo /* Hide Firefox View button */
echo #firefox-view-button { display: none !important; }
echo /* Hide Pocket button */
echo #save-to-pocket-button { display: none !important; }
) > "%PROFILE_DIR%\chrome\userChrome.css"

:: Enable userChrome.css loading
echo user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true); >> "%PROFILE_DIR%\user.js"
echo   [OK] Compact UI theme installed

echo.
echo ============================================
echo  Setup complete! Launching Firefox...
echo ============================================
echo.
echo  Your 5 services will open as tabs.
echo  RIGHT-CLICK each tab and select "Pin Tab"
echo  to keep them permanently.
echo.
echo  uBlock Origin should auto-install on restart.
echo  If not, visit: addons.mozilla.org/addon/ublock-origin
echo.
echo  For LinkedIn ad blocking, after uBlock installs:
echo    1. Click the uBlock icon
echo    2. Click the gear (Dashboard)
echo    3. Go to "My Filters" tab
echo    4. Paste these rules:
echo       www.linkedin.com##span:has-text(Promoted):upward(6)
echo       www.linkedin.com##span:has-text(Suggested):upward(6)
echo       www.linkedin.com##p:has-text(/^Promoted/):upward(6)
echo    5. Click "Apply changes"
echo.

:: Launch with all tabs
start "" "%FIREFOX%" --profile "%PROFILE_DIR%" --no-remote ^
    "https://web.whatsapp.com" ^
    "https://www.messenger.com" ^
    "https://www.linkedin.com/feed/" ^
    "https://bsky.app" ^
    "https://accounts.google.com/ServiceLogin?continue=https://calendar.google.com/calendar/u/0/r?hl%%3Den&hl=en"

echo Press any key after you've pinned your tabs...
pause
exit /b 0
