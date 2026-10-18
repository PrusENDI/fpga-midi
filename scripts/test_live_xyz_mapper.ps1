param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$buildDir=Join-Path $projectRoot 'impl/modelsim_live_xyz_mapper'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work;if($LASTEXITCODE){throw 'vlib failed'}}
  $sources=@('rtl/performance_event_pkg.sv','rtl/live_xyz_mapper.sv','sim/tb_live_xyz_mapper.sv')|%{Join-Path $projectRoot $_}
  & "$ModelSimBin/vlog.exe" -sv -work work @sources *> compile.log
  if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  & "$ModelSimBin/vsim.exe" -c -onfinish stop -l simulation.log work.tb_live_xyz_mapper -do 'run 1 ms; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -or !(Select-String -Path simulation.log -SimpleMatch 'tb_live_xyz_mapper PASS' -Quiet)){Get-Content simulation.log;throw 'live mapper failed'}
  "tb_live_xyz_mapper PASS: $buildDir/simulation.log"
} finally {Pop-Location}
