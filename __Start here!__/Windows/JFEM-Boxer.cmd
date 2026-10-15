@echo off
setlocal DisableDelayedExpansion
call "%~dp0..\..\JFEM-Boxer.cmd" %*
exit /b %errorlevel%
