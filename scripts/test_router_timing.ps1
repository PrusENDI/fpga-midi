param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'impl/modelsim_router_timing'
New-Item -ItemType Directory -Force $dir | Out-Null
Push-Location $dir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work}
  $src=@('rtl/performance_event_pkg.sv','rtl/performance_event_router.sv','rtl/input_event_mux.sv','sim/tb_router_burst.sv','sim/tb_mux_router_burst.sv')|%{Join-Path $root $_}
  & "$ModelSimBin/vlog.exe" -sv -work work @src *> compile.log
  if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  foreach($top in @('tb_router_burst','tb_mux_router_burst')) {
    & "$ModelSimBin/vsim.exe" -c -novopt -l "$top.log" "work.$top" -do 'run 1 us; quit -code 0 -f' *> "$top.console.log"
    if($LASTEXITCODE -or !(Select-String -Path "$top.log" -SimpleMatch 'PASS' -Quiet)){Get-Content "$top.log";throw "$top failed"}
  }
  'router timing PASS'
} finally { Pop-Location }
