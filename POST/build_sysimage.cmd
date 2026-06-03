@echo off
REM ====================================================================
REM  Build a prebuilt OpenJFEM sysimage for fast panel-app startup.
REM
REM  Run this ONCE per machine (double-click or run from a console).
REM  It produces  <repo>\JFEM\build\OpenJFEM_sysimage.dll, which
REM  panel_app.cmd then loads automatically via --sysimage so that
REM  Julia startup AND the first browser Analyze are near-instant.
REM
REM  The sysimage bakes in OpenJFEM, the web-server stack (HTTP, MsgPack,
REM  JSON) and the server's actual run path (run_analysis + the HTTP handler),
REM  exercised on the bundled SOL 101/103/105 decks - so the first "Run a .bdf
REM  file" does not pay just-in-time compilation for the solve/export path.
REM
REM  Notes:
REM   * Takes several minutes and uses a lot of CPU/RAM - this is normal.
REM   * The .dll is tied to THIS machine's exact Julia version + OS + CPU.
REM     It is NOT portable: build it on each machine, and rebuild it after
REM     a Julia upgrade or a change to the OpenJFEM packages.
REM   * Needs the same plain "julia" on PATH as panel_app.cmd (Julia 1.12.x,
REM     no juliaup / no "+release").
REM ====================================================================
setlocal
set "POST_DIR=%~dp0"
set "REPO_ROOT=%POST_DIR%.."
set "SYSIMG_DLL=%REPO_ROOT%\build\OpenJFEM_sysimage.dll"

echo ===================================================================
echo   BUILDING OpenJFEM sysimage
echo   target: %SYSIMG_DLL%
echo ===================================================================
echo.
echo   *** PLEASE WAIT ***  This compiles OpenJFEM and all its
echo   dependencies into one native image. It can take several minutes
echo   and the window may look frozen - that is normal.
echo.

REM deploy_fast.jl does the precompile + (with --sysimage) the PackageCompiler
REM build. --install-packagecompiler lets it add PackageCompiler if missing.
julia --threads=auto --startup-file=no --project="%REPO_ROOT%" ^
  "%REPO_ROOT%\tools\deploy_fast.jl" ^
  --sysimage="%SYSIMG_DLL%" ^
  --install-packagecompiler %*

echo.
if exist "%SYSIMG_DLL%" (
    echo Done. panel_app.cmd will now use the sysimage automatically.
) else (
    echo Build did NOT produce the sysimage - see the messages above.
)
echo Press any key to close this window.
pause >nul
endlocal
