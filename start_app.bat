@echo off
echo Stopping existing Tabburrito instances...
taskkill /IM tabburrito.exe /F >nul 2>&1
timeout /t 2 /nobreak >nul
echo Starting Tabburrito...
start "" "%~dp0src-tauri\target\debug\tabburrito.exe"
echo Tabburrito started.
