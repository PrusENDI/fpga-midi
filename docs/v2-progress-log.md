# V2 FPGA implementation progress log

This file records reproducible implementation checkpoints. Generated
`impl/`, ModelSim work libraries, transcripts and local captures remain outside
Git; source, tests, scripts and evidence summaries are committed.

## 2026-10-28 — pre-Task-8.5 checkpoint

The V2 contract is frozen for 32-slot/two-bank Loop storage, 16-bit voice-steal
diagnostics, N-tone selectors, wavetable selection fields and vibrato readback.
The Loop recorder/store/scheduler path has 32 slots per track, explicit DPB and
boundary timeout coverage. Potts now consumes the real recorder contour in the
top simulation; the measured busy interval is 1,868,573 simulation-domain
cycles for the current eight-event contour. The audio smoke slice covers the
fractional 48 kHz cadence and I2S framing.

The banked voice engine now provides 32 slots × two oscillators, a 256-bit
state-bank word, deterministic released/oldest/velocity/voice-ID stealing,
bounded eight-pass release, pending-note activation, revoice glide and UQ8.8
vibrato. The release path was corrected so the hold counter follows the
compute-stage slot and the envelope cannot wrap below zero.

Reproducible checks completed at this checkpoint:

```text
python -m unittest tools.test_v2_voice_vectors -v       # 8 passed
python -m unittest discover -s tools -p 'test_*.py'     # 174 passed
scripts/test_v2_voice_engine_banked.ps1                 # PASS
scripts/test_v2_voice_banked.ps1                        # PASS, 1827/1784, RAM=0/1
git diff --check                                      # PASS
```

The current-source Gowin voice P&R rerun exits before Tcl output with code 1;
the older 2026-10-26 routed artifact is therefore historical evidence only.
The next active work item is Task 8.5's independent N-tone test mode, followed
by the remaining Task 9–12 integration and full-path timing/board gates.

## Git checkpoint policy

Create a commit after each independently verified task or a material root-cause
fix. Commit messages should identify the task and validation command. Push a
checkpoint when the remote is available; if the environment blocks network or
the remote rejects the push, keep the local commit hash and record the reason in
this file and the validation report.
