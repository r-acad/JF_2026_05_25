@echo off
REM ====================================================================
REM  CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd  --  Windows
REM
REM  Builds a prebuilt OpenJFEM sysimage so the solver and the web app start
REM  near-instantly (including the FIRST analysis), instead of paying Julia's
REM  one-time compilation on every fresh run.
REM
REM  HOW TO USE
REM    Double-click this file, OR from a console run:
REM        JFEM_installation\CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd
REM
REM  WHAT IT PRODUCES
REM    <repo>\sysimage\OpenJFEM_sysimage.dll
REM    The launchers (jfem.cmd, POST\case_runner_web_app\RUN_PANDEATOR_WINDOWS.cmd) load it AUTOMATICALLY when
REM    present. You do nothing else after building.
REM
REM  NOTES
REM    * Takes several minutes and uses a lot of CPU/RAM - this is normal; the
REM      window may look frozen.
REM    * Installs the Julia packages from Project.toml/Manifest.toml before
REM      building the image.
REM    * The .dll is tied to THIS machine's Julia version + OS + CPU. It is NOT
REM      portable: build it on each machine, and rebuild after a Julia upgrade
REM      or a change to the OpenJFEM packages.
REM    * If you never build it, everything still works - just slower to start.
REM    * Needs a Julia 1.12.x on PATH (no juliaup / no "+release" required).
REM ====================================================================
REM EnableDelayedExpansion so an install path with parentheses/spaces (e.g.
REM "...\JF_2026_05_25-main (7)\...") does not break the if-blocks below.
setlocal EnableDelayedExpansion
REM This script lives in <repo>\JFEM_installation\ ; the repo root is one level up.
set "HERE=%~dp0"
set "REPO_ROOT=%HERE%.."
set "SYSIMG=%REPO_ROOT%\sysimage\OpenJFEM_sysimage.dll"

if "%~1"=="-h" goto :usage
if "%~1"=="--help" goto :usage
if "%~1"=="help" goto :usage

echo ===================================================================
echo   BUILDING OpenJFEM sysimage (Windows)
echo   target: %SYSIMG%
echo ===================================================================
echo.
echo   *** PLEASE WAIT ***  Compiling OpenJFEM + the web-server stack into a
echo   single native image. Several minutes; the window may look frozen.
echo.

where julia >nul 2>nul
if errorlevel 1 (
    echo ERROR: Julia was not found on PATH. Install Julia 1.12.x first.
    echo.
    if not "%OPENJFEM_NO_PAUSE%"=="1" (
        echo Press any key to close this window.
        pause >nul
    )
    exit /b 1
)

echo Step 1 of 2: installing Julia packages from Project.toml/Manifest.toml...
julia --startup-file=no --project="!REPO_ROOT!" ^
  "!REPO_ROOT!\JFEM_installation\julia_tools\install_julia_packages.jl" ^
  --no-precompile

if errorlevel 1 (
    echo.
    echo Package setup failed - see the messages above.
    echo.
    if not "%OPENJFEM_NO_PAUSE%"=="1" (
        echo Press any key to close this window.
        pause >nul
    )
    exit /b 1
)

echo.
echo Step 2 of 2: building the OpenJFEM sysimage...
echo.

REM deploy_fast.jl runs the precompile workload and, with --sysimage, the
REM PackageCompiler build. --install-packagecompiler adds PackageCompiler if
REM it is not already in the project.
julia --threads=auto --startup-file=no --project="!REPO_ROOT!" ^
  "!REPO_ROOT!\JFEM_installation\julia_tools\deploy_fast.jl" ^
  --sysimage="!SYSIMG!" ^
  --install-packagecompiler %*

set "STATUS=%ERRORLEVEL%"

echo.
if not "%STATUS%"=="0" (
    echo Sysimage build failed - see the messages above.
) else (
    if exist "!SYSIMG!" (
        echo Done. The launchers will now use the sysimage automatically:
        echo   - jfem.cmd            ^(command-line runs^)
        echo   - POST\case_runner_web_app\RUN_PANDEATOR_WINDOWS.cmd  ^(web app^)
    ) else (
        echo Build did NOT produce the sysimage - see the messages above.
        set "STATUS=1"
    )
)
echo.
if not "%OPENJFEM_NO_PAUSE%"=="1" (
    echo Press any key to close this window.
    pause >nul
)
endlocal & exit /b %STATUS%

:usage
echo Usage:
echo   JFEM_installation\CLICK_WINDOWS_INSTALL_PACKAGES_AND_CREATE_SYSIMAGE.cmd [deploy_fast options]
echo.
echo This installs OpenJFEM Julia packages, then creates:
echo   sysimage\OpenJFEM_sysimage.dll
echo.
echo Optional deploy_fast options such as --deck or --manifest are passed to
echo the sysimage precompile workload.
endlocal & exit /b 0
