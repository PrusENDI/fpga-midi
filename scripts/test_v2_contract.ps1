param([string]$ModelSim = 'C:\modeltech64_10.6d\win64')
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$vlib = Join-Path $ModelSim 'vlib.exe'
$vlog = Join-Path $ModelSim 'vlog.exe'
$vsim = Join-Path $ModelSim 'vsim.exe'
$scratch = Join-Path $env:TEMP ('v2_contract_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  Push-Location $scratch
  & $vlib work | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
  & $vlog -sv -work work (Join-Path $projectRoot 'rtl/v2_contract_pkg.sv') (Join-Path $projectRoot 'sim/tb_v2_contract.sv')
  if ($LASTEXITCODE -ne 0) { throw 'vlog failed' }
  $normal = & $vsim -c -do 'run -all; quit -f' work.tb_v2_contract 2>&1
  if (($normal -join "`n") -notmatch 'V2 contract PASS' -or ($normal -join "`n") -match '\*\* Fatal:') { throw 'normal contract test failed' }
  $mutatedPackage = Join-Path $scratch 'v2_contract_pkg_mutated.sv'
  $source = [IO.File]::ReadAllText((Join-Path $projectRoot 'rtl/v2_contract_pkg.sv'))
  $layoutPattern = 'logic \[7:0\]\s+tick;\s+logic \[7:0\]\s+duration;'
  if (-not [regex]::IsMatch($source, $layoutPattern)) { throw 'layout mutation target missing' }
  [IO.File]::WriteAllText($mutatedPackage, ([regex]::new($layoutPattern)).Replace($source, "logic [7:0]  duration;`n    logic [7:0]  tick;", 1))
  & $vlog -sv -work work $mutatedPackage (Join-Path $projectRoot 'sim/tb_v2_contract.sv') | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'layout-mutated package did not compile' }
  $mutation = & $vsim -c -do 'run -all; quit -f' work.tb_v2_contract 2>&1
  if (($mutation -join "`n") -notmatch '\*\* Fatal: event field layout mismatch') { throw 'layout mutation was not detected' }
  $target = 'logic [7:0]  tick;'
  if (-not $source.Contains($target)) { throw 'width mutation target missing' }
  [IO.File]::WriteAllText($mutatedPackage, $source.Replace($target, 'logic [6:0]  tick;'))
  & $vlog -sv -work work $mutatedPackage (Join-Path $projectRoot 'sim/tb_v2_contract.sv') | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'mutated package did not compile for runtime assertion' }
  $width = & $vsim -c -do 'run -all; quit -f' work.tb_v2_contract 2>&1
  if (($width -join "`n") -notmatch '\*\* Fatal: type width mismatch') { throw 'width mutation was not detected' }
  'V2 contract PASS; layout and width mutations rejected'
} finally {
  Pop-Location
  $resolved = [IO.Path]::GetFullPath($scratch)
  $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
  if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}
