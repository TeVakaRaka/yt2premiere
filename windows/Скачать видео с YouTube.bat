@echo off
chcp 65001 >nul
title YouTube -^> Premiere Pro
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0yt2premiere.ps1"
echo.
pause
