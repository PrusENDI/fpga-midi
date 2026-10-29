param([string]$ModelSimBin='C:\modeltech64_10.6d\win64', [string]$Baseline='ec10de4', [string]$CandidateRef='', [switch]$ExpectSampleWindowDifference, [switch]$ExpectSameLatency)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$baselineCommit=(& git -C $root rev-parse --verify "${Baseline}^{commit}").Trim()
if($LASTEXITCODE -ne 0){throw 'Cannot resolve baseline commit'}
$candidateIdentity='working tree'
$workingHead=(& git -C $root rev-parse --verify HEAD).Trim()
if($LASTEXITCODE -ne 0){throw 'Cannot resolve working tree HEAD'}
if($CandidateRef){
  $candidateIdentity=(& git -C $root rev-parse --verify "${CandidateRef}^{commit}").Trim()
  if($LASTEXITCODE -ne 0){throw 'Cannot resolve candidate commit'}
}
# A fresh directory and private library prevent stale RTL/work-library reuse.
$build=Join-Path $root ('impl/cursor_timed_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $build | Out-Null
$baseText=(& git -C $root show "${baselineCommit}:rtl/v2_cursor_filter_timed.sv") -join "`n"
if($LASTEXITCODE -ne 0){throw 'Cannot read baseline RTL'}
$baseText=$baseText.Replace('v2_cursor_filter_timed','v2_cursor_filter_timed_baseline').Replace('v2_cursor_divider_u32','v2_cursor_divider_u32_baseline')
$basePath=Join-Path $build 'baseline.sv'
[IO.File]::WriteAllText($basePath,$baseText)
$candidatePath=Join-Path $root 'rtl/v2_cursor_filter_timed.sv'
if($CandidateRef){
  $candidateText=(& git -C $root show "${candidateIdentity}:rtl/v2_cursor_filter_timed.sv") -join "`n"
  if($LASTEXITCODE -ne 0){throw 'Cannot read candidate RTL'}
  $candidatePath=Join-Path $build 'candidate.sv'
  [IO.File]::WriteAllText($candidatePath,$candidateText)
}
$candidateHash=(Get-FileHash -LiteralPath $candidatePath).Hash
$identity=@("BaselineRef=$Baseline; BaselineCommit=$baselineCommit", "CandidateRef=$CandidateRef; Candidate=$candidateIdentity; WorkingTreeHEAD=$workingHead", "Compiled=$candidatePath; RTL_SHA256=$candidateHash", "ExpectSameLatency=$ExpectSameLatency; ExpectSampleWindowDifference=$ExpectSampleWindowDifference; logs=$build")
$identity | Set-Content -LiteralPath (Join-Path $build 'source_identity.log')
$identity | Write-Output
Push-Location $build
try {
  & "$ModelSimBin/vlib.exe" work *> vlib.log
  if($LASTEXITCODE -ne 0){throw 'vlib failed'}
  $sources=@((Join-Path $root 'rtl/v2_input_pkg.sv'),$basePath,$candidatePath,(Join-Path $root 'sim/tb_v2_cursor_timed_compare.sv'))
  & "$ModelSimBin/vlog.exe" -sv -work work @sources *> compile.log
  if($LASTEXITCODE -ne 0){Get-Content compile.log; throw 'vlog failed'}
  $vector=(Join-Path $root 'tools/testdata/v2_input/cursor_replay_fast_01.vec').Replace('\','/')
  $expectWindow=if($ExpectSampleWindowDifference){1}else{0}
  $expectLatency=if($ExpectSameLatency){1}else{0}
  & "$ModelSimBin/vsim.exe" -c -novopt -onfinish stop -l replay.log work.tb_v2_cursor_timed_compare "+VECTORS=$vector" "+EXPECT_SAMPLE_WINDOW=$expectWindow" "+EXPECT_SAME_LATENCY=$expectLatency" -do 'run -all; quit -code 0 -f' *> console.log
  if($LASTEXITCODE -ne 0 -or (Select-String -Path replay.log -Pattern '\*\* (Error|Fatal):' -Quiet) -or !(Select-String -Path replay.log -SimpleMatch -Pattern 'tb_v2_cursor_timed_compare PASS' -Quiet)){
    Get-Content replay.log; throw 'timed cursor differential replay failed'
  }
  Select-String -Path replay.log -SimpleMatch -Pattern 'tb_v2_cursor_timed_compare PASS' | ForEach-Object {$_.Line}
} finally {Pop-Location}
