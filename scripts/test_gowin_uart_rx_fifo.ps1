param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'impl/modelsim_fifo_ip'
New-Item -ItemType Directory -Force $dir | Out-Null
Push-Location $dir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work;if($LASTEXITCODE){throw 'vlib failed'}}
  $src=@('rtl/uart_rx_fifo.sv','rtl/gowin_uart_rx_fifo.sv','sim/tb_gowin_uart_rx_fifo.sv')|%{Join-Path $root $_}
  & "$ModelSimBin/vlog.exe" -sv -work work @src *> compile.log
  if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  & "$ModelSimBin/vsim.exe" -c -novopt -l fifo_ip.log work.tb_gowin_uart_rx_fifo -do 'run 1 us; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -or !(Select-String -Path fifo_ip.log -SimpleMatch 'tb_gowin_uart_rx_fifo PASS' -Quiet)){
    Get-Content fifo_ip.log;Get-Content console.log;throw 'FIFO adapter test failed'
  }
  'tb_gowin_uart_rx_fifo PASS'
} finally { Pop-Location }
