param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'impl/modelsim_soft_timbre'
New-Item -ItemType Directory -Force $dir | Out-Null
Push-Location $dir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work}
  $src=@('rtl/mgc3130_voice_mixer.sv','sim/tb_soft_timbre.sv')|%{Join-Path $root $_}
  & "$ModelSimBin/vlog.exe" -sv -work work @src *> compile.log
  if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  & "$ModelSimBin/vsim.exe" -c -l soft_timbre.log work.tb_soft_timbre -do 'run 1 ms; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -or !(Select-String -Path soft_timbre.log -SimpleMatch 'tb_soft_timbre PASS' -Quiet)){Get-Content soft_timbre.log;throw 'soft timbre failed'}
  'soft timbre PASS'
} finally { Pop-Location }
