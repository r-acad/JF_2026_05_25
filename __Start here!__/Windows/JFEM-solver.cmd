@echo off
setlocal DisableDelayedExpansion
call "%~dp0..\..\JFEM-solver.cmd" %*
exit /b %errorlevel%
