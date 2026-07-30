@echo off
REM One-click EA updater. Double-click this file.
REM Pass "mq4" as an argument to update the MetaTrader 4 build instead.
setlocal
set PLATFORM=%1
if "%PLATFORM%"=="" set PLATFORM=mq5
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-EA.ps1" -Platform %PLATFORM%
