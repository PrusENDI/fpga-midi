# FPGA-Native Loop Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the approved fixed-resource four-track Loop control plane with valid/ready events, double-buffered event storage, deterministic scheduling, bounded UART control, and graded recovery while keeping the 48 kHz audio path hardware-driven.

**Architecture:** Add small, focused RTL modules around the existing MGC3130 input and audio engine. A single 50 MHz clock uses clock-enables for sample and sixteenth-note timing. Input events pass through FIFOs into a mode manager; Loop storage uses two banks of 4×16 fixed event slots; the scheduler scans slots at each tick and emits events to the existing voice path.

**Tech Stack:** SystemVerilog/Verilog RTL, Gowin GW5A-25A, existing Gowin I²C master, existing 50 MHz clock, existing simulation testbenches and Gowin `gw_sh` build flow.

**Spec:** `docs/superpowers/specs/2026-10-15-mgc3130-loop-modulation-design.md`

## Global Constraints

- Keep one `clk_50m` domain; use `sample_ce` and `sixteenth_ce` clock-enables instead of new asynchronous clocks.
- Preserve the verified MGC3130 I²C pins, reset sequence, UART pin C3, PCM5102A pins, and Gowin project settings.
- Use `valid/ready` for event transfer; no new naked one-cycle event pulses across module boundaries.
- Preserve active Loop bank during recording failures; only swap banks at a Loop boundary.
- Keep audio DDS, mixer, and I²S timing independent of UART and sensor stalls.
- Do not add a softcore in this implementation pass.
- Use Gowin FIFO/RAM IP only behind project-owned wrappers; do not expose vendor-specific ports to control logic.
- Every new module must have a focused simulation test before top-level integration.

---

## Gap-Closure Addendum (2026-10-17)

The core Loop RTL and isolated board boundary are implemented, but the shipped
board top still selects the legacy pattern-input mixer. The following tasks
close that gap in dependency order. A task is complete only when its focused
test passes and the named artifact is committed.

### Task 8: Make the board top select the Loop path

**Files:**
- Modify: `rtl/mgc3130_uart_top.sv`
- Modify: `sim/tb_mgc3130_uart_top_loop.sv`
- Modify: `scripts/test_board_integration.ps1`
- Modify: `mgc3130_uart.gprj`

**Contract:** Add `parameter integer LOOP_CONTROL_ENABLE=0`. With `0`, preserve
the existing ASCII/legacy mixer behavior. With `1`, instantiate
`mgc3130_loop_control_path`, feed it the reader/latch outputs, and select its
sample stream for I2S/audio UART. The focused test must compile both parameter
values and assert that the Loop-enabled instance receives a valid command and
produces a mixer event.

- [ ] Step 1: Add the parameterized top-level test and run it to show the
  Loop-enabled case cannot yet reach the top-level mixer.
- [ ] Step 2: Add the parameterized path selection and top-level instance.
- [ ] Step 3: Run the top-level test for both parameter values and compile the
  complete RTL source list.
- [ ] Step 4: Commit `Integrate Loop path into board top`.

### Task 9: Serialize Loop mailbox responses on C3

**Files:**
- Modify: `rtl/mgc3130_uart_top.sv`
- Create: `rtl/uart_byte_serializer.sv`
- Create: `sim/tb_uart_byte_serializer.sv`

**Contract:** Convert `tx_valid/tx_ready/tx_data` from
`mgc3130_loop_control_path` into 115200 8N1 bytes using the existing UART TX
implementation. While Loop control is enabled, ASCII status transmission is
disabled and C3 carries only binary responses. The serializer must hold one
byte until `uart_tx.busy=0`, apply backpressure, and preserve ordering.

- [ ] Step 1: Write the serializer test for two bytes with a stalled TX.
- [ ] Step 2: Run it and verify it fails before the serializer exists.
- [ ] Step 3: Implement the serializer and connect it to C3.
- [ ] Step 4: Run serializer and board integration tests.
- [ ] Step 5: Commit `Serialize Loop mailbox responses on UART TX`.

