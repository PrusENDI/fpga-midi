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

The candidate compiles with ModelSim without warnings. Existing cursor
regressions both pass:

* `tb_v2_cursor_replay PASS rows=976 adjacent=A/B`
* `tb_v2_cursor_filter PASS`

The replay benches exercise the scalar reference filter; the timed candidate
was additionally compiled and synthesized as top `v2_cursor_filter_timed`.
No full-path Gowin P&R was run, as requested.

## Risk and recommendation

The main risk is latency: the median section is serialized across three axes,
adding roughly 12 FSM cycles per accepted frame. At 200 Hz this is negligible
relative to the 500,000-cycle inter-report interval, but any future producer
rate increase should check FIFO occupancy. The queue and stable snapshot
boundaries are untouched, so frame ordering and audio `sample_ce` semantics are
preserved.

The standalone resource reduction is material (318 FF and 623 logic units),
and the candidate is recommended for mainline adoption. A full-path P&R should
be run by integration after merge to measure CLS/Fmax impact.
