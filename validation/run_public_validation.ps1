Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Set-Location $PSScriptRoot
julia --startup-file=no --project=.. .\run_public_suite.jl @args
