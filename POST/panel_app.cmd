@echo off
REM ====================================================================
REM  Stiffened-panel buckling web app - Windows double-click launcher.
REM  Starts the pure-Julia server and opens the browser automatically.
REM ====================================================================
setlocal
set "POST_DIR=%~dp0"
set "REPO_ROOT=%POST_DIR%.."
title JFEM Stiffened Panel - server
echo ===================================================================
echo   JFEM STIFFENED PANEL - starting...
echo ===================================================================
echo.
echo   *** PLEASE WAIT ***  Julia is starting and warming up the solver.
echo   The FIRST start can take ~2 minutes (it looks frozen - this is normal;
echo   it is compiling the web server AND the solver so the app is fast after).
echo.
echo   Your browser opens AUTOMATICALLY once warm-up finishes. The page then
echo   loads instantly and the first Analyze is quick.
echo   If no browser appears, open this URL yourself:  http://127.0.0.1:8088/
echo.
echo   Keep this window OPEN while you work. Close it (or Ctrl+C) to stop.
echo ===================================================================
echo.
REM Optional sysimage: if a prebuilt OpenJFEM sysimage exists, load it with -J so
REM startup/warm-up is near-instant. Build it once per machine with build_sysimage.cmd.
REM The sysimage is tied to this machine's exact Julia version + OS + CPU, so it is
REM NOT committed and must be (re)built locally; if it is absent we start normally.
set "SYSIMG_DLL=%REPO_ROOT%\build\OpenJFEM_sysimage.dll"
set "SYSIMG_ARG="
if exist "%SYSIMG_DLL%" (
    set "SYSIMG_ARG=--sysimage=%SYSIMG_DLL%"
    echo   Using prebuilt sysimage: %SYSIMG_DLL%
    echo   ^(startup will be fast; delete that file or run build_sysimage.cmd to refresh^)
    echo.
)

REM Use whatever "julia" is on PATH. The packages were precompiled with Julia
REM 1.12.x, so make sure a 1.12.x Julia is installed and on PATH on this machine.
REM (No juliaup here: do NOT add "+release" - plain julia.exe treats it as a
REM bad path argument and fails with a "+release ... not found" error.)
julia %SYSIMG_ARG% --project="%REPO_ROOT%" --threads=auto "%POST_DIR%panel_launch.jl" %*
echo.
echo Server stopped. Press any key to close this window.
pause >nul
endlocal
