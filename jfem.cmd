@echo off
setlocal DisableDelayedExpansion
set "JFEM_BIN=%JFEM_JULIA%"
if not defined JFEM_BIN set "JFEM_BIN=julia"
where "%JFEM_BIN%" >nul 2>&1
if errorlevel 1 if not exist "%JFEM_BIN%" (
  echo Julia was not found. Install Julia and run setup.cmd.
  exit /b 1
)
if "%~1"=="" (
  echo usage: jfem [-formats] model.bdf [output_folder]
  exit /b 1
)
"%JFEM_BIN%" --startup-file=no --threads=1 "%~dp0utils\julia_tools\launch.jl" solver "%~dp0." "%~dp0utils\julia_tools\jfem.jl" %*
exit /b %errorlevel%
