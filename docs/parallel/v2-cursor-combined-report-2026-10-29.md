# Combined cursor resource candidate (2026-10-29)

Status: simulation verified on the recorded traces; full-path resource-legal;
100 MHz timing acceptance **BLOCKED**. Preserve this branch as a resource
alternative; it is not a timing-closure result.

Branch `work/v2-cursor-combined`, workspace `.worktrees/v2-cursor-combined`,
base `ec10de4623648e957c56db06e3fbe628ae763ec9`. Source for the completed H0
run is clean `b1ed70a9f5908eaf9ed97ea81d7c9e56a618d1d9`. Later report-only
commits do not change the measured RTL.

## Implementation and simulation

The candidate combines a shared signed32-by-signed32 variable multiplier with
one registered five-element median sorter reused across three axes. A single
merge conflict in the declaration area retained both changes. Independent
read-only review reconstructed the union of both patches and found the final
RTL identical after declaration placement/whitespace normalization. FIFO,
sequence/timestamp and audio publication boundaries are unchanged by merging.

From this worktree, `scripts/test_v2_cursor_timed.ps1
-ExpectSampleWindowDifference` exits 0: 983/983 frames, isolated max latency
127/141 cycles, four-frame burst 296/352, 1,940 causal audio checks, one expected
publication-window sample difference. Log directory:
`impl/cursor_timed_8b864996ee0f43ddbdb77a48e5ccc614`. RTL SHA256:
`191A20A8B1EC2494E234573D4F9A32661716366867DC1489310D5B96BF8E21B1`.

`scripts/test_v2_top.ps1` exits 0 (`impl/modelsim_v2_top`), and
`python -m unittest discover -s tools -p 'test_*.py'` exits 0 with 175 tests OK.
A deliberate negative control adding `-ExpectSameLatency` correctly fails on
row 0 (16/30 cycles), proving the added assertion detects the median latency.
Negative-control log: `impl/cursor_timed_d6ea4e23f372417e843b2da43d180f82`.

The 14 extra processing cycles can delay one audio snapshot by one sample if
publication crosses `sample_ce`. Outputs remain atomic. Four-frame bursts
drain within the 200 Hz input budget; arbitrary-rate FIFO losslessness is not
claimed. Baseline timed versus scalar golden still differs on 893/976 rows;
this inherited semantic gap is separate from candidate-versus-timed equality.
See the two independent candidate reports for the coverage boundaries.

## Full-path H0 evidence

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path -LicenseServer '106.55.34.119:10559' -RunId cursor_combined_b1ed70a_1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_v2_fullpath_run.ps1 -RunDir impl/v2_top_fullpath_cursor_combined_b1ed70a_1 -Acceptance
```

Gowin V1.9.12.04, GW5A-LV25MG121NES, unchanged H0 full-path profile with serial
N-tone mode, E2/5 50 MHz input, generated 100 MHz clock, CPU/SSPI regular IO.
Manifest records the clean source above and wrapper exit 0. Verifier exits
1 / BLOCKED for setup count and actual Fmax; touch NL0002 is accepted with
surviving netlist functional-cone evidence.

| Metric | Result |
| --- | ---: |
| Logic | 14,431 (12,166 LUT + 2,265 ALU) |
| Registers | 8,804 (8,799 logic FF + 5 IO FF) |
| CLS | 10,148/11,520 |
| BSRAM | 36/56 |
| Physical DSP sites | 8/28 |
| Actual Fmax | 66.536 MHz |
| Setup violations / TNS | 3,265 / -7,987.394 ns |
| Worst setup slack | -5.029 ns |
| Hold violations / TNS | 0 / 0 ns |

The cursor hierarchy attributes 2,023 registers, 571 ALU, 2,106 LUT and two
MULT27X36 cells. The whole-design DSP site count is a separate physical metric.
The worst timing path remains Potts control to voice state-bank RAM. Lower
cursor logic/DSP usage does not by itself close that path.

Evidence directory: `impl/v2_top_fullpath_cursor_combined_b1ed70a_1/`, containing
`harness-manifest.json`, `harness-verification.json`, synthesized netlist,
P&R resource and timing reports. Generated diagnostic bitstream SHA256:
`36AA8223E2396F1C224A9B47336B28D35D0F471E8CAA4BDB429C3ED7F198BF18`.
This identifies the artifact and does not mark it accepted for board use.

A fresh clean `ec10de4` full-path control completed in
`.worktrees/v2-cursor-baseline/impl/v2_top_fullpath_cursor_baseline_ec10de4_1`.
Its manifest source is `ec10de4623648e957c56db06e3fbe628ae763ec9`, dirty state
empty, wrapper exit 0 and verifier exit 1 / BLOCKED. It reports 15,302 logic,
8,996 registers, 10,250 CLS, 36 BSRAM, 16 DSP, actual Fmax 71.342 MHz, setup
2,650/TNS -5,223.233 ns, worst -4.017 ns and zero hold violations.

The combined candidate therefore saves 871 logic, 192 registers, 102 CLS and
eight DSP sites, but Fmax falls by 4.806 MHz. Preserve it as a resource
alternative and **do not merge it into the timing lane in this phase**. This
result does not improve 100 MHz timing; the measured Potts/voice critical paths
remain the next performance priority. Re-measure any future adoption against
the then-current integrated design. The inherited timed/scalar functional
discrepancy remains open before functional acceptance.

The complete comparison is retained in
[the cursor phase record](v2-cursor-optimization-2026-10-29.md). The older dirty
`tm_serial_1` run is historical context; the new clean run is the control.
