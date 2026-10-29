# Cursor parallel optimization phase (2026-10-29)

## Scope and workspaces

Base: `ec10de4623648e957c56db06e3fbe628ae763ec9`. All paths below are
relative to the repository root. Candidate RTL is `rtl/v2_cursor_filter_timed.sv`.

| Branch | Workspace | Change |
| --- | --- | --- |
| `work/v2-cursor-dsp` | `.worktrees/v2-cursor-dsp` | Share five signed32 variable multiplications across existing FSM states |
| `work/v2-cursor-resource` | `.worktrees/v2-cursor-resource` | Reuse one registered median sorter for X/Y/Z |
| `work/v2-cursor-combined` | `.worktrees/v2-cursor-combined` | Combine the two changes; preserve the independent branches |
| detached `ec10de4` | `.worktrees/v2-cursor-baseline` | Fresh clean matched-source full-path control |

The DSP and median implementers worked in separate worktrees. The combination
resolves one declaration-area merge conflict by retaining both the single
median sorter and the shared multiplier mux. No other integration worktree,
shared H0 harness, clock target, or board constraints are changed.

Exit evidence for this phase is actual timed simulation, independent full-path
resource/timing measurements, a combined-candidate check, and committed reports.
Timing closure at 100 MHz and board acceptance are separate gates.

## Simulation evidence

Run from the resource worktree at `3f62a8a`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_cursor_timed.ps1 -CandidateRef ec10de4 -ExpectSameLatency
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_cursor_timed.ps1 -CandidateRef cd381e9 -ExpectSameLatency
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_cursor_timed.ps1 -ExpectSampleWindowDifference
```

All exit 0. Fresh GUID directories/private ModelSim libraries and parsed commit
identities prevent stale-source reuse. The bench compares two real timed DUTs,
every completed frame's XYZ/controls/state/flags/sequence/timestamp, four
adjacent inputs, and a causal audio oracle at fractional 48 kHz sample enables.

| Candidate | Completed frames | Max isolated cycles, base/candidate | Max 4-frame burst cycles | Audio checks | Same-latency assertions | Publication-window differences |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline self | 983/983 | 127/127 | 296/296 | 1,938 | 983 | 0 |
| DSP sharing | 983/983 | 127/127 | 296/296 | 1,938 | 983 | 0 |
| Median sharing | 983/983 | 127/141 | 296/352 | 1,940 | disabled | 1, expected |
| Combined, `c9b95c4` | 983/983 | 127/141 | 296/352 | 1,940 | disabled | 1, expected |

Resource-worktree logs: `impl/cursor_timed_84e567a159b345849ba235b9cd7aefac`
(self), `impl/cursor_timed_03369de1362e4cdea0ae143539e44964` (DSP),
`impl/cursor_timed_a8d6602aa1cd4bd4b6469ac12669ef9c` (median).
Combined log: `impl/cursor_timed_8b864996ee0f43ddbdb77a48e5ccc614` in its own
worktree; RTL SHA256 `191A20A8B1EC2494E234573D4F9A32661716366867DC1489310D5B96BF8E21B1`.
Combined `scripts/test_v2_top.ps1` also exits 0, with evidence under
`impl/modelsim_v2_top`. `python -m unittest discover -s tools -p 'test_*.py'`
exits 0 with 175 tests OK in the combined worktree. A deliberate negative control
running both `-ExpectSameLatency` and `-ExpectSampleWindowDifference` correctly
fails at row 0 (baseline 16 cycles, candidate 30), with log
`impl/cursor_timed_d6ea4e23f372417e843b2da43d180f82`. This verifies that the
same-latency gate detects the known extra processing latency.

The median candidate adds exactly 14 processing cycles for valid frames. At
100 MHz this is 140 ns; an audio edge in that window can retain the preceding
complete snapshot for one extra sample. Four-frame drain remains far below
the 500,000-cycle interval of a 200 Hz producer. Arbitrary-rate FIFO losslessness
and absolute cycle-identical audio are not claimed.

### Open functional discrepancy

The original `tb_v2_cursor_replay` exercises scalar `v2_cursor_filter`, so its
976-row PASS does not prove the timed implementation. The new test observes
**893/976 baseline timed versus scalar golden differences**, starting at row 0
(timed Z=0, scalar Z=45592). Timed startup sorts zero-filled history, while the
scalar implementation uses its actual history count. Timed `ST_OUTPUT` also
uses the preceding frame's `speed_q` in velocity calculation. These existing
semantics need a separate contract decision and fix; this optimization preserves
the timed baseline rather than concealing or correcting that discrepancy.

Current regression bounds: four adjacent frames, default calibration reason
and degradation flags, no mid-processing reset. Full-depth FIFO, overflow,
enqueue/dequeue coincidences and wider signed extreme stress remain future tests.

## Synthesis and full-path timing

All full-path runs use the unchanged H0 command from the respective worktree:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path -LicenseServer '106.55.34.119:10559' -RunId <unique-id>
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_v2_fullpath_run.ps1 -RunDir impl/v2_top_fullpath_<unique-id> -Acceptance
```

