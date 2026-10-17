param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'impl/modelsim_mode_gated'
New-Item -ItemType Directory -Force $dir | Out-Null
Push-Location $dir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work}
  $src=@('rtl/performance_event_fifo_wrapper.sv','rtl/performance_event_ingress.sv','sim/tb_mode_gated_event_paths.sv')|%{Join-Path $root $_}
  & "$ModelSimBin/vlog.exe" -sv -work work @src *> compile.log
  if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  & "$ModelSimBin/vsim.exe" -c -novopt -l mode_gated.log work.tb_mode_gated_event_paths -do 'run 1 us; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -or !(Select-String -Path mode_gated.log -SimpleMatch 'tb_mode_gated_event_paths PASS' -Quiet)){Get-Content mode_gated.log;throw 'mode gated paths failed'}
  'mode-gated paths PASS'
} finally { Pop-Location }
