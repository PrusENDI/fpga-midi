param(
    [double]$Seconds = 0,
    [string]$Output = "capture.jsonl",
    [ValidateSet("jsonl", "csv")]
    [string]$Format = "jsonl"
)

$exe = Join-Path $PSScriptRoot "Static-Release\mgc3130_receiver.exe"
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Receiver is not built. Run: msbuild pc_receiver\mgc3130_receiver.vcxproj /p:Configuration=Static-Release /p:Platform=Win32"
}

$args = @("--format", $Format, "--output", $Output)
if ($Seconds -gt 0) { $args += @("--seconds", $Seconds.ToString([Globalization.CultureInfo]::InvariantCulture)) }
& $exe @args
exit $LASTEXITCODE
