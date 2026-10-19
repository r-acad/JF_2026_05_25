@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_public_validation.ps1" %*
set "validation_exit=%errorlevel%"
if not "%validation_exit%"=="0" echo Validation stopped with code %validation_exit%.
pause
exit /b %validation_exit%
