@echo off
setlocal

set "ROOT=%~dp0"
set "CARGO=%ROOT%build_local.bat"

if not exist "%CARGO%" (
    echo ERROR: build_local.bat not found. Run from the project root.
    exit /b 1
)

set "DO_LITE=0"
set "DO_WEBVIEW2=0"
set "DO_TESTOPEN=0"

if "%~1"=="" (
    set "DO_LITE=1"
    set "DO_WEBVIEW2=1"
    set "DO_TESTOPEN=1"
) else (
    for %%A in (%*) do (
        if /I "%%A"=="all" set "DO_LITE=1" & set "DO_WEBVIEW2=1" & set "DO_TESTOPEN=1"
        if /I "%%A"=="lite" set "DO_LITE=1"
        if /I "%%A"=="webview2" set "DO_WEBVIEW2=1"
        if /I "%%A"=="testopen" set "DO_TESTOPEN=1"
    )
)

if "%DO_LITE%"=="1" (
    echo Building Firefox Lite release...
    "%CARGO%" build --release --manifest-path "%ROOT%tabburrito-lite\src-tauri\Cargo.toml"
    if errorlevel 1 exit /b %errorlevel%
    call "%ROOT%prepare_firefox_runtime.bat"
    if errorlevel 1 exit /b %errorlevel%
)

if "%DO_WEBVIEW2%"=="1" (
    echo Building WebView2 release...
    "%CARGO%" build --release --manifest-path "%ROOT%src-tauri\Cargo.toml"
    if errorlevel 1 exit /b %errorlevel%
)

if "%DO_TESTOPEN%"=="1" (
    echo Building testopen release...
    "%CARGO%" build --release --manifest-path "%ROOT%testopen\Cargo.toml"
    if errorlevel 1 exit /b %errorlevel%
)

echo.
echo Done.
echo Firefox Lite: build\cargo-target-firefox-lite\release\tabburrito-lite.exe
echo Firefox Runtime: build\cargo-target-firefox-lite\release\TabburritoFirefox\tabburrito-browser.exe
echo WebView2:     build\cargo-target-webview2\release\tabburrito.exe
echo testopen:     build\cargo-target-webview2\release\testopen.exe
