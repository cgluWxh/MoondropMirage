@echo off
setlocal
cd /d "%~dp0"

if not exist .venv\Scripts\python.exe (
  echo [ERROR] Run setup.bat first.
  pause
  exit /b 1
)

.venv\Scripts\python.exe windows_mirage.py
if errorlevel 1 pause
