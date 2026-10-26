param([string]$ModelSimBin='C:\modeltech64_10.6d\win64')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $root 'impl/modelsim_v2_voice_replay'
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $root
try {
    python -m tools.generate_v2_voice_replay (Join-Path $out 'voice.vec')
    if($LASTEXITCODE -ne 0){ throw 'vector generation failed' }
} finally { Pop-Location }
Push-Location $out
try {
    if(!(Test-Path 'work/_info')){ & "$ModelSimBin\vlib.exe" work; if($LASTEXITCODE -ne 0){throw 'vlib failed'} }
    $sources=@('rtl/v2_contract_pkg.sv','rtl/v2_note_increment_rom.sv','rtl/v2_voice_state_bank.sv',
               'rtl/v2_voice_engine_banked.sv','sim/tb_v2_voice_replay.sv') | ForEach-Object {Join-Path $root $_}
    & "$ModelSimBin\vlog.exe" -sv -work work 'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v' @sources *> compile.log
    if($LASTEXITCODE -ne 0){Get-Content compile.log; throw 'vlog failed'}
    foreach($ram in 0,1){
        & "$ModelSimBin\vsim.exe" -c -onfinish stop -l "replay_$ram.log" "-gUSE_GOWIN_RAM=$ram" work.tb_v2_voice_replay '+VECTORS=voice.vec' -do 'run 10 ms; quit -code 0 -f' *> "replay_$ram.console.log"
        if($LASTEXITCODE -ne 0 -or (Select-String -Path "replay_$ram.log" -Pattern '\*\* (Error|Fatal):' -Quiet) -or !(Select-String -Path "replay_$ram.log" -SimpleMatch 'tb_v2_voice_replay PASS' -Quiet)){
            Get-Content "replay_$ram.log" -Tail 35; throw "voice replay failed ram=$ram"
        }
        Select-String -Path "replay_$ram.log" -Pattern 'PASS|Errors:' | ForEach-Object Line
    }
} finally {Pop-Location}
