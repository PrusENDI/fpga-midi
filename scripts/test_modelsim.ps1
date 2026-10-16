param([string]$ModelSimBin = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (!$ModelSimBin) {
    $ModelSimBin = Split-Path (Get-Command vsim -ErrorAction Stop).Source -Parent
}
$buildDir = Join-Path $projectRoot 'impl/modelsim_fifo'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    & (Join-Path $ModelSimBin 'vlib.exe') work
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    $sources = @(
        'rtl/performance_event_pkg.sv',
        'rtl/performance_event_fifo_wrapper.sv',
        'rtl/uart_tx.sv',
        'rtl/mgc3130_audio_uart_tx.sv',
        'rtl/mgc_uart_report_tx.sv',
        'sim/tb_performance_event_fifo.sv'
    ) | ForEach-Object { Join-Path $projectRoot $_ }
    & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work @sources
    if ($LASTEXITCODE -ne 0) { throw 'SystemVerilog compilation failed' }
    # Bound simulated runtime so a handshake deadlock cannot run forever.
    & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish stop -l fifo.log work.tb_performance_event_fifo -do 'run 1 ms; quit -code 0 -f'
    if ($LASTEXITCODE -ne 0) { throw 'ModelSim failed' }
    if (Select-String -Path fifo.log -Pattern '\*\* (Error|Fatal):' -Quiet) {
        throw 'ModelSim reported an error or assertion failure'
    }
    if (!(Select-String -Path fifo.log -SimpleMatch 'tb_performance_event_fifo PASS' -Quiet)) {
        throw 'FIFO test did not reach PASS within the time limit'
    }
    Write-Output "FIFO RTL fallback PASS; log: $buildDir/fifo.log"
} finally {
    Pop-Location
}
