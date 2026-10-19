param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class StudyPickerTestNative { [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l); }'
$scriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src/native_windows_dialog.jl'))
$selectedFolder = Join-Path $OutputDirectory 'Chosen folder outside Downloads'
New-Item -ItemType Directory -Force -Path $selectedFolder | Out-Null
foreach ($action in @('select','cancel')) {
    $resultPath = Join-Path $OutputDirectory ($action+'.json')
    $errorPath = Join-Path $OutputDirectory ($action+'-error.txt')
    $pickerProcess = Start-Process (Get-Command julia.exe).Source -ArgumentList @('--startup-file=no','--compile=min','-O0',('"'+$scriptPath+'"'),'save','Study.wingfem.json',('"'+$selectedFolder+'"'),'auto') -WindowStyle Hidden -PassThru -RedirectStandardOutput $resultPath -RedirectStandardError $errorPath
    try {
        $processCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $pickerProcess.Id)
        $nameCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Save JFEM-Boxer file - choose a folder and filename')
        $condition = New-Object System.Windows.Automation.AndCondition($processCondition, $nameCondition)
        $dialog = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (!$dialog -and [DateTime]::UtcNow -lt $deadline) {
            $dialog = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            Start-Sleep -Milliseconds 100
        }
        if (!$dialog) { throw "System Save dialog did not appear. $(Get-Content -LiteralPath $errorPath -Raw)" }
        Start-Sleep -Seconds 1
        if ($action -eq 'select') {
            $rect = $dialog.Current.BoundingRectangle
            $bitmap = New-Object System.Drawing.Bitmap([int]$rect.Width,[int]$rect.Height)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try { $graphics.CopyFromScreen([int]$rect.X,[int]$rect.Y,0,0,$bitmap.Size); $bitmap.Save((Join-Path $OutputDirectory 'native-save-dialog.png')) }
            finally { $graphics.Dispose(); $bitmap.Dispose() }
        }
        $buttonId = if ($action -eq 'select') { '1' } else { '2' }
        $idCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $buttonId)
        $typeCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'Button')
        $buttonCondition = New-Object System.Windows.Automation.AndCondition($idCondition, $typeCondition)
        $button = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
        if (!$button) { throw 'System Save/Cancel button was not found.' }
        [StudyPickerTestNative]::PostMessage([IntPtr]$button.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        if (!$pickerProcess.WaitForExit(15000)) { throw 'System Save selection did not finish.' }
        $returned = (Get-Content -LiteralPath $resultPath -Raw).Trim()
        $result = if ($returned -eq 'CANCEL') { [pscustomobject]@{ok=$true;cancelled=$true} } elseif ($returned.StartsWith("PATH`t")) { [pscustomobject]@{ok=$true;cancelled=$false;path=$returned.Substring(5)} } else { throw 'Invalid native picker response.' }
        if (!$result.ok) { throw 'System picker failed.' }
        if ($action -eq 'cancel') { if (!$result.cancelled) { throw 'Cancel selected a file.' } }
        elseif ($result.cancelled -or $result.path -ne (Join-Path $selectedFolder 'Study.wingfem.json')) { throw 'System picker returned the wrong folder/file.' }
        if (Test-Path -LiteralPath (Join-Path $selectedFolder 'Study.wingfem.json')) { throw 'Selection must not create or truncate the file.' }
    } finally {
        if (!$pickerProcess.HasExited) { Stop-Process -Id $pickerProcess.Id }
    }
}
Write-Output 'PASS: real Windows Save dialog selects an arbitrary folder with spaces, cancels cleanly, and never writes before app serialization.'
