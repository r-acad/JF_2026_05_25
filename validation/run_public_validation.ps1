Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Set-Location $PSScriptRoot
$suiteArguments = @($args)
if ($suiteArguments -notcontains '--output-dir' -and
    $suiteArguments -notcontains '--dry-run' -and
    $suiteArguments -notcontains '--skip-jfem') {
    $resultFolder = Join-Path $PSScriptRoot ('local_runs\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $suiteArguments += @('--output-dir', $resultFolder)
    Write-Host "Results and .jfem files will be kept in: $resultFolder" -ForegroundColor Cyan
}
julia --startup-file=no --project=.. .\run_public_suite.jl @suiteArguments
exit $LASTEXITCODE
