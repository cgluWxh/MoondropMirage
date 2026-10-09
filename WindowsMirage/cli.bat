@echo off
setlocal
cd /d "%~dp0"
python.exe mirage_cli.py %*
exit /b %errorlevel%
