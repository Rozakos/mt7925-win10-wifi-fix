@echo off
REM Self-elevating launcher for the MT7925 Wi-Fi Fix GUI.
REM Double-click this file. It requests Administrator, then opens the GUI.

set "SCRIPT=%~dp0MT7925-Fix-GUI.ps1"

REM Already elevated?
net session >nul 2>&1
if %errorlevel% == 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
    goto :eof
)

REM Not elevated: relaunch this batch elevated via a UAC prompt.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
