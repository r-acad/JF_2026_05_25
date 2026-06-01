<#
.SYNOPSIS
  Synthesize the missing PSHELL/MAT/EIGRL/case-control set for the
  TACS uCRM coarse wingbox BDF so it can be run by JFEM or any other
  classical BDF-based solver.

.DESCRIPTION
  The upstream TACS BDF (cases/crm/wingbox_modal.bdf) contains only
  GRID*, CQUAD4 and SPC cards. TACS supplies isotropic shell properties
  from its Python runner (examples/crm/crm_frequency.py) at runtime
  with rho = 2500, E = 70e9, nu = 0.3, t = 0.02. This script writes a
  runnable copy with one PSHELL per CQUAD4 PID (242 total),
  one MAT1, an EIGRL extraction request and SOL 103 case control.

.PARAMETER InBdf
  Path to the source BDF. Defaults to cases/crm/wingbox_modal.bdf.

.PARAMETER OutBdf
  Path to write. Defaults to cases/crm/wingbox_modal_with_props.bdf.
#>

param(
  [string]$InBdf  = "$PSScriptRoot\..\cases\crm\wingbox_modal.bdf",
  [string]$OutBdf = "$PSScriptRoot\..\cases\crm\wingbox_modal_with_props.bdf"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$InBdf  = (Resolve-Path -LiteralPath $InBdf).Path
$lines  = Get-Content -Raw -Path $InBdf -Encoding ascii
$src    = $lines -split "`r?`n"

# Collect distinct CQUAD4 PIDs (field 3 in comma- or whitespace-separated).
$pids = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($ln in $src) {
  if ($ln -match '^CQUAD4\s+\S+\s+(\S+)') { [void]$pids.Add([int]$Matches[1]) }
}
$pidList = $pids | Sort-Object
Write-Host "==> distinct PIDs: $($pidList.Count)" -ForegroundColor Cyan

# Build the synthesized property/material/eigrl block.
$block = New-Object System.Text.StringBuilder
[void]$block.AppendLine("`$ -----------------------------------------------------------")
[void]$block.AppendLine("`$ PROPERTY / MATERIAL / EIGRL SYNTHESIZED FROM TACS RUNNER")
[void]$block.AppendLine("`$ source: tacs-master/examples/crm/crm_frequency.py")
[void]$block.AppendLine("`$ isotropic shell: rho=2500 kg/m3, E=70e9 Pa, nu=0.3, t=0.02 m")
[void]$block.AppendLine("`$ -----------------------------------------------------------")
[void]$block.AppendLine("PARAM, K6ROT, 100.0")
[void]$block.AppendLine("PARAM, AUTOSPC, NO")
[void]$block.AppendLine("MAT1, 1, 7.0+10, , 0.3, 2500.0")
[void]$block.AppendLine("EIGRL, 1, , , 5")
foreach ($p in $pidList) {
  [void]$block.AppendFormat("PSHELL, {0}, 1, 0.02, 1, , 1`n", $p)
}
$blockText = $block.ToString()

# Walk the source, inject:
#   - "SPC = 1" + "METHOD = 1" + DISP = ALL right after CEND
#   - synthesized property block right after BEGIN BULK
$out = New-Object System.Text.StringBuilder
foreach ($ln in $src) {
  [void]$out.AppendLine($ln)
  if ($ln -match '^CEND\s*$') {
    [void]$out.AppendLine("TITLE = uCRM coarse wingbox modal (TACS examples/crm)")
    [void]$out.AppendLine("ECHO = NONE")
    [void]$out.AppendLine("SPC = 1")
    [void]$out.AppendLine("METHOD = 1")
    [void]$out.AppendLine("DISPLACEMENT(PLOT) = ALL")
  } elseif ($ln -match '^BEGIN BULK\s*$') {
    [void]$out.Append($blockText)
  }
}

Set-Content -LiteralPath $OutBdf -Value $out.ToString() -Encoding ascii -NoNewline
Write-Host "==> wrote $OutBdf ($((Get-Item $OutBdf).Length) bytes)" -ForegroundColor Green
