# Cursor resource candidate report (2026-10-29)

## Candidate

`v2_cursor_filter_timed` now reuses one registered 5-element odd-even median
network for X, Y, and Z. The FSM runs the same five compare/swap stages for
each axis in sequence, with `mx/my/mz` captured at the end of each pass. The
FIFO, `sample_ce` snapshot boundary, input report cadence, and all arithmetic
state ordering remain unchanged.

This removes the two parallel sorter register banks (10 x 32 bits) and their
parallel compare/swap logic. It adds two axis-pass transitions per frame;
200 Hz input has ample 100 MHz cycles and the audio domain still only consumes
the stable snapshot.

## Evidence

Standalone Gowin synthesis on GW5A-LV25MG121NES, using the same project shape
for baseline `ec10de4` and the candidate:

| metric | baseline | candidate |
|---|---:|---:|
| logic (LUT+ALU) | 3,605 (2,721+884) | 2,982 (2,346+636) |
| registers | 2,343 | 2,025 |
| BSRAM | 5 | 5 |
| DSP | unchanged by this candidate | unchanged |

Reproduced with Gowin V1.9.12.04 x64 (`C:/Gowin/Gowin_V1.9.12.04_x64/IDE/bin/gw_sh.exe`),
GW5A-LV25MG121NES, top `v2_cursor_filter_timed`, SystemVerilog 2017, standalone
synthesis only. The diagnostic Tcl is checked in:

```powershell
$gw='C:/Gowin/Gowin_V1.9.12.04_x64/IDE/bin/gw_sh.exe'
$env:GOWIN_CURSOR_REF='ec10de4'
& $gw scripts/synth_v2_cursor_timed_resource.tcl *> impl/cursor_resource_base.log
$env:GOWIN_CURSOR_REF=''
& $gw scripts/synth_v2_cursor_timed_resource.tcl *> impl/cursor_resource_candidate.log
```

Actual runs: `impl/cursor_resource_20261029_210619` (baseline) and
`impl/cursor_resource_20261029_210646` (candidate); each report is
`impl/gwsynthesis/cursor_syn.rpt.html` beneath its run directory. Console logs
are the two paths in the command above. No H0 harness was modified.

SHA256 of exact synthesis source files (baseline extraction gains Tcl's final
newline; this explains its different file hash from the replay extraction):

* baseline `ec10de4`, `selected.sv`: `5E9FF7885FE6FD0556F2FAF22AD435CD26A48801AB324F80B65751258AFE2BF2`
* candidate RTL `6fd9fe5`: `D4ACDE9AF90F0003DE8EBDA3AA9545D5B625CE4974D843CE1A73EAF80F09212C`

The candidate compiles with ModelSim without warnings. Existing cursor
regressions both pass:

* `tb_v2_cursor_replay PASS rows=976 adjacent=A/B`
* `tb_v2_cursor_filter PASS`

The replay benches exercise the scalar reference filter; the timed candidate
was additionally compiled and synthesized as top `v2_cursor_filter_timed`.
The initial standalone stage did not run full-path P&R. The later clean H0
result is recorded below.

### Actual timed differential replay

The new reproducible gate is `scripts/test_v2_cursor_timed.ps1`. It creates a
fresh GUID directory/private ModelSim work library per run, extracts immutable
baseline RTL with `git show ec10de4`, renames only baseline module names, and
compiles the candidate directly from its absolute workspace path. Its compile
log lists the actual paths, and it prints the candidate SHA256. No old RTL
copies or ModelSim library are reused.
The script rejects ModelSim error/fatal output and missing PASS, and the bench
has a fatal watchdog timeout. `-ExpectSampleWindowDifference` explicitly
requires the extra-latency boundary case; it is optional so other no-latency
cursor candidates can reuse the gate.

Commands from this worktree:

```powershell
./scripts/test_v2_cursor_timed.ps1 -CandidateRef ec10de4
./scripts/test_v2_cursor_timed.ps1 -ExpectSampleWindowDifference
```

Both DUTs are real timed filters. The bench reads all 976 existing vector rows
in order with identity-calibrated signed XY and unsigned Z, preserving invalid,
gap, saturation and left-edge flags. It checks each `frame_output_valid` result
(XYZ, pitch, velocity, depth, state, point, rebase, stable) exactly, plus FIFO
input sequence/timestamp against an accepted-frame scoreboard. It additionally
tests four consecutive input frames and three publication-boundary frames.
This is a filter-level replay, not a repeat of the latch/calibration transport
regression above.

