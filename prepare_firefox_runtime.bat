@echo off
setlocal

set "ROOT=%~dp0"
set "SRC_FIREFOX=%ProgramFiles%\Mozilla Firefox"
set "DEST_DIR=%ROOT%build\cargo-target-firefox-lite\release\TabburritoFirefox"
set "DEST_EXE=%DEST_DIR%\tabburrito-browser.exe"
set "RCEDIT=%ROOT%build\tools\rcedit-x64.exe"
set "ICON=%ROOT%tabburrito-lite\src-tauri\icons\icon.ico"

if not exist "%SRC_FIREFOX%\firefox.exe" (
    echo ERROR: Installed Firefox was not found at "%SRC_FIREFOX%".
    exit /b 1
)

if not exist "%ROOT%build\tools" mkdir "%ROOT%build\tools"

if not exist "%RCEDIT%" (
    echo Downloading rcedit...
    powershell -NoProfile -Command ^
        "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest 'https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe' -OutFile '%RCEDIT%'"
    if errorlevel 1 exit /b 1
)

if not exist "%DEST_DIR%" mkdir "%DEST_DIR%"

echo Copying Firefox runtime into project-local Tabburrito runtime...
robocopy "%SRC_FIREFOX%" "%DEST_DIR%" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 exit /b %errorlevel%

if exist "%DEST_DIR%\tabburrito-browser.exe" del /f /q "%DEST_DIR%\tabburrito-browser.exe"
if exist "%DEST_DIR%\firefox.exe" ren "%DEST_DIR%\firefox.exe" "tabburrito-browser.exe"

if exist "%DEST_DIR%\firefox.exe.sig" del /f /q "%DEST_DIR%\firefox.exe.sig"
if exist "%DEST_DIR%\tabburrito-browser.VisualElementsManifest.xml" del /f /q "%DEST_DIR%\tabburrito-browser.VisualElementsManifest.xml"
if exist "%DEST_DIR%\firefox.VisualElementsManifest.xml" ren "%DEST_DIR%\firefox.VisualElementsManifest.xml" "tabburrito-browser.VisualElementsManifest.xml"

echo Patching Tabburrito browser identity...
"%RCEDIT%" "%DEST_EXE%" ^
  --set-icon "%ICON%" ^
  --set-version-string "FileDescription" "Tabburrito Browser" ^
  --set-version-string "ProductName" "Tabburrito Browser" ^
  --set-version-string "InternalName" "tabburrito-browser.exe" ^
  --set-version-string "OriginalFilename" "tabburrito-browser.exe" ^
  --set-version-string "CompanyName" "Tabburrito" ^
  --set-version-string "LegalCopyright" "Tabburrito"
if errorlevel 1 exit /b %errorlevel%

echo Tabburrito browser runtime prepared:
echo %DEST_EXE%
