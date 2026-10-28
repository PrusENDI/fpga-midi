param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out=Join-Path $root 'impl/modelsim_v2_test_mode'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $out
try {
  foreach($tool in @('vlib.exe','vlog.exe','vsim.exe')){ if(!(Test-Path (Join-Path $ModelSimBin $tool))){throw "Missing ModelSim tool $tool"} }
  if(!(Test-Path 'work/_info')){ & (Join-Path $ModelSimBin 'vlib.exe') work | Out-Null }
  $src=@(
    (Join-Path $root 'rtl/v2_contract_pkg.sv'),
    (Join-Path $root 'rtl/v2_test_mode.sv'),
    (Join-Path $root 'sim/tb_v2_test_mode.sv')
  )
  & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work @src *> compile.log
  if($LASTEXITCODE -ne 0){Get-Content compile.log; throw 'vlog failed'}
  & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish stop -l test_mode.log work.tb_v2_test_mode "+OUT_DIR=$out" -do 'run 5 ms; quit -code 0 -f' *> test_mode.console.log
  if($LASTEXITCODE -ne 0){Get-Content test_mode.console.log; throw 'vsim failed'}
  if(Select-String -Path test_mode.console.log -Pattern '\*\* (Error|Fatal):' -Quiet){Get-Content test_mode.console.log; throw 'test mode assertion failed'}
  if(!(Select-String -Path test_mode.console.log -SimpleMatch 'tb_v2_test_mode PASS' -Quiet)){Get-Content test_mode.console.log; throw 'test mode did not reach PASS'}
  Push-Location $root
  try {
    & python tools/test_v2_spectrum.py --input $out
    if($LASTEXITCODE -ne 0){throw 'spectrum analysis failed'}
  } finally { Pop-Location }
  Write-Output "V2 N-tone test mode PASS: $out"
} finally { Pop-Location }