### Task 10: Expose diagnostics and define Presence release

**Files:**
- Modify: `rtl/mgc3130_loop_control_path.sv`
- Modify: `rtl/mgc3130_uart_top.sv`
- Modify: `sim/tb_mgc3130_loop_control_path.sv`
- Modify: `docs/loop-control-plane-interface.md`
- Modify: `README.md`

**Contract:** Expose sticky RX overflow, RX framing error, adapter overflow,
and control fault through the status path. Use XYZ invalid or the configured
timeout as the board release condition; keep TouchInfo diagnostic-only until a
validated presence bit is available. Add tests for invalid-report release and
sticky diagnostics.

- [ ] Step 1: Add failing invalid-report and diagnostic assertions.
- [ ] Step 2: Implement status wiring and timeout release.
- [ ] Step 3: Run the focused test and update the interface documentation.
- [ ] Step 4: Commit `Expose Loop diagnostics and release policy`.

### Task 11: Close FIFO/IP and full-build evidence

**Files:**
- Modify: `rtl/performance_event_fifo_wrapper.sv`
- Create or record: `ip/performance_event_fifo/*` or the approved RTL-only
  fallback decision in `docs/toolchain-verification-2026-10-16.md`
- Modify: `scripts/build.tcl`
- Modify: `README.md`

**Contract:** Select one verified implementation for the performance-event
FIFO. If no matching Gowin generated FIFO is available, keep
`USE_GOWIN_FIFO=0`, remove the misleading vendor mode, and document the
resource/synthesis decision. Run all RTL tests, full Gowin synthesis/P&R, and
record timing, resource counts, bitstream timestamp, and SHA256. Do not claim
hardware success without a physical board test.

- [ ] Step 1: Add a deterministic FIFO implementation-mode test.
- [ ] Step 2: Run all RTL regressions and record the output.
- [ ] Step 3: Run Gowin synthesis/P&R and capture reports.
- [ ] Step 4: Record bitstream hash and unchanged pin assignments.
- [ ] Step 5: Commit `Document final Loop build evidence`.

### Task 1: Define the event package and Gowin FIFO wrapper

**Files:**
- Create: `rtl/performance_event_pkg.sv`
- Create: `rtl/performance_event_fifo_wrapper.sv`
- Create: `ip/performance_event_fifo/performance_event_fifo.ipc`
- Create: `ip/performance_event_fifo/performance_event_fifo.v`
- Create: `sim/tb_performance_event_fifo.sv`
- Modify: `mgc3130_uart.gprj` to include the event package, wrapper, and generated FIFO wrapper

**Interfaces:**
- Produces the 64-bit event layout and constants defined in the spec.
- The project-owned wrapper exposes `clk`, `rst`, `flush`, `in_valid`, `in_ready`, `in_data[63:0]`, `out_valid`, `out_ready`, `out_data[63:0]`, `full`, `empty`, `overflow`, `underflow`, and `level`.
- The generated Gowin FIFO remains an implementation detail; no upper module uses its vendor-specific write/read enable names.

- [ ] Step 1: Generate a single-clock Gowin FIFO with 64-bit data and a fixed depth sufficient for the input/event path; record the exact generated parameters.
- [ ] Step 2: Write a testbench that pushes `NOTE_ON`, fills the FIFO, verifies `in_ready=0` and latched overflow, then drains it with backpressure and verifies ordering.
- [ ] Step 3: Implement the wrapper, including `flush` and sticky overflow/underflow flags outside the vendor IP. Permit simultaneous pop and push when both handshakes are true.
- [ ] Step 4: Run the focused simulation and verify ordering, flush behavior, backpressure, sticky flags, and simultaneous transfer using the generated FIFO model.
- [ ] Step 5: Commit with `git add rtl/performance_event_pkg.sv rtl/performance_event_fifo_wrapper.sv ip/performance_event_fifo sim/tb_performance_event_fifo.sv mgc3130_uart.gprj && git commit -m "Add performance event FIFO wrapper"`.

### Task 2: Add the fixed double-buffer Loop store around Gowin dual-port RAM

