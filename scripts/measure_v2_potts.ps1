$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sim=Join-Path $env:TEMP ('v2_potts_'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $sim|Out-Null
Push-Location $sim; & 'C:\modeltech64_10.6d\win64\vlib.exe' work|Out-Null
& 'C:\modeltech64_10.6d\win64\vlog.exe' -sv -work work (Join-Path $root 'rtl/v2_potts_commit_fsm.sv') (Join-Path $root 'sim/tb_v2_potts_commit.sv')
& 'C:\modeltech64_10.6d\win64\vsim.exe' -c -lib work tb_v2_potts_commit -do 'run -all; quit -f'
Pop-Location
