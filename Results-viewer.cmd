@echo off
setlocal DisableDelayedExpansion
set "VIEWER_JULIA=%JFEM_JULIA%"
if not defined VIEWER_JULIA set "VIEWER_JULIA=julia"
where "%VIEWER_JULIA%" >nul 2>&1
if errorlevel 1 if not exist "%VIEWER_JULIA%" (
  echo Julia was not found. Opening the offline WebGL viewer directly.
  start "" "%~dp0APPS\JFEM_results_viewer\postv11.html"
  exit /b 0
)
echo Starting the results viewer. Keep this console open; Ctrl+C stops it.
"%VIEWER_JULIA%" --startup-file=no --threads=1 --project="%~dp0." "%~dp0utils\julia_tools\serve_results_viewer.jl" %*
set "VIEWER_EXIT=%errorlevel%"
if not "%VIEWER_EXIT%"=="0" if not "%OPENJFEM_NO_PAUSE%"=="1" pause
exit /b %VIEWER_EXIT%
