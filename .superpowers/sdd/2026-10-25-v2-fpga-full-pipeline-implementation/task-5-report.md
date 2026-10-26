# Task 5 report: V2 LIVE and LOOP rule engines

## Implemented

- `rtl/v2_live_rule_engine.sv`: explicit LIVE rule FSM with left edge arm,
  reverse approach rejection, note mapping with hysteresis, four tick minimum
  event spacing, touch/bow gate selection, same-note edge revoice, expression
  control events for Z-only changes, and a one-entry ready/valid LIVE event
  output using the frozen 96-bit contract.
- `rtl/v2_loop_event_recorder.sv`: independent six-track recorder with per-track
  depth, monotonic timestamp checking, overflow/abort faults, event counters,
  readback, and an independent write ready/valid path.
- `tools/v2_rule_reference.py`: scalar LIVE and LOOP reference models and event,
  flag, and fault constants.
- `tools/test_v2_rule_reference.py`: vectors for left edge, reverse rejection,
  touch split, pure Z, invalid/rebased input, six tracks, monotonic tick,
  overflow, and abort.
- `sim/tb_v2_live_rule_engine.sv`, `sim/tb_v2_loop_event_recorder.sv`: ModelSim
  smoke benches covering event spacing, control-only Z, touch off, track readback,
  and stopped recorder behavior.

## Verification

```
python -m unittest tools.test_v2_rule_reference -v
C:\modeltech64_10.6d\win64\vlog.exe -work work rtl/v2_contract_pkg.sv rtl/v2_live_rule_engine.sv sim/tb_v2_live_rule_engine.sv rtl/v2_loop_event_recorder.sv sim/tb_v2_loop_event_recorder.sv
C:\modeltech64_10.6d\win64\vsim.exe -c -do "run -all; quit -f" tb_v2_live_rule_engine
C:\modeltech64_10.6d\win64\vsim.exe -c -do "run -all; quit -f" tb_v2_loop_event_recorder
git diff --check
```

All six Python tests and both RTL benches pass.  Generated `work/`, `transcript`,
and `vsim.wlf` files were removed after verification.

## Scope note

The rule engines are standalone V2 blocks.  They do not alter V1 top-level or
legacy EventTable/PCM paths.  Integration into a future V2 top should connect
the LIVE and LOOP ready/valid interfaces independently.

## Corrective gate closure (2026-10-26)

- LIVE imports frozen constants from `v2_contract_pkg`. A left-edge observation
  creates a pending arm; only a final rightward confirmation sets
  `left_edge_armed`. Reverse approach remains disarmed and reports
  `V2_FAULT_REVERSE`. `NOTE_OFF` obeys `MIN_EVENT_TICKS`.
- LIVE ready/valid holds the event word and state while `event_valid && !event_ready`.
  The Python model mirrors the pending-arm rule.
- LOOP uses an independent one-entry `loop_write_valid/data` holding register.
  `event_ready` is low while occupied, and output data remains stable until
  `write_ready`; contract duration is stored unchanged. Fault constants are
  imported from the contract package. The recorder remains six tracks with
  configurable default `DEPTH=64`; Task 6's store depth-16 policy is separate.
- Fresh verification: Python `tools.test_v2_rule_reference` — 6 passed;
  ModelSim `tb_v2_live_rule_engine PASS`; ModelSim
  `tb_v2_loop_event_recorder PASS`. Benches cover rightward arm confirmation,
  minimum-spacing NOTE_OFF, pure-Z control, held output under backpressure,
  six-track readback, stop, overflow, and abort paths.
