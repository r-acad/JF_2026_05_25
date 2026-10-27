@echo off
setlocal DisableDelayedExpansion
call "%~dp0..\..\APPS\JFEM-solver\Windows\JFEM-solver.cmd" %*
exit /b %errorlevel%
