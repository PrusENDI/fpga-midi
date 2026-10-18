param([string]$ModelSimBin='C:\modeltech64_10.6d\win64',
      [string]$GowinSimLib='C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent; $dir=Join-Path $root 'impl/modelsim_calibration_top'
New-Item -ItemType Directory -Force $dir | Out-Null; Push-Location $dir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work;if($LASTEXITCODE){throw 'vlib failed'}}
  $src=@('rtl/uart_tx.sv','rtl/uart_byte_serializer.sv','rtl/mgc3130_reset_seq.sv','rtl/mgc3130_reader.sv','rtl/mgc3130_calibration_capture.sv','rtl/mgc3130_uart_calibration_top.sv','sim/gowin_i2c_master_stub.sv','sim/tb_mgc3130_uart_calibration_top.sv')|%{Join-Path $root $_}
  & "$ModelSimBin/vlog.exe" -sv -work work $GowinSimLib @src *> compile.log
  if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  & "$ModelSimBin/vsim.exe" -c -novopt -l calibration_top.log work.tb_mgc3130_uart_calibration_top -do 'run 150 ms; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -or !(Select-String -Path calibration_top.log -SimpleMatch 'tb_mgc3130_uart_calibration_top PASS' -Quiet)){Get-Content calibration_top.log;Get-Content console.log;throw 'calibration top failed'}
  'tb_mgc3130_uart_calibration_top PASS'
} finally { Pop-Location }
