# LIVE XYZ Performance Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current LIVE gesture mapping with X-based note selection, Z-based hard note on/off and pressure, rate-based X/Y stability confirmation, and a soft X revoice path while leaving RECORD/OVERDUB timing and storage behavior unchanged.

**Architecture:** Add a dedicated LIVE XYZ mapper at the sensor/event boundary. The mapper emits low-rate discrete C-major target-note events through the existing LIVE FIFO and sends pressure as a coalescing latest-value stream. Add an explicit LIVE revoice event and a two-oscillator continuous-glide mixer path; Z note on/off remains a hard state transition, while pressure slew and X pitch changes are smoothed independently.

**Tech Stack:** SystemVerilog RTL, existing 50 MHz single-clock design, ModelSim SE-64 10.6d, existing Gowin project and PCM5102A I²S path.

**Spec:** This plan is the approved design for the LIVE-only redesign discussed in chat. The existing Loop control specification remains authoritative for RECORD, OVERDUB, PLAY, UART protocol, and event transport rules.

## Global Constraints

- Keep the baseline at Git commit `632a9c7 Separate Loop event ingress paths`.
- Do not execute `git reset` or `git clean`.
- Do not change the UART binary command format or ASCII debug UART.
- Do not generate, replace, or burn a production bitstream in this implementation pass.
- Keep all logic in the existing `clk` domain; use clock-enables and sample counters.
- LIVE-only gating must not alter RECORD/OVERDUB note capture, Loop ticks, or scheduler playback.
- Keep `performance_event_ingress` LIVE FIFO depth at 16 unless a new worst-case simulation proves overflow with the approved event rates.
- Use valid/ready for every new event boundary and preserve stable data while stalled.
- Every behavior change gets a focused failing simulation before production RTL is changed.

## Resulting LIVE behavior

The mapper uses the complete X range and does not use absolute Y for pitch:

| Input | LIVE behavior |
|---|---|
| X `0x0000–0xFFFF` | Eight equal zones, one C-major note per zone: C4, D4, E4, F4, G4, A4, B4, C5. |
| Y | Only contributes to the motion-rate stability test. |
| Z `<= 18432` (`0x4800`) | Pressed state. The current X zone is selected only after X/Y become stable. |
| Z `>= 20480` (`0x5000`) | Released state. A 2048-count buffer prevents chatter around the trigger edge. |
| Z below the press threshold | Pressure target increases as Z decreases; the target is coalesced and slewed in the mixer. |
| X zone changes while Z is pressed | After X/Y are stable for three reports, emit one soft `NOTE_REVOICE`; do not emit a hard NOTE_OFF/NOTE_ON pair. |

The current rate filter parameters are explicit RTL parameters: `XY_STABLE_DELTA=16'd512`, `XY_STABLE_FRAMES=3`, `Z_TOUCH_MIN=16'd4096`, `Z_ON=16'd18432`, and `Z_OFF=16'd20480`. They remain compile-time parameters until hardware measurements justify changing them.

## Complete LIVE data path after the change

```text
MGC3130 I2C reader
    -> mgc3130_input_latch
    -> raw report_valid/xyz_valid + X/Y/Z
    -> input_event_adapter mode mux
         ├─ MODE_LIVE: live_xyz_mapper
         │    ├─ NOTE_ON / NOTE_OFF / NOTE_REVOICE
         │    │       -> LIVE event FIFO (depth 16)
         │    └─ CONTROL_POINT pressure target
         │            -> latest-value modulation register
         └─ RECORD/OVERDUB: existing recorder path unchanged
              -> RECORD FIFO -> Loop RAM writer

LIVE FIFO + modulation latest-value channel
    -> performance_event_router
         priority: ALL_NOTES_OFF > scheduler > LIVE discrete event > modulation
    -> performance_event_voice_bridge
         NOTE_ON/OFF/ALL_NOTES_OFF or NOTE_REVOICE/CONTROL_POINT
    -> mgc3130_voice_mixer
         ├─ Z NOTE_ON/OFF: hard voice-state transition
         ├─ CONTROL_POINT: pressure target slew
         └─ NOTE_REVOICE: target DDS step slews continuously to the new note
    -> existing mixed_sample bus
    -> PCM5102A I²S transmitter
```

In pure LIVE mode the scheduler and RECORD FIFO are disabled by the existing mode manager. In OVERDUB, the scheduler and existing recording path retain their current priority and timing; the LIVE-only mapper is not used to change Loop tick semantics.

---

### Task 1: Add the failing LIVE mapper simulation

