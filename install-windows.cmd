@echo off
rem Double-click to install lockwatch. Pass -Uninstall to remove it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1" %*
if errorlevel 1 pause
