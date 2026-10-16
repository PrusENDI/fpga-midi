param(
    [string]$ModelSimBin = '',
    [string]$GowinSimLib = 'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if (!$ModelSimBin) {
    $ModelSimBin = Split-Path (Get-Command vsim -ErrorAction Stop).Source -Parent
}
if (!(Test-Path -LiteralPath $GowinSimLib)) { throw "Missing GW5A simulation library: $GowinSimLib" }
$buildDir = Join-Path $projectRoot 'impl/modelsim_loop_scheduler'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    if (!(Test-Path -LiteralPath 'work/_info')) {
        & (Join-Path $ModelSimBin 'vlib.exe') work
        if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    $sources = @(
        'rtl/performance_event_pkg.sv', 'rtl/loop_event_ram.sv',
        'rtl/loop_event_store.sv', 'rtl/loop_scheduler.sv',
        'sim/tb_loop_scheduler.sv', 'sim/tb_loop_scheduler_store.sv'
    ) | ForEach-Object { Join-Path $projectRoot $_ }
    & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work $GowinSimLib @sources *> compile.log
    if ($LASTEXITCODE -ne 0) { Get-Content compile.log; throw 'Scheduler compilation failed' }
    foreach ($case in @(
        @{ Top='tb_loop_scheduler'; Name='scheduler'; Params=@() },
        @{ Top='tb_loop_scheduler_store'; Name='integration_rtl'; Params=@('-gUSE_GOWIN_RAM=0') },
        @{ Top='tb_loop_scheduler_store'; Name='integration_gowin'; Params=@('-gUSE_GOWIN_RAM=1') }
    )) {
        $simParams = $case.Params
        $logName = "$($case.Name).log"
        & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish stop -l $logName @simParams "work.$($case.Top)" -do 'run 100 ms; quit -code 0 -f' *> "$($case.Name).console.log"
        if ($LASTEXITCODE -ne 0) { Get-Content $logName; throw "$($case.Name) simulator failed" }
        if (Select-String -Path $logName -Pattern '\*\* (Error|Fatal):' -Quiet) {
            Get-Content $logName; throw "$($case.Name) assertion failed"
        }
        if (!(Select-String -Path $logName -SimpleMatch "$($case.Top) PASS" -Quiet)) {
            Get-Content $logName; throw "$($case.Name) did not reach PASS within 100 ms"
        }
        Write-Output "$($case.Name) PASS: $buildDir/$logName"
    }
} finally {
    Pop-Location
}
