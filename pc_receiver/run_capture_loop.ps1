param(
    [double]$Seconds = 0,
    [string]$RawOutput = "capture.jsonl",
    [string]$EventOutput = "ambient_events.json",
    [int]$MinReports = 8
)

$script = Join-Path $PSScriptRoot "capture_loop.py"
$args = @($script, "--raw-output", $RawOutput, "--event-output", $EventOutput, "--min-reports", $MinReports)
if ($Seconds -gt 0) { $args += @("--seconds", $Seconds.ToString([Globalization.CultureInfo]::InvariantCulture)) }
python @args
exit $LASTEXITCODE
