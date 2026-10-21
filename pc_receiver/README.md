# MGC3130 PC receiver

`mgc3130_receiver.exe` is a native Win32 console bridge around the installed Microchip GestIC SDK. It opens the supported MGC3130 USB-I²C bridge through `gestic_open()`, configures position, gesture and touch output, and emits one JSON object per line for each decoded position report.

The Capture & Loop wrapper buffers those real-time reports and runs the fixed three-dimensional Lead compiler only after the take ends. It does not implement LIVE note triggering.

The SDK installation is 32-bit, so this project intentionally targets `Win32`. The current Python interpreter is 64-bit and must not load `gestic.dll` directly. The JSONL stream is the stable boundary for the later Ambient analyzer and audio synthesizer.

## Build

From a Visual Studio Developer PowerShell:

```powershell
msbuild pc_receiver\mgc3130_receiver.vcxproj /p:Configuration=Static-Release /p:Platform=Win32
```

If the SDK is installed elsewhere, override `GESTIC_SDK_API_PATH` with the directory containing `include\` and `lib-static\`.

## Run

```powershell
pc_receiver\Static-Release\mgc3130_receiver.exe --seconds 30 `
  --output capture.jsonl
```

或者直接使用：

```powershell
.\pc_receiver\run_receiver.ps1 -Seconds 30 -Output capture.jsonl
```

The receiver writes the same JSONL to stdout and to `--output`. Use `--format csv` when a spreadsheet or the existing offline analyzer needs CSV. With no `--seconds`, it runs until interrupted.

Each position record contains `timestamp_ms`, a monotonic frame number, raw SDK coordinates (`x`, `y`, `z` in `0..65535`), and decoded `gesture`, `gesture_flags`, `touch_flags`, and `tap_flags`. It does not generate audio and does not modify the MGC3130 library image.

## Downstream contract

The sensor receiver remains responsible only for SDK connection and decoded reports. The PC compiler consumes the saved JSONL, preserves timestamp order, projects XYZ through the fixed calibration profile, extracts MOVE/HOLD/TURN/APEX/VALLEY/REST landmarks, and emits a deterministic six-track EventTable. Lead uses the fixed A-minor-pentatonic G3–C5 PitchSpace; Bass, Pad, Arp, Drums, and Texture/FX remain independent Touch/Tap recordings.

## Capture & Loop

Capture until Ctrl+C:

```powershell
python .\pc_receiver\capture_loop.py `
  --raw-output capture.jsonl `
  --event-output ambient_events.json
```

Or capture a fixed duration:

```powershell
.\pc_receiver\run_capture_loop.ps1 `
  -Seconds 30 `
  -RawOutput capture.jsonl `
  -EventOutput ambient_events.json
```

The raw JSONL is kept for replay. For the sections 13–14 acceptance path, compile it with the fixed-space Lead pipeline:

```powershell
python ..\tools\synthwave_loop.py capture.jsonl `
  --events synthwave_events.json `
  --wav synthwave_loop.wav
```

This performs deterministic 5-frame median/Hampel filtering, timestamp-based 128-tick resampling, MOVE/HOLD/TURN/APEX/VALLEY/REST landmark extraction, fixed A-minor-pentatonic G3–C5 quantization with hysteresis, and Neon Ambient Lead rendering. A short take is reported as `insufficient_capture` instead of receiving unrelated generated notes. The original `capture_loop.py` remains available for compatibility with earlier Ambient experiments.

For a quick offline handoff, save the receiver output and run:

```powershell
python ..\tools\ambient_analyzer.py capture.jsonl --output ambient_events.json
```

The executable returns `3` when no supported Microchip USB-I²C bridge is present, and `4` when the device opens but stream configuration fails. A successful compile proves the SDK ABI and link boundary; sensor reception still requires the bridge, MGC3130, configured GestIC library, and the actual electrode hardware.
