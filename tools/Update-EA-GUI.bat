@echo off
REM RiskManager EA updater - windowed. Double-click this file.
REM The console version is Update-EA.bat; this one shows what it did.
setlocal
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Update-EA-GUI.ps1"
