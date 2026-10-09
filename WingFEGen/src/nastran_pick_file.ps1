param([string]$InitialPath = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# An explicit foreground owner keeps the system dialog above the browser.
# The helper console stays hidden; only the requested Open dialog is visible.
$owner = New-Object System.Windows.Forms.Form
$owner.Text = 'WingFEGen - Select Nastran deck'
$owner.ShowInTaskbar = $false
$owner.TopMost = $true
$owner.StartPosition = 'CenterScreen'
$owner.Size = New-Object System.Drawing.Size(1, 1)
$owner.Opacity = 0
$picker = New-Object System.Windows.Forms.OpenFileDialog
$picker.Title = 'Open Nastran deck - INCLUDE files are read automatically'
$picker.Filter = 'Nastran decks (*.bdf;*.dat;*.nas;*.bulk;*.blk)|*.bdf;*.dat;*.nas;*.bulk;*.blk|All files (*.*)|*.*'
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
