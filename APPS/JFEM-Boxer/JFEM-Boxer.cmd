@echo off
setlocal DisableDelayedExpansion
set "BOXER_JULIA=%WINGFEGEN_JULIA%"
if not defined BOXER_JULIA set "BOXER_JULIA=%JFEM_JULIA%"
if not defined BOXER_JULIA set "BOXER_JULIA=julia"
where "%BOXER_JULIA%" >nul 2>&1
if errorlevel 1 if not exist "%BOXER_JULIA%" (
  echo Julia was not found. Install Julia and run setup.cmd.
  if not "%OPENJFEM_NO_PAUSE%"=="1" pause
  exit /b 1
)
"%BOXER_JULIA%" --startup-file=no --threads=auto --project="%~dp0..\.." "%~dp0JFEM-Boxer.jl" %*
set "BOXER_EXIT=%errorlevel%"
if not "%BOXER_EXIT%"=="0" if not "%OPENJFEM_NO_PAUSE%"=="1" pause
exit /b %BOXER_EXIT%
