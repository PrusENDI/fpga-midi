$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$simBin = 'C:\modeltech64_10.6d\win64'
$outputDir = Join-Path $projectRoot 'impl\modelsim_reader_touch'
New-Item -ItemType Directory -Force $outputDir | Out-Null
Push-Location $outputDir
try {
    if (!(Test-Path 'work')) { & "$simBin\vlib.exe" work; if ($LASTEXITCODE) { throw 'vlib failed' } }
    & "$simBin\vlog.exe" -work work "$projectRoot\rtl\mgc3130_reader.sv" "$projectRoot\rtl\mgc3130_input_latch.sv" "$projectRoot\sim\tb_reader_touch.sv"
    if ($LASTEXITCODE) { throw 'vlog failed' }
    & "$simBin\vsim.exe" -c -lib work -l reader_touch.log tb_reader_touch -do 'run -all; quit -f'
    if ($LASTEXITCODE) { throw 'vsim failed' }
    $simLog = Get-Content reader_touch.log -Raw
    if ($simLog -notmatch 'tb_reader_touch PASS' -or $simLog -match '\*\* (Fatal|Error):') { throw 'Reader touch regression failed' }
} finally { Pop-Location }
