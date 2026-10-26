param([string]$ModelSimBin = 'C:\modeltech64_10.6d\win64')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$buildDir = Join-Path $projectRoot 'impl/modelsim_v2_sample_scheduler'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    if (!(Test-Path (Join-Path $ModelSimBin 'vlog.exe'))) { throw "Missing ModelSim tools under $ModelSimBin" }
    if (!(Test-Path 'work/_info')) { & (Join-Path $ModelSimBin 'vlib.exe') work; if ($LASTEXITCODE -ne 0) { throw 'vlib failed' } }
    $sources = @((Join-Path $projectRoot 'rtl/v2_sample_scheduler.sv'), (Join-Path $projectRoot 'sim/tb_v2_sample_scheduler.sv'))
    & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work @sources *> compile.log
    if ($LASTEXITCODE -ne 0) { Get-Content compile.log; throw 'vlog failed' }
    & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish stop -l scheduler.log work.tb_v2_sample_scheduler -do 'run 1001 ms; quit -code 0 -f' *> scheduler.console.log
    if ($LASTEXITCODE -ne 0) { Get-Content scheduler.log; throw 'vsim failed' }
    if (Select-String -Path scheduler.log -Pattern '\*\* (Error|Fatal):' -Quiet) { Get-Content scheduler.log; throw 'scheduler assertion failed' }
    if (!(Select-String -Path scheduler.log -SimpleMatch 'tb_v2_sample_scheduler PASS' -Quiet)) { Get-Content scheduler.log; throw 'scheduler did not reach PASS' }
    Write-Output "tb_v2_sample_scheduler PASS: $buildDir/scheduler.log"
} finally { Pop-Location }
