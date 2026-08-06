@echo off
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :run
) else (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:run
powershell -ExecutionPolicy Bypass -File "%~dp0install.ps1"
pause
