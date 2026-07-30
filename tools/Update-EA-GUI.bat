@echo off
REM RiskManager EA updater - windowed. Double-click this file.
REM The console version is Update-EA.bat; this one shows what it did.
setlocal

if not exist "%~dp0Update-EA-GUI.ps1" (
  echo.
  echo   Update-EA-GUI.ps1 is missing from this folder.
  echo   Run Update-EA.bat once - it downloads the windowed updater.
  echo.
  pause
  exit /b 1
)

REM -WindowStyle Hidden keeps the console out of the way. The .ps1 traps its
REM own startup errors into a message box, so a failure is never silent.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Update-EA-GUI.ps1"
