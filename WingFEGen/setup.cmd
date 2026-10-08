@echo off
setlocal
set "WINGFEGEN_BIN=%WINGFEGEN_JULIA%"
if not defined WINGFEGEN_BIN set "WINGFEGEN_BIN=julia"
"%WINGFEGEN_BIN%" --startup-file=no "%~dp0setup.jl" %*
exit /b %errorlevel%
