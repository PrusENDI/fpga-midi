param([string]$ModelSim = 'C:\modeltech64_10.6d\win64')
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildDir = Join-Path $projectRoot 'impl/modelsim_v2_audio_smoke'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
Push-Location $buildDir
try {
  foreach ($tool in @('vlib.exe','vlog.exe','vsim.exe')) {
    if (!(Test-Path (Join-Path $ModelSim $tool))) { throw "Missing ModelSim tool $tool under $ModelSim" }
  }
  if (!(Test-Path 'work/_info')) {
    & (Join-Path $ModelSim 'vlib.exe') work | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'vlib failed' }
  }
  $sources = @(
    (Join-Path $projectRoot 'rtl/v2_clock_gen.sv'),
    (Join-Path $projectRoot 'rtl/v2_reset_sync.sv'),
    (Join-Path $projectRoot 'rtl/v2_sample_scheduler.sv'),
    (Join-Path $projectRoot 'rtl/i2s_pcm5102a_tx.sv'),
    (Join-Path $projectRoot 'rtl/v2_audio_smoke_top.sv'),
    (Join-Path $projectRoot 'sim/tb_v2_audio_smoke.sv')
  )
  & (Join-Path $ModelSim 'vlog.exe') -sv '+define+V2_SIM' -work work @sources *> compile.log
  if ($LASTEXITCODE -ne 0) { Get-Content compile.log; throw 'vlog failed' }
  & (Join-Path $ModelSim 'vsim.exe') -c -onfinish stop -l audio_smoke.log work.tb_v2_audio_smoke -do 'run 12 ms; quit -code 0 -f' *> audio_smoke.console.log
  if ($LASTEXITCODE -ne 0) { Get-Content audio_smoke.console.log; throw 'vsim failed' }
  if (Select-String -Path audio_smoke.console.log -Pattern '\*\* (Error|Fatal):' -Quiet) {
    Get-Content audio_smoke.console.log; throw 'audio smoke assertion failed'
  }
  if (!(Select-String -Path audio_smoke.console.log -SimpleMatch 'tb_v2_audio_smoke PASS' -Quiet)) {
    Get-Content audio_smoke.console.log; throw 'audio smoke did not reach PASS'
  }
  Write-Output "tb_v2_audio_smoke PASS: $buildDir/audio_smoke.console.log"
} finally { Pop-Location }
