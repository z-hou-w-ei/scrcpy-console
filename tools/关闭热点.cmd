@echo off
chcp 65001 >nul
set "HERE=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%..\src\hotspot.ps1" -Action stop
if errorlevel 1 pause
