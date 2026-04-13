@echo off
setlocal

set "ROOT=%~dp0"
set "CARGO_HOME=%ROOT%build\cargo-home"
set "RUSTUP_HOME=%ROOT%build\rustup-home"
set "RUSTUP_TOOLCHAIN=stable"
set "RUSTUP_PROFILE=minimal"

if not exist "%CARGO_HOME%" mkdir "%CARGO_HOME%" >nul 2>&1
if not exist "%RUSTUP_HOME%" mkdir "%RUSTUP_HOME%" >nul 2>&1

set "TOOLS_DIR=%ROOT%build\\tools"
set "SYSTEM_CARGO=C:\Users\filin\.cargo\bin\cargo.exe"
set "SYSTEM_RUSTUP=C:\Users\filin\.cargo\bin\rustup.exe"
set "CARGO=%TOOLS_DIR%\\cargo.exe"
set "RUSTUP=%TOOLS_DIR%\\rustup.exe"
if not exist "%TOOLS_DIR%" mkdir "%TOOLS_DIR%" >nul 2>&1

if not exist "%CARGO%" (
    if exist "%SYSTEM_CARGO%" copy "%SYSTEM_CARGO%" "%CARGO%" >nul 2>&1
)

if not exist "%RUSTUP%" (
    if exist "%SYSTEM_RUSTUP%" copy "%SYSTEM_RUSTUP%" "%RUSTUP%" >nul 2>&1
)
if not exist "%CARGO%" (
    echo ERROR: cargo not found. Expected %CARGO% or %SYSTEM_CARGO%
    exit /b 1
)

"%RUSTUP%" toolchain install %RUSTUP_TOOLCHAIN% --profile %RUSTUP_PROFILE% >nul 2>&1

set "ARGS=%*"
echo %ARGS% | findstr /I "tabburrito-lite\\src-tauri\\Cargo.toml" >nul
if %ERRORLEVEL%==0 (
    set "CARGO_TARGET_DIR=%ROOT%build\\cargo-target-firefox-lite"
) else (
    set "CARGO_TARGET_DIR=%ROOT%build\\cargo-target-webview2"
)

"%RUSTUP%" run %RUSTUP_TOOLCHAIN% "%CARGO%" %*
