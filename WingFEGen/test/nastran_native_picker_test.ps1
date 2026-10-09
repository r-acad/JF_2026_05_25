param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class PickerTestNative { [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l); }'
$scriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src/nastran_pick_file.ps1'))
$deckPath = Join-Path $OutputDirectory 'picker test.bdf'
Set-Content -LiteralPath $deckPath -Value 'BEGIN BULK' -Encoding ASCII
$resultPath = Join-Path $OutputDirectory 'native-picker.json'
$errorPath = Join-Path $OutputDirectory 'native-picker-error.txt'
$pickerProcess = Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$scriptPath+'"'),'-InitialPath',('"'+$deckPath+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput $resultPath -RedirectStandardError $errorPath
try {
    $processCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $pickerProcess.Id)
    $classCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, '#32770')
    $nameCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Open Nastran deck - INCLUDE files are read automatically')
    $condition = New-Object System.Windows.Automation.AndCondition($processCondition, $nameCondition)
    $dialog = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (!$dialog -and [DateTime]::UtcNow -lt $deadline) {
        $dialog = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        Start-Sleep -Milliseconds 100
    }
    if (!$dialog) {
        $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $processCondition)
        $windows | ForEach-Object { $_.Current | Select-Object Name, ClassName, ProcessId } | ConvertTo-Json | Set-Content (Join-Path $OutputDirectory 'windows.json')
        throw "The system Open dialog did not appear. $(Get-Content -LiteralPath $errorPath -Raw)" }
    Start-Sleep -Seconds 2
    $dialog = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    $buttonCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, '1')
    $typeCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'Button')
    $buttonCondition = New-Object System.Windows.Automation.AndCondition($buttonCondition, $typeCondition)
    $openButton = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
    if (!$openButton) { $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current | Select-Object Name, ClassName, AutomationId, ControlType } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $OutputDirectory 'controls.json'); throw 'System Open button was not found.' }
    [PickerTestNative]::PostMessage([IntPtr]$openButton.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    if (!$pickerProcess.WaitForExit(15000)) { throw 'System Open selection did not finish.' }
    if ($null -ne $pickerProcess.ExitCode -and $pickerProcess.ExitCode -ne 0) { throw (Get-Content -LiteralPath $errorPath -Raw) }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if (!$result.ok -or $result.cancelled -or $result.path -ne $deckPath) { throw 'System picker returned the wrong file.' }
    Write-Output 'PASS: native Windows Open dialog foreground owner and selected full path (spaces included).'
} finally {
    if (!$pickerProcess.HasExited) { Stop-Process -Id $pickerProcess.Id }
}