Gowin V1.9.12.04, GW5A-LV25MG121NES, 50 MHz E2/5 input, generated 100 MHz
PLL clock, CPU/SSPI regular IO. H0 retains reader, RAM Loop, H32 Potts,
32-by-2 voice, reduced nonzero FX, serial N-tone test mode, UART/telemetry/I2S.
License-consuming runs are serialized with existing `gw_sh` processes.

| Run | Source | Logic | Registers | CLS / 11,520 | BSRAM | Physical DSP / 28 | Actual Fmax MHz | Setup count / TNS ns | Hold count |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
| `cursor_baseline_ec10de4_1` | clean `ec10de4` | 15,302 | 8,996 | 10,250 | 36 | 16 | 71.342 | 2,650 / -5,223.233 | 0 |
| `cursor_dsp_cd381e9_1` | clean `cd381e9` | 15,163 | 9,123 | 10,346 | 36 | 8 | 68.671 | 3,144 / -7,815.501 | 0 |
| `cursor_median_3f62a8a_1` | clean `3f62a8a` | 14,542 | 8,676 | 10,142 | 36 | 16 | 66.898 | 3,102 / -8,989.670 | 0 |
| `cursor_combined_b1ed70a_1` | clean `b1ed70a` | 14,431 | 8,804 | 10,148 | 36 | 8 | 66.536 | 3,265 / -7,987.394 | 0 |

All four manifests record empty dirty state, matching H0 file hashes and
wrapper exit 0. All four acceptance verifiers exit 1 / BLOCKED for setup
and Fmax. The clean control independently reproduces the historical dirty
`tm_serial_1` metrics; the table now uses the new clean run as its control.
The older `338435c`
run omits the serial test-mode cone and is unsuitable for these resource deltas.

Clean baseline full source is `ec10de4623648e957c56db06e3fbe628ae763ec9`,
with worst slack -4.017 ns, Fmax 71.342 MHz in text/HTML/verifier. Its diagnostic
bitstream SHA256 is
`25D1FE873A47B5FBC362A247D0809F1C1DD2D806E161BBD6A68A58900FCDF78B`.

DSP H0 manifest records full source `cd381e9e5e1e003764bff0805377740cd9904716`,
empty dirty state, wrapper exit 0. P&R creates a bitstream but acceptance exits
**1 / BLOCKED** for 3,144 setup violations and Fmax below 100 MHz. Raw timing
Fmax is 68.671 MHz (verifier rounds to 68.67); worst slack is -4.562 ns.
Touch NL0002 is accepted only because the synthesized Boolean cone survives.
E2 and both regular-IO settings are verified. The diagnostic bitstream hash is
`4B86CC0FC6012AB6FE7F7B028602E302828D686147CE998FEA3A3783C559077A`;
this is not an accepted board image.

