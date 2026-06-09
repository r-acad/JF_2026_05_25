@echo off
setlocal
cd /d "%~dp0"
julia --startup-file=no --project=.. run_public_suite.jl %*
