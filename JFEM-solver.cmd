@echo off
setlocal DisableDelayedExpansion
set "JFEM_DECK=%~1"
if defined JFEM_DECK goto solve
set "JFEM_PICKER=%TEMP%\jfem_deck_%RANDOM%_%RANDOM%.txt"
set "JFEM_PICKER_OUT=%JFEM_PICKER%"
powershell.exe -NoProfile -STA -Command "Add-Type -AssemblyName System.Windows.Forms; $dialog = New-Object System.Windows.Forms.OpenFileDialog; $dialog.Title = 'Choose a finite element deck'; $dialog.Filter = 'Finite element decks (*.bdf;*.dat;*.nas)|*.bdf;*.dat;*.nas|All files (*.*)|*.*'; if ($dialog.ShowDialog() -eq 'OK') { [System.IO.File]::WriteAllText($env:JFEM_PICKER_OUT, $dialog.FileName, [System.Text.Encoding]::Default) }"
if not exist "%JFEM_PICKER%" exit /b 0
set /p "JFEM_DECK=" < "%JFEM_PICKER%"
del /q "%JFEM_PICKER%"
if not defined JFEM_DECK exit /b 0
:solve
call "%~dp0jfem.cmd" "%JFEM_DECK%" %2 %3 %4 %5 %6 %7 %8 %9
set "JFEM_EXIT=%errorlevel%"
echo.
echo JFEM finished with exit code %JFEM_EXIT%. Output paths are listed above.
if not "%OPENJFEM_NO_PAUSE%"=="1" pause
exit /b %JFEM_EXIT%
