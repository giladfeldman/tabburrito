@echo off
setlocal

set "ROOT=%~dp0"
set "APP_DIR=%ROOT%TabburritoLite"
set "PROFILE_DIR=%APP_DIR%\profile"

echo ============================================
echo  Tabburrito Lite Setup
echo ============================================
echo.
echo This will start the isolated Tabburrito Firefox shell.
echo Your primary Firefox profile will not be touched.
echo.

if exist "%PROFILE_DIR%" (
    echo Existing Tabburrito profile found at:
    echo   %PROFILE_DIR%
    echo.
    echo If you want a completely fresh isolated profile,
    echo use the "Reset Isolated Profile" tray action after launch.
    echo.
)

call "%ROOT%start.bat"
exit /b %ERRORLEVEL%
