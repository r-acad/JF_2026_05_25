param([string]$SuggestedName = 'Study.wingfem.json', [string]$InitialDirectory = '')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms
$owner = New-Object System.Windows.Forms.Form
$dialog = New-Object System.Windows.Forms.SaveFileDialog
try {
    $owner.TopMost = $true
    $owner.ShowInTaskbar = $false
    $owner.Opacity = 0
    $owner.Show()
    $dialog.Title = 'Save JFEM-Boxer file - choose a folder and filename'
    $dialog.FileName = $SuggestedName
    $dialog.OverwritePrompt = $true
    $dialog.CheckPathExists = $true
    $dialog.AddExtension = $true
    if ($SuggestedName.EndsWith('.toml')) {
        $dialog.DefaultExt = 'toml'
        $dialog.Filter = 'JFEM-Boxer parameters (*.toml)|*.toml'
    } else {
        $dialog.DefaultExt = 'wingfem.json'
        $dialog.Filter = 'JFEM-Boxer Study (*.wingfem.json)|*.wingfem.json'
    }
    if (Test-Path -LiteralPath $InitialDirectory -PathType Container) { $dialog.InitialDirectory = $InitialDirectory }
    if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
        @{ok=$true; path=$dialog.FileName} | ConvertTo-Json -Compress
    } else {
        @{ok=$true; cancelled=$true} | ConvertTo-Json -Compress
    }
} finally {
    $dialog.Dispose()
    $owner.Dispose()
}
