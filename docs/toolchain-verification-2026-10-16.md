# Toolchain verification — 2026-10-16

## Reproduce

Run from the project directory in PowerShell:

```powershell
& 'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe' 'scripts\build.tcl'
& .\scripts\test_modelsim.ps1 -ModelSimBin 'C:\modeltech64_10.6d\win64'
```

In this Codex session, `gw_sh` exited with code 1 and no output inside the sandbox,
including a minimal `puts` script. The same executable and minimal script worked
outside the sandbox (exit 0). Full builds also required this approved environment.
No special `-tcl` or `-f` argument is needed.

Gowin V1.9.12.04 Tcl accepts `set_option -verilog_std sysv2017`.
The old `v2001` mode rejects `performance_event_pkg`; `sysv` is not a valid value
for this Tcl option. The internal UART counter `sequence` was renamed to
`frame_sequence` because it is a SystemVerilog keyword. Protocols are unchanged.

## Observed results

- Gowin full build: exit 0; synthesis, placement, routing and bitstream generation completed.
- P&R report time: 2026-10-16 23:32:13, local time (Asia/Shanghai).
- Device: GW5A-LV25MG121NES.
- Logic: 3461/23040; registers: 2080/23280; BSRAM: 28/56; DSP: 3/28.
- Existing 50 MHz clock: reported Fmax 63.928 MHz.
- Reported setup and hold violated endpoints: both 0, under current constraints.
- ModelSim SE-64 10.6d: package, FIFO and UART sources compile with `vlog -sv`;
  FIFO test prints `tb_performance_event_fifo PASS` at 130 ns, with 0 simulation errors.
- Simulation script checks exit status, errors and the PASS marker, and bounds
  simulated runtime to 1 ms. Output is isolated under `impl/modelsim_fifo/`.

Generated bitstream: `impl/pnr/ao_0.fs`, 7,034,202 bytes.

SHA256:

```text
877DAC57F6A1B551497FD7EA1E72CD1B6DE04028634D3C213E0F3C58DBA0C49E
```

Build output: `impl/toolchain_build.log`.
Timing/resource reports: `impl/pnr/mgc3130_uart.tr` and `mgc3130_uart.rpt.txt`.

## Scope and remaining work

After the gap-closure changes, the complete top-level RTL source list including
`mgc3130_loop_control_path`, `uart_byte_serializer`, and the parameterized
`mgc3130_uart_top` compiles with ModelSim. The focused top-level Loop test and
serializer test pass. A new `gw_sh scripts/build.tcl` attempt in this session
returned exit code 1 with an empty stdout/stderr capture, so no new Loop-enabled
P&R or bitstream evidence is claimed here; the resource/timing numbers above
remain evidence for the previously built legacy top.

This is the existing top-level design with `AUDIO_STREAM=0`, `AUDIO_OUTPUT=1`
and GAO enabled. Audio UART being swept is expected in this configuration.
The event FIFO is not yet integrated into the top level. Its simulation covers
the selected RTL fallback: ordering, full/empty, sticky diagnostics and flush.
`USE_GOWIN_FIFO=1` remains intentionally unsupported because no generated
GW5A FIFO wrapper/model with the required 64-bit interface was validated;
the wrapper fails at elaboration instead of accepting an unverified vendor
implementation. Resource accounting therefore includes the RTL FIFO only
when a consumer instantiates it.
It does not verify a generated Gowin FIFO model, simultaneous transfer coverage,
four-track Loop functionality, sensor interaction or board audio output.
No board programming or hardware validation was performed in this run.

The pending implementation plan still requires vendor FIFO/RAM integration,
expanded interface verification, Loop storage, scheduler and interaction logic.
Gowin reported that its license expires in 8 days at the time of this run.
