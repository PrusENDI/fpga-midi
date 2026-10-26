param(
    [Parameter(Mandatory = $true)]
    [string]$TclScript,
    [string]$GowinRoot = 'C:\Gowin\Gowin_V1.9.12.04_x64',
    [string]$LicenseServer = '',
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

Push-Location $gowinBin
try {
    & $gwSh @args
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
