param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$buildDir=Join-Path $projectRoot 'impl/modelsim_input_pipeline'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work;if($LASTEXITCODE -ne 0){throw 'vlib failed'}}
    $sources=@('rtl/control_protocol_pkg.sv','rtl/performance_event_pkg.sv',
      'rtl/mgc3130_reader.sv','rtl/mgc3130_input_latch.sv','rtl/input_event_adapter.sv',
      'sim/tb_reader_touch.sv','sim/tb_input_pipeline.sv') | ForEach-Object {Join-Path $projectRoot $_}
    & "$ModelSimBin/vlog.exe" -sv -work work @sources *> compile.log
    if($LASTEXITCODE -ne 0){Get-Content compile.log;throw 'compile failed'}
    & "$ModelSimBin/vsim.exe" -c -onfinish stop -l pipeline.log work.tb_input_pipeline -do 'run 1 ms; quit -code 0 -f' *> console.log
    if($LASTEXITCODE -ne 0 -or (Select-String -Path pipeline.log -Pattern '\*\* (Error|Fatal):' -Quiet) -or
       !(Select-String -Path pipeline.log -SimpleMatch 'tb_input_pipeline PASS' -Quiet)){
        Get-Content pipeline.log;throw 'input pipeline failed or timed out'
    }
    Write-Output "input pipeline PASS: $buildDir/pipeline.log"
} finally {Pop-Location}
