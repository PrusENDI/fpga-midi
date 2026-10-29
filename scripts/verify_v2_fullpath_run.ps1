param(
    [Parameter(Mandatory = $true)]
    [string]$RunDir,
    [switch]$SynthesisOnly,
    [switch]$Acceptance
)

$ErrorActionPreference = 'Stop'
$runPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RunDir).Path)
$failures = [System.Collections.Generic.List[string]]::new()
$observations = [System.Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) {
    [void]$failures.Add($Message)
}

if (!(Test-Path -LiteralPath $runPath -PathType Container)) {
    throw "Run directory does not exist: $runPath"
}

$manifestPath = Join-Path $runPath 'harness-manifest.json'
if (!(Test-Path -LiteralPath $manifestPath)) {
    Add-Failure "missing harness-manifest.json"
    $manifest = $null
} else {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.schema -ne 'v2-fullpath-harness-v1') { Add-Failure "unexpected manifest schema" }
    if ($manifest.status -ne 'COMMAND_EXIT_0') { Add-Failure "wrapper status is $($manifest.status), exit_code=$($manifest.exit_code)" }
    if ($manifest.profile.top_module -ne 'v2_top_fullpath_probe') { Add-Failure 'manifest top module mismatch' }
    if ([int]$manifest.profile.use_mgc_reader -ne 1 -or
        [int]$manifest.profile.use_potts -ne 1 -or
        [int]$manifest.profile.potts_horizon -ne 32 -or
        [int]$manifest.profile.fx_enable -ne 1 -or
        [int]$manifest.profile.fx_level -ne 1) {
        Add-Failure 'manifest full-path profile mismatch'
    }
}

$textFiles = Get-ChildItem -LiteralPath $runPath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\impl\\(gwsynthesis|pnr)\\' -and $_.Extension -in @('.log', '.txt', '.html', '.cfg') }
$allText = ($textFiles | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName -ErrorAction SilentlyContinue }) -join "`n"
foreach ($marker in @('RP0006', 'RP0008', 'NL0002')) {
    if ($allText -match $marker) { Add-Failure "tool marker $marker found" }
}

$synthDir = Join-Path $runPath 'impl/gwsynthesis'
$pnrDir = Join-Path $runPath 'impl/pnr'
$synthLog = Get-ChildItem -LiteralPath $synthDir -Filter '*.log' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (!$synthLog) { Add-Failure 'missing synthesis log' }
if (!$SynthesisOnly -and !(Test-Path -LiteralPath $pnrDir -PathType Container)) { Add-Failure 'missing P&R directory' }

$cfgPath = Join-Path $pnrDir 'device.cfg'
$cfgText = if (Test-Path -LiteralPath $cfgPath) { Get-Content -Raw -LiteralPath $cfgPath } else { '' }
$rptPath = Get-ChildItem -LiteralPath $pnrDir -Filter '*.rpt.txt' -File -ErrorAction SilentlyContinue | Select-Object -First 1
$rptText = if ($rptPath) { Get-Content -Raw -LiteralPath $rptPath.FullName } else { '' }
$timingPath = Get-ChildItem -LiteralPath $pnrDir -Filter '*_tr_content.html' -File -ErrorAction SilentlyContinue | Select-Object -First 1
$timingText = if ($timingPath) { Get-Content -Raw -LiteralPath $timingPath.FullName } else { '' }

if ($rptPath) {
    $logicMatch = [regex]::Match($rptText, 'Logic\s+\|\s+([0-9]+)\s*/\s*23040')
    if ($logicMatch.Success) {
        $logic = [int]$logicMatch.Groups[1].Value
        $observations.Add("logic=$logic/23040")
        if ($Acceptance -and $logic -gt 23040) { Add-Failure "logic exceeds GW5A limit: $logic" }
    } elseif ($Acceptance) { Add-Failure 'missing logic usage summary' }
} elseif (!$SynthesisOnly) { Add-Failure 'missing P&R report' }

if ($cfgText) {
    if ($cfgText -notmatch '(?m)^set SSPI regular_io = true\s*$') { Add-Failure 'SSPI regular_io is not true' }
    if ($cfgText -notmatch '(?m)^set CPU regular_io = true\s*$') { Add-Failure 'CPU regular_io is not true' }
}

if ($rptText) {
    if ($rptText -notmatch 'clk_50m\s+\|[^\r\n]*E2/5') { Add-Failure 'clk_50m is not reported at E2/5' }
    if ($rptText -match '(?i)PR2017|PR2028') { Add-Failure 'PR2017/PR2028 found in P&R report' }
}

if ($timingText) {
    $setupMatch = [regex]::Match($timingText, 'Numbers of Setup Violated Endpoints</td>\s*<td>([0-9]+)')
    $holdMatch = [regex]::Match($timingText, 'Numbers of Hold Violated Endpoints</td>\s*<td>([0-9]+)')
    $fmaxMatch = [regex]::Match($timingText, '<th>Actual Fmax</th>[\s\S]*?<td[^>]*>([0-9]+(?:\.[0-9]+)?)\(MHz\)</td>')
    if ($setupMatch.Success) {
        $setup = [int]$setupMatch.Groups[1].Value
        $observations.Add("setup_violations=$setup")
        if ($Acceptance -and $setup -ne 0) { Add-Failure "setup violations=$setup" }
    } elseif ($Acceptance) { Add-Failure 'missing setup violation count' }
    if ($holdMatch.Success) {
        $hold = [int]$holdMatch.Groups[1].Value
        $observations.Add("hold_violations=$hold")
        if ($Acceptance -and $hold -ne 0) { Add-Failure "hold violations=$hold" }
    } elseif ($Acceptance) { Add-Failure 'missing hold violation count' }
    if ($fmaxMatch.Success) {
        $fmax = [double]$fmaxMatch.Groups[1].Value
        $observations.Add("fmax_mhz=$fmax")
        if ($Acceptance -and $fmax -lt 100.0) { Add-Failure "Fmax=$fmax MHz is below 100 MHz" }
    } elseif ($Acceptance) { Add-Failure 'missing actual Fmax' }
} elseif ($Acceptance) { Add-Failure 'missing timing HTML report' }

$status = if ($failures.Count -eq 0) { 'PASS' } else { 'BLOCKED' }
$summary = [ordered]@{
    schema = 'v2-fullpath-verification-v1'
    status = $status
    run_dir = $runPath
    acceptance = [bool]$Acceptance
    observations = @($observations)
    failures = @($failures)
}
$summaryPath = Join-Path $runPath 'harness-verification.json'
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Output "V2_FULLPATH_VERIFY_STATUS=$status"
foreach ($observation in $observations) { Write-Output "OBSERVATION $observation" }
foreach ($failure in $failures) { Write-Output "FAILURE $failure" }
Write-Output "V2_FULLPATH_VERIFY_SUMMARY=$summaryPath"
if ($failures.Count -ne 0) { exit 1 }
exit 0
