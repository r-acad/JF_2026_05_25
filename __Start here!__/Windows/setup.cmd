@echo off
setlocal DisableDelayedExpansion
call "%~dp0..\..\setup.cmd" %*
exit /b %errorlevel%
