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
REM Pin to the juliaup "release" channel (currently Julia 1.12.3 - the version
REM the packages were precompiled with). This avoids accidentally using an old
REM Julia (e.g. 1.11.1). If you don't use juliaup, drop "+release".
julia +release --project="%REPO_ROOT%" --threads=auto "%POST_DIR%panel_launch.jl" %*
echo.
echo Server stopped. Press any key to close this window.
pause >nul
endlocal
