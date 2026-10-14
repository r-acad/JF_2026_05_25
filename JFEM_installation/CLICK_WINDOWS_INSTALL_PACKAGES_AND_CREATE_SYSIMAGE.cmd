@echo off
setlocal
REM Compatibility entry: canonical setup owns dependencies, verification and build.
call "%~dp0..\setup.cmd" --sysimage %*
set "JFEM_SETUP_EXIT=%errorlevel%"
if not "%OPENJFEM_NO_PAUSE%"=="1" pause
exit /b %JFEM_SETUP_EXIT%
