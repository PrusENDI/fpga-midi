param([string]$ModelSimBin = 'C:\modeltech64_10.6d\win64')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$buildDir = Join-Path $projectRoot 'impl/modelsim_v2_top'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    if (!(Test-Path (Join-Path $ModelSimBin 'vlog.exe'))) { throw "Missing ModelSim tools under $ModelSimBin" }
    if (!(Test-Path 'work/_info')) { & (Join-Path $ModelSimBin 'vlib.exe') work }
    $src = @(
      'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v',
      (Join-Path $projectRoot 'rtl/v2_contract_pkg.sv'), (Join-Path $projectRoot 'rtl/v2_input_pkg.sv'),
      (Join-Path $projectRoot 'rtl/v2_touch_info_decoder.sv'), (Join-Path $projectRoot 'rtl/mgc3130_input_latch.sv'),
      (Join-Path $projectRoot 'rtl/v2_input_calibration.sv'), (Join-Path $projectRoot 'rtl/v2_position_validity.sv'),
      (Join-Path $projectRoot 'rtl/v2_cursor_filter_timed.sv'), (Join-Path $projectRoot 'rtl/v2_live_rule_engine.sv'),
      (Join-Path $projectRoot 'rtl/v2_loop_event_recorder.sv'), (Join-Path $projectRoot 'rtl/v2_loop_event_store_dpb.sv'),
      (Join-Path $projectRoot 'rtl/v2_loop_scheduler.sv'), (Join-Path $projectRoot 'rtl/v2_potts_commit_fsm.sv'),
      (Join-Path $projectRoot 'rtl/v2_note_increment_rom.sv'), (Join-Path $projectRoot 'rtl/v2_voice_state_bank.sv'),
      (Join-Path $projectRoot 'rtl/v2_voice_engine_banked.sv'), (Join-Path $projectRoot 'rtl/v2_fx_lite.sv'),
      (Join-Path $projectRoot 'rtl/v2_test_mode.sv'),
      (Join-Path $projectRoot 'rtl/v2_clock_gen.sv'), (Join-Path $projectRoot 'rtl/v2_reset_sync.sv'),
      (Join-Path $projectRoot 'rtl/v2_sample_scheduler.sv'), (Join-Path $projectRoot 'rtl/i2s_pcm5102a_tx.sv'),
      (Join-Path $projectRoot 'rtl/uart_rx.sv'), (Join-Path $projectRoot 'rtl/uart_tx.sv'),
      (Join-Path $projectRoot 'rtl/v2_uart_link.sv'), (Join-Path $projectRoot 'rtl/v2_telemetry_snapshot.sv'),
      (Join-Path $projectRoot 'rtl/mgc3130_reader.sv'), (Join-Path $projectRoot 'sim/gowin_i2c_master_stub.sv'),
      (Join-Path $projectRoot 'rtl/mgc3130_v2_top.sv'), (Join-Path $projectRoot 'sim/tb_mgc3130_v2_top.sv')
    )
    & (Join-Path $ModelSimBin 'vlog.exe') +define+V2_SIM -sv -work work @src *> compile.log
    if ($LASTEXITCODE -ne 0) { Get-Content compile.log; throw 'vlog failed' }
    & (Join-Path $ModelSimBin 'vsim.exe') -c -novopt -onfinish stop -l v2_top.log work.tb_mgc3130_v2_top -do 'run -all; quit -code 0 -f' *> v2_top.console.log
    if ($LASTEXITCODE -ne 0) { Get-Content v2_top.log; throw 'V2 top simulation failed' }
    if (Select-String -Path v2_top.log -Pattern '\*\* (Error|Fatal):' -Quiet) { Get-Content v2_top.log; throw 'V2 top assertion failed' }
    if (!(Select-String -Path v2_top.log -SimpleMatch 'tb_mgc3130_v2_top PASS' -Quiet)) { Get-Content v2_top.log; throw 'V2 top did not reach PASS' }
    Write-Output "V2 top simulation PASS: $buildDir"
} finally { Pop-Location }
