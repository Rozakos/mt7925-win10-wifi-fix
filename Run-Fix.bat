@echo off
REM Double-click launcher for Fix-MT7925-WiFi.ps1 — self-elevates to Administrator.
setlocal
set "PS1=%~dp0Fix-MT7925-WiFi.ps1"

REM Check for admin; if not elevated, relaunch this batch elevated.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
echo.
echo ============================================================
echo If test signing was just enabled, REBOOT and run this again.
echo ============================================================
pause
