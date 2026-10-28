param([string]$ModelSimBin = 'C:\modeltech64_10.6d\win64')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$buildDir = Join-Path $projectRoot 'impl/modelsim_v2_patch_bank'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
    foreach ($tool in @('vlib.exe', 'vlog.exe', 'vsim.exe')) {
        if (!(Test-Path (Join-Path $ModelSimBin $tool))) { throw "Missing ModelSim tool $tool under $ModelSimBin" }
    }
    if (!(Test-Path 'work/_info')) { & (Join-Path $ModelSimBin 'vlib.exe') work | Out-Null }
    $src = @(
        'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v',
        (Join-Path $projectRoot 'rtl/v2_contract_pkg.sv'),
        (Join-Path $projectRoot 'rtl/v2_patch_bank.sv'),
        (Join-Path $projectRoot 'sim/tb_v2_patch_bank.sv')
    )
    & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work @src *> compile.log
    if ($LASTEXITCODE -ne 0) { Get-Content compile.log; throw 'vlog failed' }
    & (Join-Path $ModelSimBin 'vsim.exe') -c -novopt -onfinish stop -l v2_patch_bank.log work.tb_v2_patch_bank -do 'run -all; quit -code 0 -f' *> v2_patch_bank.console.log
    if ($LASTEXITCODE -ne 0) { Get-Content v2_patch_bank.log; throw 'V2 patch bank simulation failed' }
    if (Select-String -Path v2_patch_bank.log -Pattern '\*\* (Error|Fatal):' -Quiet) { Get-Content v2_patch_bank.log; throw 'V2 patch bank assertion failed' }
    if (!(Select-String -Path v2_patch_bank.log -SimpleMatch 'tb_v2_patch_bank PASS' -Quiet)) { Get-Content v2_patch_bank.log; throw 'V2 patch bank did not reach PASS' }
    Write-Output "V2 patch bank simulation PASS: $buildDir"
} finally { Pop-Location }
