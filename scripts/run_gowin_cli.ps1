param(
    [Parameter(Mandatory = $true)]
    [string]$TclScript,
    [string]$GowinRoot = 'C:\Gowin\Gowin_V1.9.12.04_x64',
    [string]$LicenseServer = '',
    [string]$RunId = '',
    [switch]$DebugMode
)

$ErrorActionPreference = 'Stop'

$gowinBin = Join-Path $GowinRoot 'IDE\bin'
$gwSh = Join-Path $gowinBin 'gw_sh.exe'
if (!(Test-Path -LiteralPath $gwSh)) {
    throw "Gowin CLI not found: $gwSh"
}
if (!(Test-Path -LiteralPath $TclScript)) {
    throw "Tcl script not found: $TclScript"
}

if (!$RunId) {
    $RunId = Get-Date -Format 'yyyyMMdd_HHmmss'
}
if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') {
    throw "RunId must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"
}

# gw_sh resolves its bundled Tcl/plugins and gwlicense.ini relative to this
# installation.  Keep the vendor bin directory first so a system Tcl/Qt DLL
# cannot be selected accidentally.
$env:GOWIN_HOME = $GowinRoot
$env:GW_HOME = $GowinRoot
$env:Path = "$gowinBin;$GowinRoot\IDE\bin\Lib;$env:Path"

# The installed gwlicense.ini is authoritative.  These aliases are also
# accepted by older Gowin builds and make the selected server explicit for
# child synthesis/P&R processes without editing the installation directory.
if ($LicenseServer) {
    $env:GW_LICENSE_FILE = $LicenseServer
    $env:GW_LICENSE_SERVER = $LicenseServer
    $env:GW_LIC = $LicenseServer
}

$args = @()
if ($DebugMode) { $args += '--debug' }
$args += (Resolve-Path -LiteralPath $TclScript).Path

$resolvedTcl = (Resolve-Path -LiteralPath $TclScript).Path
$projectRoot = Split-Path (Split-Path $resolvedTcl -Parent) -Parent
$runDir = Join-Path $projectRoot (Join-Path 'impl' "v2_top_fullpath_$RunId")
if (Test-Path -LiteralPath $runDir) {
    throw "Refusing to reuse existing full-path run directory: $runDir"
}

$oldRunId = $env:V2_FULLPATH_RUN_ID
$env:V2_FULLPATH_RUN_ID = $RunId
$startedUtc = [DateTime]::UtcNow.ToString('o')
$gwExit = 1

Push-Location $gowinBin
try {
    & $gwSh @args
    $gwExit = $LASTEXITCODE
}
finally {
    Pop-Location
    if (!(Test-Path -LiteralPath $runDir)) {
        New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    }
    $gitCommit = (& git -C $projectRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    $gitStatus = @(& git -C $projectRoot status --porcelain 2>$null)
    $hashes = [ordered]@{}
    foreach ($relativePath in @(
        'scripts/run_gowin_cli.ps1',
        'scripts/synth_v2_top_fullpath_20261029.tcl',
        'sim/v2_top_fullpath_probe.sv',
        'mgc3130_v2.cst',
        'mgc3130_v2_top_observable.sdc'
    )) {
        $candidate = Join-Path $projectRoot $relativePath
        if (Test-Path -LiteralPath $candidate) {
            $hashes[$relativePath] = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash
        }
    }
    $manifest = [ordered]@{
        schema = 'v2-fullpath-harness-v1'
        run_id = $RunId
        status = if ($gwExit -eq 0) { 'COMMAND_EXIT_0' } else { 'COMMAND_FAILED' }
        started_utc = $startedUtc
        finished_utc = [DateTime]::UtcNow.ToString('o')
        exit_code = $gwExit
        source_commit = ([string]$gitCommit).Trim()
        dirty_state = $gitStatus
        working_directory = (Get-Location).Path
        gowin_home = $GowinRoot
        gw_sh = $gwSh
        gw_sh_version = (Get-Item -LiteralPath $gwSh).VersionInfo.FileVersion
        license_server = $LicenseServer
        tcl_script = $resolvedTcl
        command = "$gwSh $($args -join ' ')"
        profile = [ordered]@{
            top_module = 'v2_top_fullpath_probe'
            device = 'GW5A-LV25MG121NES'
            use_mgc_reader = 1
            use_gowin_ram = 1
            use_potts = 1
            preserve_loop_plane = 1
            preserve_potts_plane = 1
            potts_horizon = 32
            fx_enable = 1
            fx_level = 1
            use_sspi_as_gpio = 1
            use_cpu_as_gpio = 1
        }
        harness_sha256 = $hashes
        report_paths = @(
            'impl/gwsynthesis/v2_top_fullpath.log',
            'impl/pnr/v2_top_fullpath.rpt.txt',
            'impl/pnr/v2_top_fullpath_tr_content.html',
            'impl/pnr/device.cfg',
            'impl/pnr/v2_top_fullpath.fs'
        )
    }
    $manifestPath = Join-Path $runDir 'harness-manifest.json'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Output "V2_FULLPATH_MANIFEST=$manifestPath"
    if ($null -eq $oldRunId) { Remove-Item Env:V2_FULLPATH_RUN_ID -ErrorAction SilentlyContinue }
    else { $env:V2_FULLPATH_RUN_ID = $oldRunId }
}

exit $gwExit
