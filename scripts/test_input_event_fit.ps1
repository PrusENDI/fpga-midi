param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'impl/modelsim_input_fit'
New-Item -ItemType Directory -Force $dir | Out-Null
Push-Location $dir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work}
  $src=@('rtl/control_protocol_pkg.sv','rtl/performance_event_pkg.sv','rtl/input_event_adapter.sv','sim/tb_input_event_fit.sv')|%{Join-Path $root $_}
  & "$ModelSimBin/vlog.exe" -sv -work work @src *> compile.log
  if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  & "$ModelSimBin/vsim.exe" -c -l fit.log work.tb_input_event_fit -do 'run 1 ms; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -or !(Select-String -Path fit.log -SimpleMatch 'tb_input_event_fit PASS' -Quiet)){Get-Content fit.log;throw 'input fit failed'}
  'input event fit PASS'
} finally { Pop-Location }
