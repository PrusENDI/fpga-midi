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

## Indexed-contract correction after independent review

The previous `0x48..0x5C` fixed patch/gesture row could not address the parameters explicitly required by Task3/4/7/9/11. This revision uses six fixed addresses for indexed selector, shadow data, active data, status, CRC and APPLY. Four families cover per-track patch/rule values and global calibration/cursor values. Python `PATCH_PARAMETERS` holds every index, Q format, raw minimum/maximum/default and scope; corresponding family/index constants, CSR write masks, field shifts and data validation are exported by `rtl/v2_contract_pkg.sv`. The old `PATCH_GAIN`, `PATCH_BRIGHTNESS`, `GESTURE` and `FX` CSR names were removed. The documentation fixes readback and atomic APPLY at idle or Loop boundary, 128 ticks/four ticks per beat/60–240 BPM, and 1024-sample A/B/C wavetable coverage/version/CRC. ACK statuses and errors now specify interim/final APPLY replies and malformed sequence echo. Reserved event type/flag values are rejected by the Python encoder.

RED: New tests for indexed CSR and reserved event values failed on missing `PATCH_SHADOW_DATA` and accepted invalid event type. New indexed codec and wavetable tests then failed on missing functions. GREEN: `python -m unittest tools.test_v2_contract -v` passed 10 tests; `scripts/test_v2_contract.ps1` compiled and ran the ModelSim testbench, then actually reordered `tick`/`duration` in a package copy and narrowed a field in another copy; both mutations produced `$fatal`. `git diff --check` passed for Task1 files. The testbench checks all defined CSR access/write masks and invalid mode/track/WT/selector/BPM values.

This work defines and tests the contract and reference codec. It does not wire the indexed parameter bank, shadow/APPLY or UART control into the downstream RTL. Task5 still has duplicate event/flag/fault constants; its gate cannot pass until it imports this package. The Task3/4 raw-Z mismatch remains for their integration fix.

The final indexed table also includes Task7 lambda/density/min-length/rest policy,
fixed-scale/bend, Task11 gate/touch-bow, and Task4 alpha/Z thresholds/max-step/settle
under RULE and CURSOR families. Loop timing is fixed at 128 ticks, four ticks per
beat, BPM 60–240 (default 120). SV `v2_csr_data_valid` and Python validation reject
invalid mode/track/table/family/index/BPM values in addition to reserved write bits.
The implementation report must treat these as codec/contract/TB evidence only;
downstream RTL consumers remain an explicit follow-up.

## Indexed value-validation follow-up

`PATCH_SHADOW_DATA` now requires explicit selector context in the Python control
codec and validates the selected family/track/index against the frozen signed or
unsigned min/max range. `v2_patch_value_valid` in the SV package implements the
same generated metadata table (family, index, Q code, scope, min, max, default),
and `v2_csr_data_valid` accepts selector context for the data write. Tests cover
out-of-range OSC/patch data, missing selector context, and SV acceptance/rejection.
The complete parameter metadata is parity-tested against Python. Python 10/10 and
ModelSim TB/mutation tests pass; diff-check passes.
