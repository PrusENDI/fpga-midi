# MGC3130 Calibration Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a temporary, production-independent raw MGC3130 XYZ capture path that streams framed reports over C3/COM4 and records them as CSV for calibration analysis.

**Architecture:** Add a standalone `mgc3130_uart_calibration_top` that reuses the existing reset sequence and parsed `mgc3130_reader`, then sends each report through a bounded capture FIFO and UART serializer. Keep the Loop top and binary Loop command protocol unchanged. Add a host Python tool with the same fixed frame format and focused RTL/host tests.

**Tech Stack:** SystemVerilog, ModelSim/PowerShell scripts, Python 3 standard library, existing Gowin I2C MASTER and UART primitives.

**Spec:** Approved in chat on 2026-10-18: independent calibration top, raw post-reader fields, fixed binary frames with sync/sequence/timestamp/flags/CRC8, host CSV plus metadata/summary, no production bitstream overwrite.

## Global Constraints

- Baseline is local `632a9c7` on `feat/loop-event-store`.
- Do not modify UART Loop protocol or `mgc3130_uart_loop_top` behavior.
- Do not execute `git reset` or `git clean`.
- Do not generate or burn a bitstream during this implementation.
- Capture raw reader outputs before input filtering, hysteresis, note mapping, or Z gating.
- Preserve report and frame loss visibility through sequence numbers and overflow flags.

---

### Task 1: Lock the frame contract with host tests

**Files:**
- Create: `tools/mgc3130_calibration_protocol.py`
- Create: `tools/test_mgc3130_calibration_protocol.py`

**Interfaces:**
- `encode_frame(frame_type, sequence, timestamp, flags, x, y, z, gesture, error_code, touch_info, build_tag=0) -> bytes`
- `decode_frames(data: bytes) -> list[dict]`
- `crc8(data: bytes) -> int`

- [ ] Write tests for a valid metadata frame and report frame, CRC rejection, sequence-gap detection, and resynchronization after garbage bytes.
- [ ] Run `python -m unittest tools\test_mgc3130_calibration_protocol.py`; verify the tests fail because the protocol module is absent.
- [ ] Implement the fixed frame layout: `A5 5A version type length sequence timestamp flags x y z gesture error_code touch_info build_tag crc8`, little-endian integers, and CRC8 over all bytes after sync through the last payload byte.
- [ ] Implement a parser that scans for sync, validates version/length/CRC, and returns dictionaries with `gap_before` metadata.
- [ ] Re-run the unittest command and verify all protocol tests pass.

### Task 2: Add the RTL frame builder and capture FIFO

**Files:**
- Create: `rtl/mgc3130_calibration_capture.sv`
- Create: `sim/tb_mgc3130_calibration_capture.sv`
- Create: `scripts/test_calibration_capture.ps1`

**Interfaces:**
- Inputs: `clk`, `rst_n`, `mgc_ready`, report fields from `mgc3130_reader`, `build_tag`.
- Outputs: `tx_valid`, `tx_data`, `capture_overflow`, `report_sequence`.

- [ ] Write a failing SystemVerilog test that injects metadata and report pulses, checks exact sync/version/length/payload/CRC bytes, checks sequence increment, and checks FIFO overflow remains sticky.
- [ ] Run `scripts\test_calibration_capture.ps1`; verify the test fails before the RTL module exists.
- [ ] Implement a fixed-length 32-byte frame builder with a 16-byte-or-larger byte FIFO, one-cycle input capture, report sequence, 32-bit free-running timestamp, flags, and CRC8.
- [ ] Implement startup metadata emission once after `mgc_ready` with `frame_type=0`, plus report frames with `frame_type=1`.
- [ ] Drive the existing `uart_tx` byte serializer through a valid/ready byte interface and hold `tx_data` stable while stalled.
- [ ] Re-run the focused ModelSim script and verify PASS.

### Task 3: Add the standalone calibration top

**Files:**
- Create: `rtl/mgc3130_uart_calibration_top.sv`
- Create: `sim/tb_mgc3130_uart_calibration_top.sv`
- Create: `scripts/test_calibration_top.ps1`

**Interfaces:**
- Board ports mirror the MGC pins and `uart_tx` from `mgc3130_uart_top`; `uart_rx` is retained for pin compatibility and unused.

- [ ] Write a failing top-level simulation that uses the existing Gowin I2C simulation stub, waits for `mgc_ready`, and verifies the calibration startup frame reaches the UART output.
- [ ] Run the top-level test and verify it fails before the wrapper exists.
- [ ] Reuse `mgc3130_reset_seq` and `mgc3130_reader`; connect raw reader fields directly to `mgc3130_calibration_capture`.
- [ ] Instantiate `uart_byte_serializer` at 115200 baud and connect capture bytes to C3.
- [ ] Tie PCM outputs low, omit Loop control and audio modules, and expose a `BUILD_TAG` parameter without changing the production top.
- [ ] Re-run the top-level test and verify PASS.

### Task 4: Add the capture CLI and data products

**Files:**
- Create: `tools/capture_mgc3130_calibration.py`
- Create: `tools/test_capture_mgc3130_calibration.py`
- Create: `calibration/README.md`

**Interfaces:**
- CLI: `python tools\capture_mgc3130_calibration.py --port COM4 --seconds N --out DIR [--baud 115200]`.

- [ ] Write host tests for decoding a metadata frame, writing CSV rows, rejecting CRC errors, reporting sequence gaps, and preserving raw binary bytes.
- [ ] Run the host test command and verify it fails before the CLI exists.
- [ ] Implement serial capture with a startup metadata wait, timeout, CRC/gap counters, raw `frames.bin`, `samples.csv`, `metadata.json`, and `summary.json`.
- [ ] Keep the tool standard-library-only except for `pyserial`, and make it usable with a synthetic byte stream in tests.
- [ ] Document the physical setup, startup verification, fixed action protocol, and output files in `calibration/README.md`.
- [ ] Re-run host tests and verify PASS.

### Task 5: Repository verification and review boundary

**Files:**
- Modify: `README.md` only if the new calibration entry point needs a short pointer.

- [ ] Run the focused calibration protocol, RTL capture, top-level, and host tests.
- [ ] Run existing regression scripts for input adapter, loop audio path, router timing, voice bridge, and mode-gated paths.
- [ ] Run `git diff --stat` and `git diff --check`.
- [ ] Confirm no `.fs`, `.bin`, or production generated bitstream changed.
- [ ] Show the complete diff summary and list the exact files intended for commit before any commit is made.
