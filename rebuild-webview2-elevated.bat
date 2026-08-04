@echo off
:: Rebuild Tabburrito WebView2 and reinstall it.
::
:: This used to build into build\cargo-target-webview2\release\ and keep sessions
:: beside the exe there. That layout destroyed every logged-in session on
:: 2026-08-04 when the build cache was cleaned - a cargo target directory is
:: disposable by definition. It now delegates to the installer, which builds to
:: %LOCALAPPDATA%\TabburritoBuild and installs to %LOCALAPPDATA%\Programs\Tabburrito,
:: leaving sessions untouched in %LOCALAPPDATA%\Tabburrito.
::
:: No elevation required - this is a per-user install.

setlocal EnableExtensions
set "ROOT=%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%install\Update-Tabburrito.ps1" -Force
set "EC=%ERRORLEVEL%"

if not "%EC%"=="0" (
  echo.
  echo Rebuild/install failed with exit code %EC%.
  echo Log: %LOCALAPPDATA%\TabburritoBuild\update.log
  echo.
  echo If you see "Application Control policy has blocked" / os error 4551:
  echo   that is Smart App Control blocking unsigned cargo build scripts.
  echo   Elevation does NOT fix that. Options: turn SAC Off, or build on another PC.
  pause
  exit /b %EC%
)

echo.
echo Done. Sessions untouched: %LOCALAPPDATA%\Tabburrito\TabburritoWebViewData
pause
exit /b 0
