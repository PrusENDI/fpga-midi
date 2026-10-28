param([string]$ModelSimBin = 'C:\modeltech64_10.6d\win64')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$buildDir = Join-Path $projectRoot 'impl/modelsim_v2_voice_engine_banked'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    if (!(Test-Path (Join-Path $ModelSimBin 'vlog.exe'))) { throw "Missing ModelSim tools under $ModelSimBin" }
    if (!(Test-Path 'work/_info')) { & (Join-Path $ModelSimBin 'vlib.exe') work }
    $src = @(
      'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v',
      (Join-Path $projectRoot 'rtl/v2_contract_pkg.sv'),
      (Join-Path $projectRoot 'rtl/v2_note_increment_rom.sv'),
      (Join-Path $projectRoot 'rtl/v2_voice_state_bank.sv'),
      (Join-Path $projectRoot 'rtl/v2_voice_engine_banked.sv'),
      (Join-Path $projectRoot 'sim/tb_v2_voice_engine_banked.sv')
    )
    & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work @src *> compile.log
    if ($LASTEXITCODE -ne 0) { Get-Content compile.log; throw 'vlog failed' }
    & (Join-Path $ModelSimBin 'vsim.exe') -c -novopt -onfinish stop -l voice_engine.log work.tb_v2_voice_engine_banked -do 'run -all; quit -code 0 -f' *> voice_engine.console.log
    if ($LASTEXITCODE -ne 0) { Get-Content voice_engine.log; throw 'V2 voice engine simulation failed' }
    if (Select-String -Path voice_engine.log -Pattern '\*\* (Error|Fatal):' -Quiet) { Get-Content voice_engine.log; throw 'V2 voice engine assertion failed' }
    if (!(Select-String -Path voice_engine.log -SimpleMatch 'tb_v2_voice_engine_banked PASS' -Quiet)) { Get-Content voice_engine.log; throw 'V2 voice engine did not reach PASS' }
    Write-Output "V2 voice engine simulation PASS: $buildDir"
} finally { Pop-Location }