DSP netlist attribution: the cursor has two MULT27X36 cells, one alpha
multiplier and `mul_product2_0_s`. Historical cursor had six; thus the five
variable multiplication cells become one. This is distinct from physical DSP
site accounting: whole-design DSP is eight, down from the historical sixteen.
The resource reduction does not establish improved full-path timing; the DSP
worst path remains Potts to voice state RAM.

Median H0 manifest records clean full source
`3f62a8a045d61bd3da938563727d6af3fae5494e`, wrapper exit 0. Acceptance verifier
exits 1 / BLOCKED for setup and Fmax. The raw `.tr` text reports 66.898 MHz;
HTML/verifier reports 66.897 MHz. Both are below 100 MHz. Worst slack is
-4.948 ns, with Potts to voice RAM as the worst path. The hierarchy report
attributes 1,895 registers, 593 ALU, 2,149 LUT and six multiplier cells to the
cursor. This confirms that the median candidate leaves variable multipliers
independent. E2/5, CPU/SSPI regular IO and touch-inline evidence are retained.
Its diagnostic bitstream SHA256 is
`2E97E19A20F76756435B41FF693750AC74A20EDBBEC4D65A079C1981C81F4CF4`.

Combined full source is `b1ed70a9f5908eaf9ed97ea81d7c9e56a618d1d9`, worst
slack -5.029 ns. Its cursor has 2,023 registers, 571 ALU, 2,106 LUT and two
MULT27X36 cells; the worst timing path is Potts control to voice RAM.
Diagnostic bitstream SHA256:
`36AA8223E2396F1C224A9B47336B28D35D0F471E8CAA4BDB429C3ED7F198BF18`.
See `docs/parallel/v2-cursor-combined-report-2026-10-29.md` in the combination
branch for the commands, simulation and complete H0 evidence record.

Median standalone synthesis (`scripts/synth_v2_cursor_timed_resource.tcl`)
compares immutable `ec10de4` against its candidate: logic 3,605 to 2,982
(-623), registers 2,343 to 2,025 (-318), BSRAM 5 to 5. See the candidate's
`docs/parallel/v2-cursor-resource-report-2026-10-29.md` for source hashes and
the two standalone output directories. These numbers are not full-path CLS
or timing evidence.

## Decision and next gate

| Candidate versus clean control | Logic delta | Register delta | CLS delta | DSP site delta | Fmax delta MHz |
| --- | ---: | ---: | ---: | ---: | ---: |
| DSP | -139 | +127 | +96 | -8 | -2.671 |
| Median | -760 | -320 | -108 | 0 | -4.444 |
| Combined | -871 | -192 | -102 | -8 | -4.806 |

Keep all three branches as resource alternatives; **do not merge them into
the timing lane in this phase**. This round validates resource reductions,
but no candidate improves full-path timing. The combined design halves DSP
usage and removes 871 logic units, while packed CLS improves by only 102 sites
and actual Fmax falls to 66.536 MHz. DSP sharing alone raises register and CLS
usage, so it is a tradeoff rather than a uniform resource improvement.

These are matched-source/profile, single-run comparisons. They do not isolate
every physical placement effect, and future integrated changes must be measured
again. The next timing work should address the observed Potts/voice critical
paths. Resolve the inherited timed/scalar semantic gap separately before
functional acceptance. Keep the 100 MHz constraint, setup/hold, I2S/output
constraints and outstanding board measurements as final acceptance gates.

Reproducible source, tests and candidate reports are pushed to
`work/v2-cursor-dsp`, `work/v2-cursor-resource` and `work/v2-cursor-combined`;
the root ledger/this phase record are retained on `feat/loop-event-store`.
Generated `impl/` artifacts remain local and ignored in each preserved worktree.
