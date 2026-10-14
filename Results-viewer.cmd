@echo off
setlocal DisableDelayedExpansion
start "" "%~dp0APPS\JFEM_results_viewer\postv11.html"
exit /b %errorlevel%
