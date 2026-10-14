@echo off
setlocal
set "JFEM_SETUP_JULIA=%JFEM_JULIA%"
if not defined JFEM_SETUP_JULIA set "JFEM_SETUP_JULIA=julia"
where "%JFEM_SETUP_JULIA%" >nul 2>&1
if errorlevel 1 if not exist "%JFEM_SETUP_JULIA%" (
  echo Julia was not found. Install it from https://julialang.org/downloads/ then reopen this terminal.
  echo You can also set JFEM_JULIA to an installed Julia executable.
  exit /b 1
)
"%JFEM_SETUP_JULIA%" --startup-file=no --project="%~dp0." "%~dp0JFEM_installation\julia_tools\install_julia_packages.jl" %*
exit /b %errorlevel%