Implementation clarification (2026-10-16): use the project-owned
`rtl/loop_event_ram.sv` wrapper around actual GW5A `DPB` primitives, rather than
claiming GUI-generated `.ipc` files. Validate both official vendor simulation
and the matching RTL model. Detailed contract: `docs/loop-event-store-interface.md`.
The write/read ownership rules supersede the arbitrary `read_bank` draft below:
playback can only read active. Controls use a valid/ready opcode channel; prepare
record preserves other tracks. Empty recording abort is a mode-manager policy;
the store permits empty commits so CLEAR_ALL can take effect.

**Files:**
- Create: `rtl/loop_event_store.sv`
- Create: `rtl/loop_event_ram.sv`
- Create: `sim/tb_loop_event_store.sv`
- Create: `sim/tb_loop_event_ram.sv`
- Create: `scripts/test_loop_store.ps1`, `scripts/synth_loop_store.tcl`
- Modify: `mgc3130_uart.gprj`

**Interfaces:**
- Write channel: `write_valid`, `write_ready`, `write_track[1:0]`, `write_slot[3:0]`, `write_data[63:0]`.
- Control: `ctrl_valid/ctrl_ready`, `ctrl_op[2:0]`, `ctrl_track[1:0]`, `ctrl_done`, priority `abort`, and `loop_boundary`.
- Scheduler read: `read_enable`, `read_index[5:0]`, one-cycle `read_valid`, `read_slot_valid`, `read_data[63:0]`.
- Status: `active_bank`, `shadow_bank`, `commit_pending`, per-track `record_count`, per-track `overflow`, `commit_ack`.

- [x] Step 1: Configure and verify GW5A DPB primitives behind the wrapper, sized logically for two banks of four tracks with sixteen 64-bit event slots per track.
- [x] Step 2: Test writing shadow slots, rejecting writes when a track has 16 valid slots, clearing a track, and reading active bank without exposing shadow writes.
- [x] Step 3: Test `prepare_overdub` copies active bank to shadow bank and `commit_request` waits until `loop_boundary`.
- [x] Step 4: Implement `loop_event_store.sv` with per-track counts defining contiguous valid slots, copy/clear sequencing, and atomic bank swap at `loop_boundary`.
- [x] Step 5: Verify active-bank preservation after an aborted recording and verify `commit_ack` only follows a bank swap; ModelSim passes against both RAM models and standalone Gowin synthesis succeeds.
- [x] Step 6: Commit the wrapper, tests, project entry and interface/build documentation on `feat/loop-event-store`.

### Task 3: Implement deterministic tempo and Loop scheduler

Implementation clarification: current `loop_tick` advances at musical phase
deadlines, not scan completion. Three global 64-slot passes enforce event-type
priority; after a full tick127 interval, ALL_NOTES_OFF and LOOP_BOUNDARY must be
accepted before the store commit pulse and guard cycle. See
`docs/loop-scheduler-interface.md` for cancellation, retained PLAY, fault and tempo
quantization details. A deadline overrun faults instead of silently skipping ticks.

**Files:**
- Create: `rtl/loop_scheduler.sv`
- Create: `sim/tb_loop_scheduler.sv`
- Create: `sim/tb_loop_scheduler_store.sv`
- Create: `scripts/test_loop_scheduler.ps1`, `scripts/synth_loop_scheduler.tcl`
- Modify: `mgc3130_uart.gprj`

**Interfaces:**
- Configuration: `bpm_value[15:0]`, `run`, `stop`, `reset_position`, `flush`.
- Store read: `read_enable`, `read_index[5:0]`, `read_valid`, `read_slot_valid`, `read_data[63:0]`.
- Output: `event_valid`, `event_ready`, `event_data[63:0]`, `sixteenth_ce`, `loop_tick[6:0]`, `loop_boundary`, `stall`, `fault_valid`.

