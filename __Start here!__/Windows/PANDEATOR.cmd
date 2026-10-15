@echo off
setlocal DisableDelayedExpansion
call "%~dp0..\..\PANDEATOR.cmd" %*
exit /b %errorlevel%
