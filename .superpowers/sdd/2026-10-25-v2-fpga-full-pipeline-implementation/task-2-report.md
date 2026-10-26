# Task 2 report: V2 clock and sample scheduler

## Implemented

- `rtl/v2_clock_gen.sv`: 50 MHz input to GW5A `PLLA` primitive, configured for 100 MHz (`FCLKIN=50.0`, `IDIV_SEL=1`, `FBDIV_SEL=1`, `MDIV_SEL=20`, `ODIV0_SEL=10`). `V2_SIM` bypasses the PLL and forwards `clk_in`; `pll_locked` follows `rst_n` in that mode.
- `rtl/v2_sample_scheduler.sv`: one 100 MHz clock domain, 32-bit bounded phase accumulator, `48_000` increment versus `100_000_000` modulus, and registered one-cycle `sample_ce` with incrementing `sample_index`. No free-running audio clock is created.
- `sim/tb_v2_sample_scheduler.sv` and `scripts/test_v2_sample_scheduler.ps1`: ModelSim test covering 100,000,000 system-clock cycles (one second at 100 MHz), enable count, index, and interval distribution.
- `mgc3130_v2.sdc`: 50 MHz input and 100 MHz generated clock. The I2S BCLK is a synchronous output of this domain and is not an asynchronous clock group.
- `scripts/synth_v2_clock.tcl`: isolated GW5A synthesis project.

## Verification

The scheduler test was run fail-first before implementation and failed because `rtl/v2_sample_scheduler.sv` did not exist. After implementation:

```
tb_v2_sample_scheduler PASS ce=48000 interval_2083=32000 interval_2084=15999 index=48000
```

ModelSim used `C:\modeltech64_10.6d\win64`; simulation completed with zero errors. Both V2_SIM source compilation and hardware-branch source compilation with the installed GW5A `prim_sim.v` completed successfully. `git diff --check` completed without whitespace errors (only existing line-ending warnings on unrelated user files).

## Superseded initial synthesis attempt

`gw_sh.exe scripts/synth_v2_clock.tcl` reached Gowin synthesis parsing and mapping, then stopped with the tool/device diagnostic:

```
ERROR (RP0008) : There is no PLL resource in current device, please change device
```

The initial attempt used the wrong `PLL` primitive. Subsequent investigation found the GW5A's `PLLA` in the vendor `simlib/gw5a/prim_sim.v` and in the `ipcore/PLLD/data/PLLA` and `ipcore/PLL_ADV/data/PLLA` templates. The initial conclusion that the selected device lacks PLL resources was incorrect. The successful corrected run is recorded below.

## Review correction

The I2S transmitter's `bit_count` spans 0 through 63, so the interface clock is 48 kHz x 64 = 3.072 MHz. A prior revision added a 325.520833 ns virtual clock. The final correction removes that clock because I2S BCLK is generated synchronously from `clk_sys_100m` and should not be in an asynchronous clock group.

## Final clock closure correction

The Gowin PLLA model's internal feedback formula is `VCO = input / IDIV * FBDIV * MDIV`, then `CLKOUT0 = VCO / ODIV0`. The corrected parameters yield a 1 GHz VCO and 100 MHz output. The original `PLL`/8/4 settings were invalid for this GW5A device; the earlier BCLK virtual-clock constraint also cut synchronous paths and has been removed.

Hardware-branch ModelSim command (run from `impl/modelsim_v2_clock_hardware`): compile `rtl/v2_clock_gen.sv`, `sim/tb_v2_clock_gen.sv`, and `C:\Gowin\Gowin_V1.9.12.04_x64\IDE\simlib\gw5a\prim_sim.v` with `vlog -sv -work work`; simulate `work.tb_v2_clock_gen` with `vsim -c -onfinish stop -l clock.log -do 'run 200 us; quit -code 0 -f'`. Result: `tb_v2_clock_gen PASS lock/reset/relock and 10 ns period` at 102.590 us, zero errors. Four warnings are internal to the vendor PLLA simulation model (`vopt-13162`).

The scheduler was rerun with `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_sample_scheduler.ps1`: 48,000 enables in 100,000,000 system cycles, sample index 48,000, with 32,000 intervals of 2,083 cycles and 15,999 intervals of 2,084 cycles.

`C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe scripts/synth_v2_clock.tcl` successfully ran synthesis and P&R for a `v2_clock_sample_probe` harness that preserves both the PLL and scheduler. Reports are in `impl/v2_clock_synth/impl/gwsynthesis/v2_clock_syn.rpt.html` and `impl/v2_clock_synth/impl/pnr/v2_clock_tr_content.html`, with P&R resources in `impl/v2_clock_synth/impl/pnr/v2_clock.rpt.txt`. The routed report names `clk_50m` at 50.000 MHz and generated `clk_sys_100m` at 100.000 MHz, with post-route actual Fmax 175.843 MHz and setup/hold TNS 0.000. The device report shows PLLA usage 1/6. These timing numbers apply only to this clock+scheduler probe, not a complete V2 top-level design.

## Reset release closure and pending I/O constraints

The clock+scheduler probe now instantiates reusable `rtl/v2_reset_sync.sv`. External reset or PLL unlock asserts `rst_sys_n` asynchronously; two 100 MHz flip-flops release it on system-clock edges. The scheduler consumes `rst_sys_n` rather than raw `rst_n & pll_locked`. Task 12 must use this same policy in the final V2 top. The hardware-branch test first failed with `system reset did not synchronously release` against the raw-lock probe, then passed after the reset synchronizer was added. The final test also checks an injected independent PLL-lock drop and relock, edge-aligned two-cycle release, scheduler reset, PLL lock/reset/relock, and 10 ns output period. Command: from `impl/modelsim_v2_clock_hardware`, `vlog -sv -work work` with `rtl/v2_clock_gen.sv`, `rtl/v2_reset_sync.sv`, `rtl/v2_sample_scheduler.sv`, `sim/v2_clock_sample_probe.sv`, `sim/tb_v2_clock_gen.sv`, and the vendor GW5A `prim_sim.v`; then `vsim -c -onfinish stop -l clock.log work.tb_v2_clock_gen -do 'run 200 us; quit -code 0 -f'`. Result: `tb_v2_clock_gen PASS lock/reset/relock, 10 ns period, async assert/two-edge release` at 102.630 us, zero errors and four vendor-model warnings.

After the reset logic change, the scheduler script again passed 48,000 enables in 100,000,000 cycles. Re-running `C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe scripts/synth_v2_clock.tcl` completed synthesis and P&R for the PLLA+reset+scheduler probe. The final routed report records 50.000 MHz `clk_50m`, 100.000 MHz generated `clk_sys_100m`, 194.654 MHz post-route Fmax, setup and hold TNS 0.000, and PLLA usage 1/6. This is probe-only evidence.

The present V2 SDC constrains the real 50 MHz input and 100 MHz generated system clock. There is no V2 transmitter or BCLK output port yet, so no BCLK/output delay path can be constrained or verified in Task 2. Task 12 must add and verify synchronous I2S/BCLK output timing constraints once those ports exist, without asynchronous clock groups or false cuts. I2S I/O constraints remain an explicit open integration item.
