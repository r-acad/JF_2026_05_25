@echo off
setlocal DisableDelayedExpansion
call "%~dp0APPS\PANDEATOR_APP\RUN_PANDEATOR_WINDOWS.cmd" %*
exit /b %errorlevel%
