# Task 8.5 standalone test-mode synthesis evidence

This record covers the independent `v2_test_mode` probe. It is not evidence
for the final `mgc3130_v2_top` or for board-level CSR/I2S connectivity.

## Reproduction

From `mgc3130_uart`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_test_mode.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
  -TclScript (Resolve-Path scripts/synth_v2_test_mode.tcl).Path
```

The first command completed with `tb_v2_test_mode PASS`, followed by
`v2 N-tone spectrum PASS files=6` and `V2 N-tone test mode PASS`. It generated
4096-sample captures for N=1, 2, 4, 8, 16 and 32. The checker printed
`sideband_ratio=0.0000` for every capture; its current implementation sets
that field to zero and does not perform a third-party FFT or sideband search.
The 32-tone 4096-sample window has a 1 Hz bin error for the first two tones
and 0 Hz for the remaining tones. A true sideband/FFT acceptance check remains
open under Task 8.5.

The second command uses
`C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe` through the repository
wrapper and completed with `V2_TEST_MODE_SYNTH_PASS` (exit code 0). The probe top is
`v2_test_mode_synth_probe`; all test-mode outputs are top-level observables and
the instance has `keep_hierarchy` so synthesis cannot sweep the test mode.

Report:
`impl/v2_test_mode_synth_20261028/impl/gwsynthesis/v2_test_mode_syn.rpt.html`

| Resource | Usage | Device total / utilization |
| --- | ---: | ---: |
| Logic | 10036 (9254 LUT + 782 ALU) | 23040 / 44% |
| LUT (resource usage summary) | 9252 | report breakdown below |
| Register | 1060 DFFRE | 23280 / 5% |
| Latch | 0 | 0% |
| BSRAM | 0 | 56 / 0% |
| I/O buffer | 158 | probe-only |

The synthesis log records `Extracting RAM for identifier 'phase'`, but the
mapped report has BSRAM=0; the current array implementation therefore maps to
logic for this probe. The report's resource-usage table contains the LUT
breakdown (LUT2=413, LUT3=1048, LUT4=7791, summing to LUT=9252), while its
utilization table reports 9254 LUT inside the 10036 logic total. Both values
are preserved here verbatim; ALU=782 and INV=2 are also reported.

The synthesis timing section records a 100.000 MHz constraint and a
12.337 MHz **synthesis-estimated** Fmax at 114 logic levels. This is not a
routed timing result and is not used as a Task 8.5 acceptance claim.

## P&R scope

An initial probe script included `run pnr`. Gowin rejected that probe before
placement with `PA2112`/`PA2024`: the full observable interface has 158 ports,
while `GW5A-LV25MG121NES` provides 68 regular I/Os plus one RECONFIG_N. The
script is intentionally synthesis-only so the reproducible Task 8.5 command
returns success and the resource report is not confused with a board P&R
claim. A final-top P&R/board result still requires the test-mode CSR and audio
outputs to be integrated into a legal package-pin design.

\n