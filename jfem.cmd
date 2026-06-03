@echo off
REM ====================================================================
REM  jfem.cmd - simplest way to analyze a .bdf on Windows.
REM
REM    jfem  model.bdf
REM    jfem  model.bdf  my_output_folder
REM    jfem  -rs  model.bdf            (choose which outputs to write)
REM
REM  The solution sequence (SOL 101/103/105/106) is auto-detected from the
REM  deck. By default it writes the viewer-ready set (.jfem + REPORT.md + JSON)
REM  to <deck_dir>\<deckname>_out\, or to the folder you name.
REM
REM  Optional output-format string BEFORE the deck (a '-' then letters, any
REM  order): j=.jfem viewer  r=REPORT.md  s=results JSON  v=VTK  h=HDF5
REM  m=model JSON  c=card inventory.  e.g.  jfem -jrsv model.bdf out
REM
REM  Tip: add this folder to your PATH so you can run `jfem` from anywhere.
REM  Uses whatever `julia` is on PATH (Julia 1.12.x; no juliaup needed) and
REM  auto-loads build\OpenJFEM_sysimage.dll for fast startup if it exists.
REM ====================================================================
setlocal
set "REPO_ROOT=%~dp0"
if "%~1"=="" (
  echo usage:  jfem  [-formats]  ^<model.bdf^>  [output_folder]
  echo example: jfem  C:\models\my_model.bdf
  echo example: jfem  -rs  C:\models\my_model.bdf
  exit /b 1
)

REM Optional sysimage for near-instant startup (build it with build_sysimage\build_sysimage.cmd).
set "SYSIMG_DLL=%REPO_ROOT%build\OpenJFEM_sysimage.dll"
set "SYSIMG_ARG="
if exist "%SYSIMG_DLL%" set "SYSIMG_ARG=--sysimage=%SYSIMG_DLL%"

julia %SYSIMG_ARG% --project="%REPO_ROOT%." --threads=auto --startup-file=no ^
  "%REPO_ROOT%tools\jfem.jl" %*

endlocal
