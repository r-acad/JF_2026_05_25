@echo off
setlocal DisableDelayedExpansion
call "%~dp0..\..\APPS\JFEM_results_viewer\Windows\Results-viewer.cmd" %*
exit /b %errorlevel%
