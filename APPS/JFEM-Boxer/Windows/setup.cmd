@echo off
setlocal DisableDelayedExpansion
set "WINGFEGEN_BIN=%WINGFEGEN_JULIA%"
if not defined WINGFEGEN_BIN set "WINGFEGEN_BIN=%JFEM_JULIA%"
if not defined WINGFEGEN_BIN set "WINGFEGEN_BIN=julia"
"%WINGFEGEN_BIN%" --startup-file=no "%~dp0..\setup.jl" %*
exit /b %errorlevel%
