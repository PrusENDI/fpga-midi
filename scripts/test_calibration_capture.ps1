param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $root 'impl/modelsim_calibration_capture'
New-Item -ItemType Directory -Force $dir | Out-Null
Push-Location $dir
try {
  if(!(Test-Path work/_info)){& "$ModelSimBin/vlib.exe" work;if($LASTEXITCODE){throw 'vlib failed'}}
  & "$ModelSimBin/vlog.exe" -sv -work work (Join-Path $root 'rtl/mgc3130_calibration_capture.sv') (Join-Path $root 'sim/tb_mgc3130_calibration_capture.sv') *> compile.log
  if($LASTEXITCODE){Get-Content compile.log;throw 'compile failed'}
  & "$ModelSimBin/vsim.exe" -c -l calibration_capture.log work.tb_mgc3130_calibration_capture -do 'run 1 ms; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -or !(Select-String -Path calibration_capture.log -SimpleMatch 'tb_mgc3130_calibration_capture PASS' -Quiet)){Get-Content calibration_capture.log;Get-Content console.log;throw 'calibration capture failed'}
  'tb_mgc3130_calibration_capture PASS'
} finally { Pop-Location }