**Files:**
- Create: `rtl/live_xyz_mapper.sv`
- Create: `sim/tb_live_xyz_mapper.sv`
- Create: `scripts/test_live_xyz_mapper.ps1`

**Interfaces:**
- Consumes: `clk`, active-low `rst_n`, `enable`, `flush`, one-cycle `report_valid`, `xyz_valid`, `report_error`, `x_position`, `y_position`, `z_position`, `selected_track`, and valid/ready outputs for discrete events and modulation.
- Produces: 64-bit `live_event` values using `performance_event_pkg`, 64-bit `modulation_event` values using `EVENT_CONTROL_POINT`, `idle`, and sticky `overflow` for a blocked discrete-event output.

- [ ] **Step 1: Write the failing test**

  Add tests that assert: X zone 0 maps to note 48 and zone 7 maps to note 60; Y alone never changes the note; Z crossing down through `Z_ON` waits for three stable X/Y reports before `NOTE_ON`; Z crossing up through `Z_OFF` emits one `NOTE_OFF`; X zone movement while held emits `EVENT_NOTE_REVOICE` only after three stable reports; pressure values replace one another while modulation is stalled; and a flush clears all pending mapper state.

- [ ] **Step 2: Run the test to verify it fails**

  Run:

  ```powershell
  .\scripts\test_live_xyz_mapper.ps1
  ```

  Expected: compilation or assertions fail because `live_xyz_mapper.sv` does not yet exist.

- [ ] **Step 3: Implement the minimal mapper**

  Implement states `IDLE`, `WAIT_XY_STABLE`, and `PLAYING`. Compute `x_zone=x_position[15:13]`; compute unsigned `abs_dx` and `abs_dy`; count consecutive reports satisfying both delta limits; and generate only state-change events. Use a two-entry internal discrete-event holding queue with the existing LIVE safety policy: if a new event arrives while blocked, replace the pending contents with `ALL_NOTES_OFF` followed by the newest event and set sticky overflow. Keep pressure as one latest target register.

  Encode `EVENT_NOTE_REVOICE` as event type `3'd6`. Use `EVENT_VELOCITY_LSB` for the initial pressure/velocity and `EVENT_AMP_LSB` for the same 8-bit pressure target. Map pressure with:

  ```systemverilog
  pressure_target = (z_position >= Z_ON) ? 8'd0 :
                    (z_position <= Z_TOUCH_MIN) ? 8'd255 :
                    8'd255 - (((z_position - Z_TOUCH_MIN) * 8'd255) /
                               (Z_ON - Z_TOUCH_MIN));
  ```

- [ ] **Step 4: Run the focused test**

  Run the same command and require `tb_live_xyz_mapper PASS` with no ModelSim errors.

- [ ] **Step 5: Commit the focused unit**

  ```powershell
  git add rtl/live_xyz_mapper.sv sim/tb_live_xyz_mapper.sv scripts/test_live_xyz_mapper.ps1
  git commit -m "Add LIVE XYZ mapper state machine"
  ```

### Task 2: Route the new mapper only in MODE_LIVE

**Files:**
- Modify: `rtl/input_event_adapter.sv`
- Modify: `rtl/mgc3130_loop_control_path.sv`
- Modify: `sim/tb_input_event_adapter.sv`
- Modify: `scripts/test_input_adapter.ps1`

**Interfaces:**
- Consumes: the mapper interface from Task 1 and the existing raw MGC3130 report interface.
- Produces: the existing `live_valid/live_event`, `record_valid/record_event`, and `modulation_valid/modulation_event` ports, with no external protocol change.

- [ ] **Step 1: Extend the test before changing RTL**

  Add a regression sequence that enters `MODE_LIVE`, proves X controls the note, proves Y-only motion does not generate a note change, and then enters `MODE_RECORDING`/`MODE_OVERDUB` with the old recording assertions unchanged.

- [ ] **Step 2: Run the regression and observe the expected failure**

  ```powershell
  .\scripts\test_input_adapter.ps1
  ```

  Expected: the new X/Z assertions fail against the current Y/X/Z behavior.

- [ ] **Step 3: Add the mode mux**

  Instantiate `live_xyz_mapper` at the input boundary. Select mapper outputs only when `mode==MODE_LIVE`; select the existing adapter recording/live outputs for RECORDING, OVERDUB, and their armed/commit states. Clear mapper state on mode exit and on the existing adapter flush. Keep `record_start`, record duration, tick ownership, and completed-record tails untouched.