`sample_ce` runs independently with a 48,000/100,000,000 fractional accumulator
(2083/2084 system cycles). Each DUT has its own causal audio oracle: sample
edges consume the preceding stable publication, including NBA ordering. Every
cycle checks the entire held audio XYZ/control/valid/sequence/timestamp bundle.
The publication-boundary case deliberately causes one audio sample to contain
the baseline's new snapshot and candidate's old snapshot; the oracle verifies
each is correct, rather than requiring cycle-identical audio timing.

| check | baseline vs itself | baseline vs candidate |
|---|---:|---:|
| completed frames | 983/983 | 983/983 |
| maximum isolated replay latency, cycles | 127/127 | 127/141 |
| maximum four-frame burst latency, cycles | 296/296 | 296/352 |
| independent audio snapshots checked | 1,938 | 1,940 |
| publication-window audio differences | 0 | 1 (expected) |
| baseline versus scalar golden differing rows | 893 | 893 |

Final ModelSim SE-64 10.6d logs are under
`impl/cursor_timed_b211c6c92b4847b3af44fef2e33914d2` (baseline self-check) and
`impl/cursor_timed_e47d470ee3e94c7cbd63fb6482c024c7` (candidate), each containing
`compile.log`, `replay.log`, and `console.log`.

### Strict latency gate and source identity follow-up

`-ExpectSameLatency` now passes `EXPECT_SAME_LATENCY=1` to the bench. It checks
each corresponding completed frame's measured acceptance-to-completion latency,
including FIFO waiting, and requires exactly 983 latency checks before PASS.
This is used for DSP sharing; median serialization deliberately omits it.
Script output and `source_identity.log` record resolved full baseline/candidate
commit SHAs. A current-file candidate is explicitly labeled `working tree`
with its HEAD and actual RTL SHA256, instead of mislabeling HEAD as the selected
candidate commit.

Verified commands and outputs:

```powershell
./scripts/test_v2_cursor_timed.ps1 -CandidateRef ec10de4 -ExpectSameLatency
./scripts/test_v2_cursor_timed.ps1 -CandidateRef cd381e9 -ExpectSameLatency
./scripts/test_v2_cursor_timed.ps1 -ExpectSampleWindowDifference
```

| candidate | frames | isolated cycles | burst cycles | latency assertions | sample window differences |
|---|---:|---:|---:|---:|---:|
| `ec10de4623648e957c56db06e3fbe628ae763ec9` | 983/983 | 127/127 | 296/296 | 983 | 0 |
| `cd381e9e5e1e003764bff0805377740cd9904716` | 983/983 | 127/127 | 296/296 | 983 | 0 |
| median working tree | 983/983 | 127/141 | 296/352 | disabled | 1 |

All passed. Logs respectively:
`impl/cursor_timed_84e567a159b345849ba235b9cd7aefac`,
`impl/cursor_timed_03369de1362e4cdea0ae143539e44964`,
`impl/cursor_timed_a8d6602aa1cd4bd4b6469ac12669ef9c`.
The baseline SHA is `ec10de4623648e957c56db06e3fbe628ae763ec9` in all runs.
The working-tree HEAD at invocation was `16e66860d47c57b7ee8b8c42201cc139cb85534e`;
median RTL SHA256 remained `D4ACDE9AF90F0003DE8EBDA3AA9545D5B625CE4974D843CE1A73EAF80F09212C`.
DSP extracted RTL SHA256 was `5FFF32D409BBFDD875D00ABA643A4E64E1B669D4174A6FD21F09DBFC00A8161A`.
This follow-up changes only test scripts/bench and this report; no RTL, H0
harness, or Gowin run was changed or started.

The last row is a pre-existing discrepancy, not relaxed DUT comparison:
baseline timed differs from the scalar vector golden beginning at row 0
(timed Z=0 versus scalar Z=45592). The timed startup sorts five values including
zero-initialized history, whereas the scalar uses actual startup history count.
This can change subsequent causal history; timed `speed_q` also uses its prior
frame value in the existing `ST_OUTPUT` velocity expression. This optimization
preserves all baseline timed results exactly and does not fix those separate
semantic issues. The scalar PASS above must not be interpreted as a timed
versus scalar equivalence claim.

