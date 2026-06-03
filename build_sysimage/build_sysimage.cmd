@echo off
REM ====================================================================
REM  build_sysimage.cmd  --  Windows
REM
REM  Builds a prebuilt OpenJFEM sysimage so the solver and the web app start
REM  near-instantly (including the FIRST analysis), instead of paying Julia's
REM  one-time compilation on every fresh run.
REM
REM  HOW TO USE
REM    Double-click this file, OR from a console run:
REM        build_sysimage\build_sysimage.cmd
REM
REM  WHAT IT PRODUCES
REM    <repo>\build\OpenJFEM_sysimage.dll
REM    The launchers (jfem.cmd, POST\panel_app.cmd) load it AUTOMATICALLY when
REM    present. You do nothing else after building.
REM
REM  NOTES
REM    * Takes several minutes and uses a lot of CPU/RAM - this is normal; the
REM      window may look frozen.
REM    * The .dll is tied to THIS machine's Julia version + OS + CPU. It is NOT
REM      portable: build it on each machine, and rebuild after a Julia upgrade
REM      or a change to the OpenJFEM packages.
REM    * If you never build it, everything still works - just slower to start.
REM    * Needs a Julia 1.12.x on PATH (no juliaup / no "+release" required).
REM ====================================================================
setlocal
REM This script lives in <repo>\build_sysimage\ ; the repo root is one level up.
set "HERE=%~dp0"
set "REPO_ROOT=%HERE%.."
set "SYSIMG=%REPO_ROOT%\build\OpenJFEM_sysimage.dll"

echo ===================================================================
echo   BUILDING OpenJFEM sysimage (Windows)
echo   target: %SYSIMG%
echo ===================================================================
echo.
echo   *** PLEASE WAIT ***  Compiling OpenJFEM + the web-server stack into a
echo   single native image. Several minutes; the window may look frozen.
echo.

REM deploy_fast.jl runs the precompile workload and, with --sysimage, the
REM PackageCompiler build. --install-packagecompiler adds PackageCompiler if
REM it is not already in the project.
julia --threads=auto --startup-file=no --project="%REPO_ROOT%" ^
  "%REPO_ROOT%\tools\deploy_fast.jl" ^
  --sysimage="%SYSIMG%" ^
  --install-packagecompiler %*

echo.
if exist "%SYSIMG%" (
    echo Done. The launchers will now use the sysimage automatically:
    echo   - jfem.cmd            ^(command-line runs^)
    echo   - POST\panel_app.cmd  ^(web app^)
) else (
    echo Build did NOT produce the sysimage - see the messages above.
)
echo.
echo Press any key to close this window.
pause >nul
endlocal
