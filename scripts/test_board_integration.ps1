param([string]$ModelSimBin='C:\\modeltech64_10.6d\\win64',[string]$GowinSimLib='C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v')
$ErrorActionPreference='Stop'; $root=Split-Path $PSScriptRoot -Parent; $dir=Join-Path $root 'impl/modelsim_board_integration'; New-Item -ItemType Directory -Force $dir | Out-Null; Push-Location $dir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work;if($LASTEXITCODE){throw 'vlib failed'}}
  $src=@('rtl/control_protocol_pkg.sv','rtl/performance_event_pkg.sv','rtl/loop_event_ram.sv','rtl/loop_event_store.sv','rtl/loop_scheduler.sv','rtl/command_mailbox.sv','rtl/control_csr.sv','rtl/mode_manager.sv','rtl/performance_event_fifo_wrapper.sv','rtl/performance_event_ingress.sv','rtl/performance_event_router.sv','rtl/input_event_mux.sv','rtl/loop_control_plane.sv','rtl/performance_event_voice_bridge.sv','rtl/mgc3130_voice_mixer.sv','rtl/loop_audio_path.sv','rtl/uart_rx.sv','rtl/uart_rx_fifo.sv','rtl/gowin_uart_rx_fifo.sv','rtl/uart_control_link.sv','rtl/mgc3130_input_latch.sv','rtl/input_event_adapter.sv','rtl/mgc3130_loop_control_path.sv','sim/tb_mgc3130_loop_control_path.sv')|%{Join-Path $root $_}
  & "$ModelSimBin/vlog.exe" -sv -work work $GowinSimLib @src *> compile.log; if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  & "$ModelSimBin/vsim.exe" -c -onfinish stop -l board_integration.log work.tb_mgc3130_loop_control_path -do 'run 50 ms; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -or !(Select-String -Path board_integration.log -SimpleMatch 'tb_mgc3130_loop_control_path PASS' -Quiet)){Get-Content board_integration.log;Get-Content console.log;throw 'board integration failed'}
  'tb_mgc3130_loop_control_path PASS'
} finally {Pop-Location}
