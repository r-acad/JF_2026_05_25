@echo off
setlocal EnableDelayedExpansion
set "APP_DIR=%~dp0"
set "REPO_ROOT=%APP_DIR%..\.."
set "PANEL_JULIA=%JFEM_JULIA%"
if not defined PANEL_JULIA set "PANEL_JULIA=julia"
where "!PANEL_JULIA!" >nul 2>&1
if errorlevel 1 if not exist "!PANEL_JULIA!" (
    echo Julia was not found. Install Julia from https://julialang.org/downloads/
    echo Set JFEM_JULIA to an installed Julia executable if it is not on PATH.
    exit /b 1
)
echo Starting PANDEATOR. First use may install dependencies and compile packages.
echo The browser opens after server warm-up. Keep this terminal open; Ctrl+C stops it.
REM Select only an image with a matching source/runtime/workload receipt.
REM Build the optional image with setup.cmd --sysimage from the repository root.
set "SYSIMG_DLL=%REPO_ROOT%\sysimage\OpenJFEM_sysimage.dll"
set "SYSIMG_ARG="
if exist "!SYSIMG_DLL!" (
    "!PANEL_JULIA!" --startup-file=no --threads=1 --project="!REPO_ROOT!" "!REPO_ROOT!\JFEM_installation\julia_tools\check_sysimage.jl" "!REPO_ROOT!" "!SYSIMG_DLL!"
    if not errorlevel 1 (
        set "SYSIMG_ARG=--sysimage=!SYSIMG_DLL!"
        echo Using verified sysimage: !SYSIMG_DLL!
    )
)
if defined SYSIMG_ARG (
    "!PANEL_JULIA!" "!SYSIMG_ARG!" --startup-file=no --project="!REPO_ROOT!" --threads=auto "!APP_DIR!panel_launch.jl" %*
) else (
    "!PANEL_JULIA!" --startup-file=no --project="!REPO_ROOT!" --threads=auto "!APP_DIR!panel_launch.jl" %*
)
set "JFEM_EXIT=!errorlevel!"
if not "%OPENJFEM_NO_PAUSE%"=="1" pause
endlocal & exit /b %JFEM_EXIT%