- [x] Step 1: Test BPM 60 and 180 against bounded tick intervals using a reduced clock parameter in simulation.
- [x] Step 2: Test all 64 slots, backpressure, full tick127 duration, boundary order, duration-generated Note-Off and cancellation/restart edges.
- [x] Step 3: Implement a 32-bit phase accumulator, configurable tempo step, sixteenth tick generation, 6-bit scan index, and fixed event comparison.
- [x] Step 4: Implement event priority and stable stalled output; add bounded RAM/deadline faults and held ALL_NOTES_OFF recovery.
- [x] Step 5: Validate real store integration with both RTL and official GW5A RAM, standalone synthesis, independent review; commit scheduler, tests, project and documentation on `feat/loop-event-store`.

### Task 4: Add the mode manager and command mailbox

2026-10-17 implementation contract and evidence:
`docs/loop-control-plane-interface.md`. Added `control_protocol_pkg`, independent
`performance_event_router`, and `loop_control_plane` wrapper. Scheduler boundary
permission prevents swapping before final record writes drain. ERROR mode encoding
is reserved: faults clean up into IDLE with sticky diagnostics. Board UART/sensor/
voice adapters remain Tasks 5–6. Six control tests plus six store/scheduler
regressions pass; isolated Gowin synthesis uses 1837 LUT, 127 ALU, 1053 FF,
four BSRAM and one DSP. This is not board integration or P&R validation.

**Files:**
- Create: `rtl/command_mailbox.sv`
- Create: `rtl/control_csr.sv`
- Create: `rtl/mode_manager.sv`
- Create: `sim/tb_mode_manager.sv`
- Modify: `mgc3130_uart.gprj`

**Interfaces:**
- Command mailbox: fixed binary frame parser input and one-entry `cmd_valid/cmd_ready`, `opcode`, `arg0`, `arg1`, `sequence`; response output with ACK status.
- Mode manager: input event FIFO, scheduler event FIFO, store controls, `mode`, `selected_track`, `bpm_shadow`, `run`, `record_enable`, `overdub_enable`, `all_notes_off`, `flush`.

- [x] Step 1: Test command acceptance, busy rejection, parameter rejection, and two-phase `ACK_ACCEPTED`/`ACK_APPLIED` behavior.
- [x] Step 2: Test legal transitions among `IDLE`, `LIVE`, `RECORD`, `OVERDUB`, `PLAY`, and fault cleanup to IDLE, including STOP priority.
- [x] Step 3: Implement a small project-owned CSR block for the approved register map; the UART parser writes CSR requests and reads status through the same interface.
- [x] Step 4: Implement the fixed binary parser, command mailbox, mode ownership, safe-boundary command commit, and event routing.
- [x] Step 5: Verify UART commands cannot directly modify active Loop storage or block the scheduler; bounded mailbox ingress limitations documented.
- [x] Step 6: Commit control modules, standalone wrapper, tests, project entries and interface/build documentation on `feat/loop-event-store`.

### Task 5: Adapt the existing input front end to standard events

2026-10-17 implementation evidence:
`mgc3130_reader` now exposes raw `touch_info[31:0]` and `touch_valid` using the
SDK's dynamic mask offsets; `mgc3130_input_latch` provides report/error/touch
valid pulses while preserving the legacy XYZ pulse. `input_event_adapter` emits
separate live, completed-record, and PLAY modulation valid/ready streams. It
uses Y C-major zones with confirmation, forward-only X retrigger high-water and
left re-arm, explicit presence input or invalid/timeout release, and bounded
overflow ALL_NOTES_OFF recovery. Raw TouchInfo is diagnostic-only because the
SDK has no general hand-presence bit. `tb_reader_touch`, `tb_input_event_adapter`
and the reader→latch→adapter pipeline pass; isolated Gowin synthesis is 512 LUT,
72 ALU, 224 FF, 2 DSP, no BSRAM. The sensor configuration itself is unchanged:
the board must emit mask bit 0x0004 from its stored GestIC configuration before
touch_valid can become active.

**Files:**
- Modify: `rtl/mgc3130_input_latch.sv`
- Modify: `rtl/mgc3130_pattern_input.sv`
- Modify: `rtl/mgc3130_reader.sv` to expose `touch_info` and `touch_valid` after enabling the required DataOutputConfigMask field
- Create: `rtl/input_event_adapter.sv`
- Create: `sim/tb_input_event_adapter.sv`

