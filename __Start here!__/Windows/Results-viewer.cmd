@echo off
setlocal DisableDelayedExpansion
call "%~dp0..\..\Results-viewer.cmd" %*
exit /b %errorlevel%
