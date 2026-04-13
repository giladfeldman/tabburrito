@echo off
setlocal

set "ROOT=%~dp0"
set "PROJECT_ROOT=%ROOT%.."
set "RELEASE_EXE=%ROOT%src-tauri\target\release\tabburrito-lite.exe"
set "DEBUG_EXE=%ROOT%src-tauri\target\debug\tabburrito-lite.exe"
set "CARGO_LOCAL=%PROJECT_ROOT%\build_local.bat"

echo Starting Tabburrito Lite shell...

if exist "%RELEASE_EXE%" (
    start "" "%RELEASE_EXE%"
    exit /b 0
)

if exist "%DEBUG_EXE%" (
    start "" "%DEBUG_EXE%"
    exit /b 0
)

if exist "%CARGO_LOCAL%" (
    echo No built executable found. Running cargo build first...
    "%CARGO_LOCAL%" run --manifest-path "%ROOT%src-tauri\Cargo.toml"
    exit /b %ERRORLEVEL%
)

echo ERROR: Could not find a Tabburrito Lite executable or cargo.
pause
exit /b 1
