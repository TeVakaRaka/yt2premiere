@echo off
chcp 65001 >nul
rem Запускает графическое окно yt2premiere без консоли
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0yt2premiere-gui.ps1"
