param([string]$InitialPath = '', [string]$Format = 'auto')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# An explicit foreground owner keeps the system dialog above the browser.
# The helper console stays hidden; only the requested Open dialog is visible.
$owner = New-Object System.Windows.Forms.Form
$owner.Text = 'JFEM-Boxer - Select model deck'
$owner.ShowInTaskbar = $false
$owner.TopMost = $true
$owner.StartPosition = 'CenterScreen'
$owner.Size = New-Object System.Drawing.Size(1, 1)
$owner.Opacity = 0
$picker = New-Object System.Windows.Forms.OpenFileDialog
$picker.Title = 'Open Reference deck - INCLUDE files are read automatically'
$picker.Title = 'Open model deck - INCLUDE files are read automatically'
if ($Format -eq 'abaqus') {
    $picker.Filter = 'Abaqus input (*.inp;*.inp.gz)|*.inp;*.inp.gz|All files (*.*)|*.*'
} else {
    $picker.Filter = 'Model decks (*.bdf;*.dat;*.nas;*.inp;*.inp.gz)|*.bdf;*.dat;*.nas;*.bulk;*.blk;*.inp;*.inp.gz|Reference decks (*.bdf;*.dat;*.nas)|*.bdf;*.dat;*.nas;*.bulk;*.blk|Abaqus input (*.inp;*.inp.gz)|*.inp;*.inp.gz|All files (*.*)|*.*'
}
$picker.CheckFileExists = $true
$picker.Multiselect = $false
$picker.RestoreDirectory = $true
try {
    if ($InitialPath -and (Test-Path -LiteralPath $InitialPath)) {
        if (Test-Path -LiteralPath $InitialPath -PathType Leaf) {
            $picker.InitialDirectory = Split-Path -LiteralPath $InitialPath
            $picker.FileName = [System.IO.Path]::GetFileName($InitialPath)
        } else { $picker.InitialDirectory = $InitialPath }
    }
    $owner.Show()
    $owner.Activate()
    $owner.BringToFront()
    [System.Windows.Forms.Application]::DoEvents()
    $answer = $picker.ShowDialog($owner)
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    @{ok=$true; cancelled=($answer -ne [System.Windows.Forms.DialogResult]::OK); path=$(if ($answer -eq [System.Windows.Forms.DialogResult]::OK) {$picker.FileName} else {''})} | ConvertTo-Json -Compress
} finally {
    $picker.Dispose()
    $owner.Close()
    $owner.Dispose()
}
