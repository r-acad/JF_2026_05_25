@echo off
setlocal DisableDelayedExpansion
call "%~dp0JFEM-Boxer.cmd" %*
exit /b %errorlevel%
