@echo off
rem ==========================================================================
rem  WingFEGen - wing torsion box FE model generator
rem
rem  Starts the Julia application, which serves the Babylon.js web app and
rem  opens it in the default browser.
rem
rem    run_fe_generator.cmd                    start the web app
rem    run_fe_generator.cmd my_wing.toml       use another input file
rem    run_fe_generator.cmd --nastran          generate and write, no browser
rem    run_fe_generator.cmd --port 9000
rem ==========================================================================
setlocal
set "WINGFEGEN_ENTRY=%~dp0run.jl"
set "WINGFEGEN_BIN=%WINGFEGEN_JULIA%"
if not defined WINGFEGEN_BIN set "WINGFEGEN_BIN=julia"
where "%WINGFEGEN_BIN%" >nul 2>&1
if errorlevel 1 if not exist "%WINGFEGEN_BIN%" (
  echo.
  echo   Julia was not found on the PATH.
  echo   Install Julia 1.13.1, or set WINGFEGEN_JULIA to its executable.
  echo   Run setup.cmd once to install the recorded package dependencies.
  echo.
  exit /b 1
)

"%WINGFEGEN_BIN%" --startup-file=no --project="%~dp0." "%WINGFEGEN_ENTRY%" %*
exit /b %errorlevel%
