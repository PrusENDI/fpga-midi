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
`mgc3130_loop_control_path`, `uart_byte_serializer`, the parameterized
`mgc3130_uart_top`, and the fixed `mgc3130_uart_loop_top` wrapper compiles with
ModelSim. The focused top-level Loop test and serializer test pass. A full Gowin
V1.9.12.04 build completed on 2026-10-17 with the Loop wrapper as top and produced
`bitstream/mgc3130_uart_loop.fs`.

This is the existing top-level design with `AUDIO_STREAM=0`, `AUDIO_OUTPUT=1`
and GAO enabled. Audio UART being swept is expected in this configuration.
The event FIFO is integrated through the Loop path using the selected RTL
fallback: ordering, full/empty, sticky diagnostics and flush are covered by
simulation.
`USE_GOWIN_FIFO=1` remains intentionally unsupported because no generated
GW5A FIFO wrapper/model with the required 64-bit interface was validated;
the wrapper fails at elaboration instead of accepting an unverified vendor
implementation. Resource accounting therefore includes the RTL FIFO only
when a consumer instantiates it.
It does not verify a generated Gowin FIFO model, simultaneous transfer coverage,
sensor interaction or board audio output. No board programming or hardware
validation was performed in this run.

The Loop-enabled P&R result uses 4094/23040 logic, 2227/23280 registers,
31/56 BSRAM and 3/28 DSP resources. Setup and hold violated endpoints are both
zero; the smallest reported setup slack is 5.847 ns and hold slack is 0.184 ns. The generated bitstream
SHA256 is `419497779AAA3FF659738A59A36D43D170E1269CA12567834E6F6B7A431606D`.

The pending implementation plan still requires vendor FIFO/RAM integration,
expanded interface verification, Loop storage, scheduler and interaction logic.
Gowin reported that its license expires in 8 days at the time of this run.

## UART bring-up build — 2026-10-17

After the first hardware ACK timeout, the official Tang Primer UART example was
checked directly. It assigns `uart_rx` to **B3**, `uart_tx` to **C3**, and the
50 MHz clock to **E2**, using 115200 8N1. The current P&R report has the same
assignments and `impl/pnr/device.cfg` contains `set SSPI regular_io = true`.

The Loop top now sends one diagnostic line, `LOOP UART READY\r\n`, after the
2.25 s MGC reset/startup sequence. This is intentionally before the binary
mailbox output and is not an additional protocol frame. The full Gowin build
completed with the Loop wrapper as top; setup/hold violated endpoints remain
zero. The resulting file is `bitstream/mgc3130_uart_loop.fs`, 7,034,234 bytes,
SHA256 `919C781FDAFC4AFB017A7A98FB9057E5368FB1648F5A1105DF6095294B4536B3`.
The only synthesis warnings are the existing UART counter width warning, the
encrypted Gowin I²C IP delay/full-case warnings, and unused legacy paths swept
from the Loop top.

## Diagnostic CSR rebuild — 2026-10-17

The audio diagnostic CSR was extended with the live-event handshake and adapter
overflow flags. A fresh Gowin synthesis/P&R completed successfully; setup and
hold violated endpoints remain zero. The regenerated bitstream is
`bitstream/mgc3130_uart_loop.fs` (7,464,250 bytes), SHA256:

```text
AD7DF300A81CFDECE3F89B968A1FD83DBC65852413FB5A4992E9D94788589CB3

The subsequent LIVE adapter queue-boundary fix was rebuilt and produced
SHA256 `9F18A745AA9D7C0A363B5A0C954098961CB650D20B069E9DD99E212510AC32D6`.
```
