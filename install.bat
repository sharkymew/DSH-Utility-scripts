@echo off
rem DeepSeek Harness installer - Windows entry point (double-click friendly)
rem Runs install.ps1 with the execution policy bypassed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %errorlevel%
