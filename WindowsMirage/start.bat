@echo off
setlocal
cd /d "%~dp0"

python.exe windows_mirage.py
if errorlevel 1 pause
