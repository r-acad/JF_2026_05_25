@echo off
setlocal DisableDelayedExpansion
call "%~dp0..\..\APPS\JFEM-Boxer\Windows\JFEM-Boxer.cmd" %*
exit /b %errorlevel%
