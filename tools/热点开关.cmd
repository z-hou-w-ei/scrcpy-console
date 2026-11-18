@echo off
chcp 65001 >nul
set "HERE=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%..\src\hotspot.ps1" -Action toggle
ping -n 2 127.0.0.1 >nul
