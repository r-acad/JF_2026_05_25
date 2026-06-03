@echo off
REM ====================================================================
REM  MOVED: the sysimage build scripts now live in a dedicated, clearly
REM  identified folder at the repository root:
REM
REM      build_sysimage\build_sysimage.cmd   (Windows)
REM      build_sysimage\build_sysimage.sh    (Linux / macOS)
REM      build_sysimage\README.md            (instructions)
REM
REM  This thin shim simply forwards to the new Windows script so existing
REM  shortcuts keep working. Please use the build_sysimage\ folder going forward.
REM ====================================================================
setlocal
set "HERE=%~dp0"
set "NEW=%HERE%..\build_sysimage\build_sysimage.cmd"
if exist "%NEW%" (
    call "%NEW%" %*
) else (
    echo Could not find %NEW%
    echo Please run build_sysimage\build_sysimage.cmd from the repository root.
    pause >nul
)
endlocal
