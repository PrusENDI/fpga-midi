param([string]$ModelSimBin='C:\modeltech64_10.6d\win64',
      [string]$GowinSimLib='C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$buildDir=Join-Path $projectRoot 'impl/modelsim_control_plane'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work;if($LASTEXITCODE -ne 0){throw 'vlib failed'}}
    $sources=@('rtl/control_protocol_pkg.sv','rtl/performance_event_pkg.sv',
      'rtl/loop_event_ram.sv','rtl/loop_event_store.sv','rtl/loop_scheduler.sv',
      'rtl/command_mailbox.sv','rtl/control_csr.sv','rtl/mode_manager.sv','rtl/performance_event_fifo_wrapper.sv','rtl/performance_event_ingress.sv','rtl/performance_event_router.sv','rtl/input_event_mux.sv','rtl/loop_control_plane.sv',
      'sim/tb_command_mailbox.sv','sim/tb_control_csr.sv','sim/tb_mode_manager.sv','sim/tb_performance_event_router.sv','sim/tb_loop_control_plane.sv') |
        ForEach-Object {Join-Path $projectRoot $_}
    & "$ModelSimBin/vlog.exe" -sv -work work $GowinSimLib @sources *> compile.log
    if($LASTEXITCODE -ne 0){Get-Content compile.log;throw 'compile failed'}
    $cases=@(
      @{Top='tb_command_mailbox';Name='mailbox';Params=@()},
      @{Top='tb_control_csr';Name='csr';Params=@()},
      @{Top='tb_mode_manager';Name='mode';Params=@()},
      @{Top='tb_performance_event_router';Name='router';Params=@()},
      @{Top='tb_loop_control_plane';Name='plane_rtl';Params=@('-gUSE_GOWIN_RAM=0')},
      @{Top='tb_loop_control_plane';Name='plane_gowin';Params=@('-gUSE_GOWIN_RAM=1')})
    foreach($case in $cases){
        $params=$case.Params;$log="$($case.Name).log"
        & "$ModelSimBin/vsim.exe" -c -onfinish stop -l $log @params "work.$($case.Top)" -do 'run 100 ms; quit -code 0 -f' *> "$($case.Name).console.log"
        if($LASTEXITCODE -ne 0 -or (Select-String -Path $log -Pattern '\*\* (Error|Fatal):' -Quiet) -or
           !(Select-String -Path $log -SimpleMatch "$($case.Top) PASS" -Quiet)){
            Get-Content $log;throw "$($case.Name) failed or timed out"
        }
        Write-Output "$($case.Name) PASS: $buildDir/$log"
    }
} finally {Pop-Location}
