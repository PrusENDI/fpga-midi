#!/usr/bin/env bash
# Run Gowin's Windows gw_sh.exe through the repository wrapper.
#
# Usage:
#   ./scripts/gw.sh scripts/synth_v2_voice_engine.tcl
#
# The wrapper resolves gwlicense.ini from the installed Gowin tree.  Set
# GOWIN_ROOT or GW_LICENSE_SERVER when the installation/server differs.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if (($# < 1)); then
  printf 'usage: %s <tcl-script> [wrapper arguments...]\n' "$0" >&2
  exit 2
fi

if command -v pwsh.exe >/dev/null 2>&1; then
  powershell_cmd="$(command -v pwsh.exe)"
elif command -v powershell.exe >/dev/null 2>&1; then
  powershell_cmd="$(command -v powershell.exe)"
else
  echo 'PowerShell (pwsh.exe or powershell.exe) is required to run Gowin CLI.' >&2
  exit 127
fi

wrapper_args=(-TclScript "$1")
shift

if [[ -n "${GOWIN_ROOT:-}" ]]; then
  wrapper_args+=(-GowinRoot "$GOWIN_ROOT")
fi
if [[ -n "${GW_LICENSE_SERVER:-}" ]]; then
  wrapper_args+=(-LicenseServer "$GW_LICENSE_SERVER")
fi

# Forward optional run_gowin_cli.ps1 switches such as -DebugMode.
wrapper_args+=("$@")

exec "$powershell_cmd" -NoProfile -ExecutionPolicy Bypass \
  -File "$script_dir/run_gowin_cli.ps1" "${wrapper_args[@]}"
