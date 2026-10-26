# Task 2 report: V2 clock and sample scheduler

## Implemented

- `rtl/v2_clock_gen.sv`: 50 MHz input to GW5A `PLL` primitive, configured for 100 MHz (`FCLKIN=50.0`, `FBDIV_SEL=8`, `ODIV0_SEL=4`). `V2_SIM` bypasses the PLL and forwards `clk_in`; `pll_locked` follows `rst_n` in that mode.
- `rtl/v2_sample_scheduler.sv`: one 100 MHz clock domain, 32-bit bounded phase accumulator, `48_000` increment versus `100_000_000` modulus, and registered one-cycle `sample_ce` with incrementing `sample_index`. No free-running audio clock is created.
- `sim/tb_v2_sample_scheduler.sv` and `scripts/test_v2_sample_scheduler.ps1`: ModelSim test covering 100,000,000 system-clock cycles (one second at 100 MHz), enable count, index, and interval distribution.
- `mgc3130_v2.sdc`: 50 MHz input, 100 MHz generated clock, and 768 kHz I2S BCLK virtual-clock constraint.
- `scripts/synth_v2_clock.tcl`: isolated GW5A synthesis project.

## Verification

The scheduler test was run fail-first before implementation and failed because `rtl/v2_sample_scheduler.sv` did not exist. After implementation:

```
tb_v2_sample_scheduler PASS ce=48000 interval_2083=32000 interval_2084=15999 index=48000
```

ModelSim used `C:\modeltech64_10.6d\win64`; simulation completed with zero errors. Both V2_SIM source compilation and hardware-branch source compilation with the installed GW5A `prim_sim.v` completed successfully. `git diff --check` completed without whitespace errors (only existing line-ending warnings on unrelated user files).

## Synthesis limitation

`gw_sh.exe scripts/synth_v2_clock.tcl` reached Gowin synthesis parsing and mapping, then stopped with the tool/device diagnostic:

```
ERROR (RP0008) : There is no PLL resource in current device, please change device
```

The project device is the repository's existing `GW5A-25A / GW5A-LV25MG121NES` declaration. Therefore no PLL lock, Fmax, or post-route timing result is claimed; the installed Gowin database reports no PLL resource for this selected device/package. P&R was not run after this synthesis stop.

## Review correction

The I2S transmitter's `bit_count` spans 0 through 63, so the interface clock is 48 kHz x 64 = 3.072 MHz. `mgc3130_v2.sdc` now constrains `i2s_bclk` at 325.520833 ns with a 162.760417 ns high time.
