param([string]$ModelSimBin = 'C:\modeltech64_10.6d\win64')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$buildDir = Join-Path $projectRoot 'impl/modelsim_v2_uart_task10'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    if (!(Test-Path (Join-Path $ModelSimBin 'vlog.exe'))) { throw "Missing ModelSim tools under $ModelSimBin" }
    if (!(Test-Path 'work/_info')) {
        & (Join-Path $ModelSimBin 'vlib.exe') work
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    $sources = @(
        (Join-Path $projectRoot 'rtl/v2_contract_pkg.sv'),
        (Join-Path $projectRoot 'rtl/v2_uart_link.sv'),
        (Join-Path $projectRoot 'sim/tb_v2_uart_link.sv'),
        (Join-Path $projectRoot 'rtl/v2_telemetry_snapshot.sv'),
        (Join-Path $projectRoot 'sim/tb_v2_telemetry.sv')
    )
    & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work @sources *> compile.log
    if ($LASTEXITCODE -ne 0) { Get-Content compile.log; throw 'vlog failed' }
    foreach ($top in @('tb_v2_uart_link', 'tb_v2_telemetry')) {
        $log = "$top.log"
        & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish stop -l $log "work.$top" -do 'run -all; quit -code 0 -f' *> "$top.console.log"
        if ($LASTEXITCODE -ne 0) { Get-Content $log; throw "$top failed" }
        if (Select-String -Path $log -Pattern '\*\* (Error|Fatal):' -Quiet) { Get-Content $log; throw "$top assertion failed" }
        if (!(Select-String -Path $log -SimpleMatch "${top} PASS" -Quiet)) { Get-Content $log; throw "$top did not reach PASS" }
    }
    Write-Output "Task 10 UART/telemetry PASS: $buildDir"
} finally { Pop-Location }
