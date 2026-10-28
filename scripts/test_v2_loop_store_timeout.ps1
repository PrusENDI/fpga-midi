param([string]$ModelSimBin = 'C:\modeltech64_10.6d\win64')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$buildDir = Join-Path $projectRoot 'impl/modelsim_v2_loop_store_timeout'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    if (!(Test-Path (Join-Path $ModelSimBin 'vlog.exe'))) { throw "Missing ModelSim tools under $ModelSimBin" }
    if (!(Test-Path 'work/_info')) { & (Join-Path $ModelSimBin 'vlib.exe') work }
    $src = @(
      'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v',
      (Join-Path $projectRoot 'rtl/v2_loop_event_store.sv'),
      (Join-Path $projectRoot 'rtl/v2_loop_event_store_dpb.sv'),
      (Join-Path $projectRoot 'sim/tb_v2_loop_store_timeout.sv')
    )
    & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work @src *> compile.log
    if ($LASTEXITCODE -ne 0) { Get-Content compile.log; throw 'vlog failed' }
    & (Join-Path $ModelSimBin 'vsim.exe') -c -novopt -onfinish stop -l v2_loop_store_timeout.log work.tb_v2_loop_store_timeout -do 'run -all; quit -code 0 -f' *> v2_loop_store_timeout.console.log
    if ($LASTEXITCODE -ne 0) { Get-Content v2_loop_store_timeout.log; throw 'V2 loop store timeout simulation failed' }
    if (Select-String -Path v2_loop_store_timeout.log -Pattern '\*\* (Error|Fatal):' -Quiet) { Get-Content v2_loop_store_timeout.log; throw 'V2 loop store timeout assertion failed' }
    if (!(Select-String -Path v2_loop_store_timeout.log -SimpleMatch 'tb_v2_loop_store_timeout PASS' -Quiet)) { Get-Content v2_loop_store_timeout.log; throw 'V2 loop store timeout did not reach PASS' }
    Write-Output "V2 loop store timeout simulation PASS: $buildDir"
} finally { Pop-Location }
