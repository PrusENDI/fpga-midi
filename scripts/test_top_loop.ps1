param([string]$ModelSimBin='C:\modeltech64_10.6d\win64',
      [string]$GowinSimLib='C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'impl/modelsim_top_loop'
New-Item -ItemType Directory -Force $dir | Out-Null
Push-Location $dir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work;if($LASTEXITCODE){throw 'vlib failed'}}
  $src=@('rtl/uart_byte_serializer.sv','rtl/uart_banner_tx.sv','rtl/control_protocol_pkg.sv','rtl/performance_event_pkg.sv','rtl/loop_event_ram.sv','rtl/loop_event_store.sv','rtl/loop_scheduler.sv','rtl/command_mailbox.sv','rtl/control_csr.sv','rtl/mode_manager.sv','rtl/performance_event_fifo_wrapper.sv','rtl/performance_event_ingress.sv','rtl/performance_event_router.sv','rtl/input_event_mux.sv','rtl/loop_control_plane.sv','rtl/performance_event_voice_bridge.sv','rtl/mgc3130_voice_mixer.sv','rtl/loop_audio_path.sv','rtl/uart_rx.sv','rtl/uart_rx_ref.sv','rtl/uart_rx_fifo.sv','rtl/gowin_uart_rx_fifo.sv','rtl/uart_control_link.sv','rtl/mgc3130_input_latch.sv','rtl/input_event_adapter.sv','rtl/mgc3130_loop_control_path.sv','rtl/mgc3130_reset_seq.sv','rtl/mgc3130_reader.sv','rtl/mgc3130_pattern_input.sv','rtl/mgc3130_uart_top.sv','rtl/uart_tx.sv','rtl/mgc3130_audio_uart_tx.sv','rtl/mgc_uart_report_tx.sv','rtl/i2s_pcm5102a_tx.sv','sim/gowin_i2c_master_stub.sv','sim/tb_mgc3130_uart_top_loop.sv')|%{Join-Path $root $_}
  & "$ModelSimBin/vlog.exe" -sv -work work $GowinSimLib @src *> compile.log
  if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  & "$ModelSimBin/vsim.exe" -c -novopt -l top_loop.log work.tb_mgc3130_uart_top_loop -do 'run 120 ms; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -or !(Select-String -Path top_loop.log -SimpleMatch 'tb_mgc3130_uart_top_loop PASS' -Quiet)){Get-Content top_loop.log;Get-Content console.log;throw 'top Loop test failed'}
  'tb_mgc3130_uart_top_loop PASS'
} finally { Pop-Location }