- [ ] **Step 4: Run both adapter and pipeline tests**

  ```powershell
  .\scripts\test_input_adapter.ps1
  .\scripts\test_input_pipeline.ps1
  ```

  Expected: all existing RECORD/OVERDUB tests pass and the new LIVE assertions pass.

- [ ] **Step 5: Commit the mode boundary**

  ```powershell
  git add rtl/input_event_adapter.sv rtl/mgc3130_loop_control_path.sv sim/tb_input_event_adapter.sv scripts/test_input_adapter.ps1
  git commit -m "Select dedicated XYZ mapper only in LIVE mode"
  ```

### Task 3: Connect modulation to the existing latest-value ingress

**Files:**
- Modify: `rtl/loop_control_plane.sv`
- Modify: `rtl/loop_audio_path.sv`
- Modify: `rtl/performance_event_ingress.sv` only if the focused test finds a same-cycle replacement bug
- Modify: `sim/tb_mode_gated_event_paths.sv`
- Modify: `sim/tb_loop_audio_path.sv`
- Modify: `scripts/test_mode_gated_event_paths.ps1`

**Interfaces:**
- Adds to `loop_control_plane`: `modulation_in_valid`, `modulation_in_ready`, `modulation_in_data`, `modulation_out_valid`, `modulation_out_ready`, and `modulation_out_data`.
- Keeps `loop_audio_path` external ports unchanged; it internally connects adapter modulation into the ingress coalescer and consumes the coalesced output at the final bridge.

- [ ] **Step 1: Add a failing coalescing integration assertion**

  Drive two pressure points while the mixer bridge is stalled. Assert that the second point replaces the first, that the LIVE FIFO level remains unchanged, and that the latest point is eventually delivered after the stall.

- [ ] **Step 2: Run the focused test and verify failure**

  ```powershell
  .\scripts\test_mode_gated_event_paths.ps1
  .\scripts\test_loop_audio_path.ps1
  ```

  Expected: the test fails because `loop_control_plane` currently hardwires `.modulation_in_valid(1'b0)` and bypasses the ingress modulation register.

- [ ] **Step 3: Wire the channel**

  Connect the adapter's pressure stream to `performance_event_ingress.modulation_in_*`; connect its `modulation_out_*` to the existing final bridge. Preserve the existing priority `ALL_NOTES_OFF > scheduler > LIVE event > modulation`. Do not change LIVE FIFO depth from 16.

- [ ] **Step 4: Run the focused tests**

  Require both scripts to report PASS and verify that `router_status` still reports LIVE and RECORD FIFO levels in bits 3:0 and 7:4.

- [ ] **Step 5: Commit the ingress connection**

  ```powershell
  git add rtl/loop_control_plane.sv rtl/loop_audio_path.sv sim/tb_mode_gated_event_paths.sv sim/tb_loop_audio_path.sv scripts/test_mode_gated_event_paths.ps1
  git commit -m "Route LIVE pressure through coalescing ingress"
  ```

### Task 4: Add explicit soft X revoice event support

**Files:**
- Modify: `rtl/performance_event_pkg.sv`
- Modify: `rtl/performance_event_router.sv`
- Modify: `rtl/performance_event_voice_bridge.sv`
- Modify: `sim/tb_performance_event_voice_bridge.sv`
- Modify: `scripts/test_voice_bridge.ps1`

**Interfaces:**
- Adds `EVENT_NOTE_REVOICE=3'd6`.
- Adds a one-cycle `note_revoice` output to `performance_event_voice_bridge`; existing `note_on`, `note_off`, and `expression_valid` behavior remains unchanged.

- [ ] **Step 1: Write the failing bridge test**

  Send an event with type `EVENT_NOTE_REVOICE`, note 55, and velocity 90. Assert that only `note_revoice` pulses and that `note_on`/`note_off` remain low. Assert that the router does not count this LIVE-only event as a RECORD storage event.

- [ ] **Step 2: Run and confirm failure**

  ```powershell
  .\scripts\test_voice_bridge.ps1
  ```

- [ ] **Step 3: Implement event decoding and record filtering**

  Add the package constant, decode it in the bridge, and exclude it from `recordable` in the router. Preserve all existing event field positions and UART-visible formats.

- [ ] **Step 4: Run bridge and router regressions**

  ```powershell
  .\scripts\test_voice_bridge.ps1
  .\scripts\test_router_timing.ps1
  ```

- [ ] **Step 5: Commit the event type**

  ```powershell
  git add rtl/performance_event_pkg.sv rtl/performance_event_router.sv rtl/performance_event_voice_bridge.sv sim/tb_performance_event_voice_bridge.sv scripts/test_voice_bridge.ps1
  git commit -m "Add explicit LIVE soft revoice event"
  ```