**Interfaces:**
- Consume existing valid XYZ reports and pattern-input decisions.
- Produce `performance_event_fifo` input; preserve existing thresholds and X/Y/Z mappings unless a test demonstrates a bug.

- [x] Step 1: Extend the reader parser and DataOutputConfigMask handling for `touch_info[31:0]` and `touch_valid`, while retaining dynamic message-size parsing.
- [x] Step 2: Replay injected MGC3130 reports and assert aligned report/error/touch pulses and stable standard event handshakes.
- [x] Step 3: Test invalid reports, timeout fallback, left-edge majority start, X hysteresis, Y confirmation, note changes, and explicit presence release.
- [x] Step 4: Implement the adapter and preserve the current legacy input path for comparison until Task 6 integration.
- [x] Step 5: Verify output stability under backpressure and explicit bounded overflow recovery.
- [x] Step 6: Add reader, latch, adapter, tests, synthesis script, and project entries on `feat/loop-event-store`.

### Task 6: Integrate the control plane without disturbing audio

2026-10-17 boundary implementation: added `input_event_mux`,
`performance_event_voice_bridge`, and `loop_audio_path`. Completed duration
events are marked storage-only and remain drainable after capture disables live
input; manager commit waits for adapter idle. ModelSim passes the input mux,
voice bridge, loop audio path, and control-plane RTL/Gowin-RAM tests. The board
top remains on its legacy path because it has UART TX only; physical UART RX/FIFO
and sensor-to-control instantiation are still required before replacing it.
The user confirmed the USB-UART RX pin as B3; `uart_rx` and its B3 constraint,
16-byte `uart_rx_fifo`, and `uart_control_link` are added and independently
verified. Full mailbox response serialization and board mode wiring remain open.

**Files:**
- Modify: `rtl/mgc3130_uart_top.sv`
- Modify: `mgc3130_uart.gprj`
- Create: `sim/tb_loop_control_integration.sv`

The integration must apply the frozen interaction defaults: BPM changes at the next Loop boundary, PLAY starts at tick 0, STOP clears the playback position while preserving active bank, and PLAY is rejected when no valid Loop exists.

**Interfaces:**
- Connect input adapter → input FIFO → mode manager → Loop store/scheduler → existing voice manager.
- Keep `sample_ce`, DDS, mixer, I²S, and optional audio UART as independent consumers.

- [x] Step 1: Run a synthetic LIVE/PLAY/STOP integration at the control-to-mixer boundary; full RECORD/OVERDUB board wiring remains gated on the RX path.
- [x] Step 2: Verify STOP and recovery close voices and preserve active bank in the control-plane regression.
- [ ] Step 3: Integrate physical UART RX, sensor adapter, and expose complete status/error fields through the board diagnostic path.
- [x] Step 4: Run focused simulations and `git diff --check`.
- [ ] Step 5: Commit final board integration after UART RX and PCM/I²S top-level wiring are complete.

### Task 7: Run synthesis and hardware-safe verification

**Files:**
- Modify: `README.md` with new command protocol, status fields, and recovery behavior.
- Modify: `scripts/build.tcl` only if new files require explicit project handling.

- [ ] Step 1: Run all RTL simulations with the available simulator and record pass/fail output.
- [ ] Step 2: Run the Gowin synthesis/P&R script and inspect LUT, FF, B-SRAM, timing, and swept-module reports.
- [ ] Step 3: Confirm generated FIFO and RAM IP models are included in synthesis and simulation, and that no vendor-specific ports leak beyond their wrappers.
- [ ] Step 4: Confirm UART diagnostic mode and PCM5102A pin assignments remain unchanged.
- [ ] Step 5: Record bitstream timestamp and SHA256; do not claim hardware success without a board test.
- [ ] Step 6: Commit documentation and build evidence with `git add README.md scripts/build.tcl && git commit -m "Document Loop control build and verification"`.

---
