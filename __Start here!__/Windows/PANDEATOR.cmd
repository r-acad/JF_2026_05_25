@echo off
setlocal DisableDelayedExpansion
call "%~dp0..\..\APPS\PANDEATOR_APP\Windows\PANDEATOR.cmd" %*
exit /b %errorlevel%
