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

**Files:**
- Create: `rtl/loop_event_store.sv`
- Create: `ip/loop_event_ram/loop_event_ram.ipc`
- Create: `ip/loop_event_ram/loop_event_ram.v`
- Create: `sim/tb_loop_event_store.sv`
- Modify: `mgc3130_uart.gprj`

**Interfaces:**
- Write channel: `write_valid`, `write_ready`, `write_track[1:0]`, `write_slot[3:0]`, `write_data[63:0]`.
- Control: `clear_track`, `clear_all`, `prepare_overdub`, `commit_request`.
- Scheduler read: `read_bank`, `read_index[5:0]`, `read_data[63:0]`.
- Status: `active_bank`, `shadow_bank`, `commit_pending`, per-track `record_count`, per-track `overflow`, `commit_ack`.

- [ ] Step 1: Generate a Gowin `RAM_DPB` configuration sized for two banks of four tracks with sixteen 64-bit event slots per track; keep the bank and slot mapping in the wrapper.
- [ ] Step 2: Test writing shadow slots, rejecting writes when a track has 16 valid slots, clearing a track, and reading active bank without exposing shadow writes.
- [ ] Step 3: Test `prepare_overdub` copies active bank to shadow bank and `commit_request` waits until `loop_boundary`.
- [ ] Step 4: Implement `loop_event_store.sv` around the generated RAM, including valid bits, per-track counters, copy/clear sequencing, and atomic bank swap at `loop_boundary`.
- [ ] Step 5: Verify active-bank preservation after an aborted recording and verify `commit_ack` only follows a bank swap.
- [ ] Step 6: Commit with `git add rtl/loop_event_store.sv ip/loop_event_ram sim/tb_loop_event_store.sv mgc3130_uart.gprj && git commit -m "Add double-buffered Loop RAM wrapper"`.

### Task 3: Implement deterministic tempo and Loop scheduler

**Files:**
- Create: `rtl/loop_scheduler.sv`
- Create: `sim/tb_loop_scheduler.sv`
- Modify: `mgc3130_uart.gprj`

**Interfaces:**
- Configuration: `bpm_value[15:0]`, `run`, `stop`, `reset_position`, `flush`.
- Store read: `read_index[5:0]`, `read_data[63:0]`.
- Output: `event_valid`, `event_ready`, `event_data[63:0]`, `sixteenth_ce`, `loop_tick[6:0]`, `loop_boundary`, `stall`, `fault_valid`.

- [ ] Step 1: Test BPM 60 and 180 against bounded tick intervals using a reduced clock parameter in simulation.
- [ ] Step 2: Test scanning all 64 slots, backpressure pause/resume, tick progression, and boundary Note-Off ordering.
- [ ] Step 3: Implement a 32-bit phase accumulator, configurable tempo step, sixteenth tick generation, 6-bit scan index, and fixed event comparison.
- [ ] Step 4: Implement priority `flush/all_notes_off > loop_boundary > NOTE_OFF > NOTE_ON > CONTROL_POINT` and hold scan state while `event_ready=0`.
- [ ] Step 5: Commit with `git add rtl/loop_scheduler.sv sim/tb_loop_scheduler.sv mgc3130_uart.gprj && git commit -m "Add deterministic Loop scheduler"`.

### Task 4: Add the mode manager and command mailbox

**Files:**
- Create: `rtl/command_mailbox.sv`
- Create: `rtl/control_csr.sv`
- Create: `rtl/mode_manager.sv`
- Create: `sim/tb_mode_manager.sv`
- Modify: `mgc3130_uart.gprj`

**Interfaces:**
- Command mailbox: fixed binary frame parser input and one-entry `cmd_valid/cmd_ready`, `opcode`, `arg0`, `arg1`, `sequence`; response output with ACK status.
- Mode manager: input event FIFO, scheduler event FIFO, store controls, `mode`, `selected_track`, `bpm_shadow`, `run`, `record_enable`, `overdub_enable`, `all_notes_off`, `flush`.

- [ ] Step 1: Test command acceptance, busy rejection, parameter rejection, and two-phase `ACK_ACCEPTED`/`ACK_APPLIED` behavior.
- [ ] Step 2: Test legal transitions among `IDLE`, `LIVE`, `RECORD`, `OVERDUB`, `PLAY`, and `ERROR`, including STOP priority.
- [ ] Step 3: Implement a small project-owned CSR block for the approved register map; the UART parser writes CSR requests and reads status through the same interface.
- [ ] Step 4: Implement the fixed binary parser, command mailbox, mode ownership, safe-boundary command commit, and event routing.
- [ ] Step 5: Verify UART commands cannot directly modify active Loop storage or block the scheduler.
- [ ] Step 6: Commit with `git add rtl/control_csr.sv rtl/command_mailbox.sv rtl/mode_manager.sv sim/tb_mode_manager.sv mgc3130_uart.gprj && git commit -m "Add Loop mode manager and command mailbox"`.

### Task 5: Adapt the existing input front end to standard events

**Files:**
- Modify: `rtl/mgc3130_input_latch.sv`
- Modify: `rtl/mgc3130_pattern_input.sv`
- Create: `rtl/input_event_adapter.sv`
- Create: `sim/tb_input_event_adapter.sv`

**Interfaces:**
- Consume existing valid XYZ reports and pattern-input decisions.
- Produce `performance_event_fifo` input; preserve existing thresholds and X/Y/Z mappings unless a test demonstrates a bug.

- [ ] Step 1: Replay existing MGC3130 reports and assert that valid reports produce ordered standard events without naked cross-module pulses.
- [ ] Step 2: Test invalid reports, timeout, left-edge start, right-edge stop, and note change behavior.
- [ ] Step 3: Implement the adapter and retain the current input logic behind it.
- [ ] Step 4: Verify no event is lost when the consumer holds `ready=0`.
- [ ] Step 5: Commit with `git add rtl/mgc3130_input_latch.sv rtl/mgc3130_pattern_input.sv rtl/input_event_adapter.sv sim/tb_input_event_adapter.sv && git commit -m "Adapt MGC3130 input to performance events"`.

### Task 6: Integrate the control plane without disturbing audio

**Files:**
- Modify: `rtl/mgc3130_uart_top.sv`
- Modify: `mgc3130_uart.gprj`
- Create: `sim/tb_loop_control_integration.sv`

**Interfaces:**
- Connect input adapter → input FIFO → mode manager → Loop store/scheduler → existing voice manager.
- Keep `sample_ce`, DDS, mixer, I²S, and optional audio UART as independent consumers.

- [ ] Step 1: Run the integration test with a synthetic event stream and verify LIVE, RECORD, PLAY, and OVERDUB behavior.
- [ ] Step 2: Verify STOP and recovery close all voices and preserve active bank.
- [ ] Step 3: Integrate the modules and expose status/error fields through the existing diagnostic path.
- [ ] Step 4: Run all focused simulations and `git diff --check`.
- [ ] Step 5: Commit with `git add rtl/mgc3130_uart_top.sv mgc3130_uart.gprj sim/tb_loop_control_integration.sv && git commit -m "Integrate fixed-resource Loop control plane"`.

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