### Task 5: Implement pressure slew and continuous X pitch glide

**Files:**
- Modify: `rtl/mgc3130_voice_mixer.sv`
- Modify: `rtl/loop_audio_path.sv`
- Create or modify: `sim/tb_mgc3130_voice_mixer.sv`
- Create or modify: `scripts/test_voice_mixer.ps1`

**Interfaces:**
- Adds `note_revoice` to the mixer input.
- Keeps `active_voice_count[2:0]`, `mixed_sample`, and `sample_valid` ports unchanged.

- [ ] **Step 1: Write failing mixer tests**

  Assert that NOTE_ON starts two oscillator voices, NOTE_OFF clears active voices immediately, a CONTROL_POINT changes loudness gradually rather than in one sample, and NOTE_REVOICE keeps the same two voices active while changing the target pitch.

- [ ] **Step 2: Run and confirm failure**

  ```powershell
  .\scripts\test_voice_mixer.ps1
  ```

- [ ] **Step 3: Implement the minimum mixer state**

  Use two continuously running oscillators: a triangle main oscillator and a quieter, slightly detuned saw component for string-like brightness. Keep `note_on` and `note_off` hard for voice state, while attack/release and `expression_valid` pressure move by a sample-rate gain slew. For `note_revoice`, preserve phase and gain and slew the current DDS step toward the new C-major target step. Add a small fixed-rate vibrato and normalize the mixed output before the signed 16-bit limiter.

- [ ] **Step 4: Run the mixer and audio-path tests**

  ```powershell
  .\scripts\test_voice_mixer.ps1
  .\scripts\test_loop_audio_path.ps1
  ```

- [ ] **Step 5: Commit the mixer behavior**

  ```powershell
  git add rtl/mgc3130_voice_mixer.sv rtl/loop_audio_path.sv sim/tb_mgc3130_voice_mixer.sv scripts/test_voice_mixer.ps1
  git commit -m "Add smooth LIVE pressure and X revoice crossfade"
  ```

### Task 6: Prove FIFO sizing and preserve RECORD/OVERDUB behavior

**Files:**
- Create: `sim/tb_live_fifo_burst.sv`
- Create: `scripts/test_live_fifo_burst.ps1`
- Modify: `sim/tb_mgc3130_loop_control_path.sv` or the existing board-boundary test
- Modify: `docs/loop-audio-integration-interface.md`

**Interfaces:**
- Consumes the completed mapper, ingress, router, bridge, and mixer behavior from Tasks 1–5.
- Produces simulation evidence that LIVE FIFO depth 16 is sufficient for the approved event contract and that RECORD/OVERDUB remain on their existing path.

- [ ] **Step 1: Write the burst test**

  Generate one Z press, eight rapid X-zone changes, one Z release, and a stalled downstream for a bounded interval. Assert no FIFO overflow, ordered revoice events after stability confirmation, and latest-value pressure replacement without pressure FIFO growth.

- [ ] **Step 2: Run the test**

  ```powershell
  .\scripts\test_live_fifo_burst.ps1
  ```

  Expected: PASS with LIVE FIFO maximum level below 16 and no adapter/router overflow.

- [ ] **Step 3: Run the existing RECORD/OVERDUB regressions**

  ```powershell
  .\scripts\test_input_adapter.ps1
  .\scripts\test_control_plane.ps1
  .\scripts\test_router_timing.ps1
  .\scripts\test_top_loop.ps1
  ```

  Require the existing recording duration, Loop tick, scheduler, UART, and top-level assertions to remain green.

- [ ] **Step 4: Update the integration documentation**

  Document the new event type, pressure coalescing, Z thresholds, X/Y rate filter, and the fact that LIVE FIFO depth remains 16. Add the diagnostic interpretation for LIVE FIFO level and modulation pending.

- [ ] **Step 5: Commit the completed redesign**

  Before committing, run `git diff --stat`, `git diff --check`, and record every ModelSim command and PASS result. Then commit only the RTL, focused tests, scripts, and integration documentation listed in this plan.

## Verification and hardware boundary

The implementation is complete only after all focused ModelSim scripts and the existing control/top-level regressions pass. The production bitstream remains untouched. Hardware validation is a separate later step using COM4 diagnostics: verify `diag-input` counts, then `diag-audio` note-on/active-voice counts, then listen for hard Z on/off, smooth pressure, and smooth X revoice. Any threshold adjustment must be made as a parameter change followed by the mapper and mixer simulations; it must not be inferred from the simulation value `0x8000` alone.
