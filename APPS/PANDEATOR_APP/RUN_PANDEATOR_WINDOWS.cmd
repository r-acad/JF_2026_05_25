@echo off
setlocal DisableDelayedExpansion
set "PANEL_JULIA=%JFEM_JULIA%"
if not defined PANEL_JULIA set "PANEL_JULIA=julia"
echo Starting PANDEATOR. Keep this terminal open; Ctrl+C stops it.
"%PANEL_JULIA%" --startup-file=no --threads=1 "%~dp0..\..\utils\julia_tools\launch.jl" solver "%~dp0..\.." "%~dp0panel_launch.jl" %*
set "JFEM_EXIT=%errorlevel%"
if not "%OPENJFEM_NO_PAUSE%"=="1" pause
exit /b %JFEM_EXIT%
