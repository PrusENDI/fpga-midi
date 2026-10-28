param([string]$ModelSimBin = 'C:\modeltech64_10.6d\win64')
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildDir = Join-Path $projectRoot 'impl/modelsim_v2_loop_transactions'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
  foreach ($tool in @('vlib.exe','vlog.exe','vsim.exe')) {
    if (!(Test-Path (Join-Path $ModelSimBin $tool))) { throw "Missing ModelSim tool $tool under $ModelSimBin" }
  }
  if (!(Test-Path 'work/_info')) {
    & (Join-Path $ModelSimBin 'vlib.exe') work | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
  }
  $sources = @(
    'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v',
    (Join-Path $projectRoot 'rtl/v2_contract_pkg.sv'),
    (Join-Path $projectRoot 'rtl/v2_loop_event_store.sv'),
    (Join-Path $projectRoot 'rtl/v2_loop_event_store_dpb.sv'),
    (Join-Path $projectRoot 'rtl/v2_loop_event_recorder.sv'),
    (Join-Path $projectRoot 'rtl/v2_loop_scheduler.sv'),
    (Join-Path $projectRoot 'sim/tb_v2_loop_event_recorder.sv'),
    (Join-Path $projectRoot 'sim/tb_v2_loop_transactions.sv'),
    (Join-Path $projectRoot 'sim/tb_v2_loop_store_dpb.sv')
  )
  & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work @sources *> compile.log
  if ($LASTEXITCODE -ne 0) { Get-Content compile.log; throw 'vlog failed' }
  foreach ($top in @('tb_v2_loop_event_recorder','tb_v2_loop_transactions','tb_v2_loop_store_dpb')) {
    $log = "$top.log"
    & (Join-Path $ModelSimBin 'vsim.exe') -c -onfinish stop -l $log "work.$top" -do 'run 5 ms; quit -code 0 -f' *> "$top.console.log"
    if ($LASTEXITCODE -ne 0) { Get-Content "$top.console.log"; throw "$top failed" }
    if (Select-String -Path $log -Pattern '\*\* (Error|Fatal):' -Quiet) { Get-Content $log; throw "$top assertion failed" }
    if (!(Select-String -Path $log -SimpleMatch "$top PASS" -Quiet)) { Get-Content $log; throw "$top did not reach PASS" }
    Write-Output "$top PASS: $buildDir/$log"
  }
} finally { Pop-Location }
