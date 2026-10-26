# Task 1 report — V2 contract

## Implementation

- Added the frozen V2 contract document with mode boundaries, one 96-bit event layout, 11-byte control packet, 22-byte telemetry packet, CRC16-CCITT-FALSE, two's-complement fields, and the unified address map.
- Added `rtl/v2_contract_pkg.sv` with V2 mode enum, packed command/telemetry types, event width, packet lengths, address/error constants, address validation, and width checks.
- Added `tools/v2_contract.py` serializers and validators with explicit masks/range checks and big-endian encoding.
- Added focused unit tests and linked the contract from `docs/README.md`.

## RED/GREEN evidence

RED: `python -m unittest tools.test_v2_contract -v` failed at import with `ModuleNotFoundError: No module named 'tools.v2_contract'` before implementation.

GREEN: `python -m unittest tools.test_v2_contract -v` — 5 tests passed.

`iverilog` and `verilator` are unavailable in this environment, so SV compilation could not be run. `git diff --check` passes for task files.

## Self-review

- Legacy V1 files were not edited.
- The existing user files `docs/mgc3130-coordinate-calibration-spec.md`, `docs/mgc3130-z-coupling-clutch-rebase-realtime-design-2026-10-22.md`, and `docs/投稿的文档.pdf` were preserved and excluded from the commit.
- Python packet lengths, CRC coverage, signed ranges, reserved event bit, and address rejection are executable assertions/tests.

## Concerns

SV compiler evidence is unavailable because neither `iverilog` nor `verilator` is installed. The package uses standard SystemVerilog packed types/functions and should be checked by the project toolchain.

## Review fix (2026-10-26)

- Replaced opaque `logic [95:0] v2_event_t` with a packed named-field struct. The declaration at `rtl/v2_contract_pkg.sv:12-25` exposes `reserved`, `type`, `track`, `tick`, `duration`, `note`, `velocity`, `pitch_mod`, `timbre_mod`, `flags`, and `sequence` in MSB-first contract order while retaining `$bits(v2_event_t)==96`.
- Added elaboration-time negative-width typedef checks at `rtl/v2_contract_pkg.sv:59-82` for event/command/telemetry widths, 11/22-byte lengths, and every accepted/rejected address boundary. Any violation produces a compile-time error in standard SV elaboration. The address predicate remains available for runtime decode checks.
- Focused Python tests: `python -m unittest tools.test_v2_contract -v` — 5 passed.
- `git diff --check` passed. No SV compiler is installed in this environment, so external syntax compilation remains unavailable.

## Follow-up fix (2026-10-26)

- Corrected `V2_TELEMETRY_WIDTH_CHECK` to require `$bits(v2_telemetry_t) == 144`, matching all packed telemetry fields. The wire serializer remains `V2_TELEMETRY_BYTES == 22`.
- ModelSim syntax evidence: `C:\modeltech64_10.6d\win64\vlog.exe -sv -work work rtl/v2_contract_pkg.sv` completed with 0 errors and 0 warnings.
- Python focused suite: 5 tests passed. `git diff --check` passed.

## Reopened gate: complete machine-readable contract

- `rtl/v2_contract_pkg.sv` now owns all named CSR addresses, access classification, UART op/ACK/telemetry types, event types/flags, and fault/error codes. The misleading negative-index typedef checks were removed; `sim/tb_v2_contract.sv` uses executable `$fatal` checks for widths, lengths, every address, access, and the complete event bit mapping.
- `tools/v2_contract.py` exports the matching constants and `CSR` definitions with access and 32-bit packing. Its control encoder/decoder now rejects invalid operations and RO/WO misuse. `tools/test_v2_contract.py` compares every Python constant against the SV source.
- `docs/v2-fpga-contract-2026-10-25.md` now fixes all 32-bit CSR layouts, shadow/APPLY/version/CRC rules, UART ACK/NACK and duplicate-sequence behavior, typed 22-byte telemetry, and the raw XYZ coordinate boundary.
- RED: `test_machine_contract_constants_match_sv` failed with missing `SV_CONSTANTS`; ModelSim `vlog` also failed on missing `V2_EV_NOTE_ON`/`V2_FLAG_TOUCH` before implementation.
- GREEN: `python -m unittest tools.test_v2_contract -v` passed 6 tests. `scripts/test_v2_contract.ps1` compiled with ModelSim 10.6d, passed the normal simulation, and confirmed both layout and width mutations trigger `$fatal`. Focused `git diff --check` passed.
- Scope: V1 and Task5 RTL were not edited. Task5 must import these constants in its next integration pass. Task3 raw-coordinate handling currently conflicts with the newly fixed 17-bit input boundary; that is documented as an integration failure to resolve and verify in Task3/4, not claimed fixed here.