### Static boundary review

Top-level telemetry takes `audio_cursor_{x,y,z}[15:0]` and `audio_sequence` at
`u_telemetry`, not the sorter or raw cursor signals. These are registers updated
only by `sample_ce` from the stable publication registers. The candidate keeps
both boundaries intact; no median combinational logic is added to the
cursor-to-telemetry path. The median compare/swap depth remains one compare
level per FSM stage; a 3-way source mux is added at sorter load. Actual CLS and
post-route results are now available from the clean candidate H0 run below.

### Clean median candidate H0 result

Integration ran H0 at clean source commit
`3f62a8a045d61bd3da938563727d6af3fae5494e`, run ID
`cursor_median_3f62a8a_1`, directory
`impl/v2_top_fullpath_cursor_median_3f62a8a_1`.
`harness-manifest.json` confirms empty dirty state and wrapper exit 0, using
Gowin V1.9.12.04 x64, device GW5A-LV25MG121NES, top
`v2_top_fullpath_probe`, reader/RAM/Potts/loop preservation enabled,
Potts horizon 32, FX enabled at level 1, SSPI/CPU GPIO reuse enabled.
The Acceptance verifier exited 1 with `BLOCKED`: the inlined touch decoder
was accepted, while 100 MHz setup timing remains unclosed.

| metric | clean median candidate |
|---|---:|
| logic | 14,542 (12,253 LUT + 2,289 ALU) |
| registers | 8,676 (8,671 logic FF + 5 IO) |
| CLS | 10,142 / 11,520 |
| BSRAM | 36 |
| DSP | 16 |
| Fmax in raw `.tr` | 66.898 MHz |
| Fmax in HTML / verifier | 66.897 MHz |
| setup violating endpoints | 3,102 |
| setup TNS | -8,989.670 ns |
| worst setup slack | -4.948 ns |
| hold violations | 0 |

The raw and HTML/verifier Fmax values are distinct report values, not treated
as identical. Worst timing remains Potts to voice RAM. Cursor hierarchy reports
1,895 REG, 593 ALU, 2,149 LUT, and 6 DSP cells. These are full-path hierarchy
figures and must not be confused with the earlier standalone-top totals.

Evidence paths beneath the run directory are `harness-manifest.json`,
`harness-verification.json`, `impl/pnr/v2_top_fullpath.rpt.txt`,
`impl/pnr/v2_top_fullpath.tr`, `impl/pnr/v2_top_fullpath_tr_content.html`,
`impl/pnr/device.cfg`, and `impl/pnr/v2_top_fullpath.fs`.
Diagnostic FS SHA256:
`2E97E19A20F76756435B41FF693750AC74A20EDBBEC4D65A079C1981C81F4CF4`.
It is not an accepted 100 MHz board artifact.

No clean integrated baseline delta is claimed here. The historical dirty
`tm_serial_1` run is unsuitable as a clean baseline; a clean `ec10de4` rerun
is queued separately. The combined candidate has passed review, 983-frame
timed checks, top regression and 175 Python tests; its P&R is in progress
in integration and is not evidence for this isolated median candidate.

## Risk and recommendation

The main risk is latency: the median section is serialized across three axes,
adding exactly 14 FSM cycles (140 ns at 100 MHz) per valid processed frame.
Bad-frame rejection bypasses the sorter. At 200 Hz this is negligible
relative to the 500,000-cycle inter-report interval, but any future producer
rate increase should check FIFO occupancy. The queue and stable snapshot
boundaries are untouched, so frame ordering and audio `sample_ce` semantics are
preserved, with stable publication 14 cycles later. A sample edge inside that
140 ns window holds the preceding snapshot for one more sample. The measured
141-cycle isolated latency and 352-cycle four-frame drain are both far below
the 500,000-cycle 200 Hz budget. Sustained burst service rate is lower, so this
does not claim arbitrary-rate FIFO losslessness.

The standalone resource reduction is material (318 FF and 623 logic units),
and the candidate remains a timed-behavior preserving resource optimization
for integration assessment. Existing timed/scalar differences remain separate
open issues. Its clean full-path H0 is still **100 MHz BLOCKED**; adoption as a
timing solution is not supported by the result. Compare only against the
pending clean integrated baseline and completed combined-candidate P&R before
drawing integrated resource or timing improvement conclusions.
