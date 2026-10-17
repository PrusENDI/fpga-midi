param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'impl/modelsim_live_input_quality'
New-Item -ItemType Directory -Force $dir | Out-Null
Push-Location $dir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work}
  $src=@('rtl/control_protocol_pkg.sv','rtl/performance_event_pkg.sv','rtl/input_event_adapter.sv','sim/tb_live_input_quality.sv')|%{Join-Path $root $_}
  & "$ModelSimBin/vlog.exe" -sv -work work @src *> compile.log
  if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  & "$ModelSimBin/vsim.exe" -c -l quality.log work.tb_live_input_quality -do 'run 1 ms; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -or !(Select-String -Path quality.log -SimpleMatch 'tb_live_input_quality PASS' -Quiet)){Get-Content quality.log;throw 'LIVE quality failed'}
  'LIVE input quality PASS'
} finally { Pop-Location }
