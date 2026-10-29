# Stream A — voice metadata timing report

## Scope

This report covers the A workstream change on top of shared H0 commit
`5abe3909d8b0abefe845b0afd5d150e1d47a422a`. The shared H0 harness and all
Potts/resource files are unchanged.

## Structural change

Full-bank `NOTE_ON` victim selection no longer performs a 32-entry
`releasing`/`age`/`velocity` reduction in the event acceptance cone. The engine
now accepts the note into the existing one-entry mailbox, reads one metadata
row into registered `victim_scan_meta_*` signals per cycle, and compares that
registered row with a registered candidate. Released voices retain priority,
then oldest age, lowest velocity, and lowest voice ID break the tie. The
candidate is armed only after the scan drains; `event_ready` stays low during
the scan.

The scan is also an explicit sample boundary. A `sample_ce` pulse that arrives
while victim selection is active is held in `sample_pending` and starts the
playback scan after victim selection completes. This prevents the new metadata
latency from consuming a sample with a partially updated voice bank.

The full-bank victim scan takes 34 clock edges from mailbox acceptance to
`steal_pending` becoming active for the 32-voice configuration. This is an
internal event latency; the producer observes it through `event_ready`.

## Functional evidence

Before the RTL change, the new boundary assertion failed as intended:

```text
Fatal: victim selection armed without registered scan boundary
Time: 356 ns
```

After the change:

```text
scripts/test_v2_voice_engine_banked.ps1       PASS
scripts/test_v2_voice_banked.ps1              PASS (RAM=0 and RAM=1)
python -m unittest discover -s tools -p 'test_*.py'   175 tests, OK
git diff --check                              exit 0
```

The voice replay remained `rows=1827`, `samples=1784`, with 1-LSB tolerance
for both the portable and Gowin RAM models.

## Gowin evidence

The standalone voice probe was attempted in the fresh output directory
`impl/v2_voice_synth_banked_A_20261029_5abe390_b/`; `gw_sh` returned exit code
1 before producing synthesis or P&R reports. The shared full-path retry used
RunId `a_h0_20261029_5abe390`. Its verifier result is:

```text
V2_FULLPATH_VERIFY_STATUS=BLOCKED
wrapper status is COMMAND_FAILED, exit_code=1
missing synthesis log
missing P&R directory
missing P&R report
```

No current-source Fmax, setup/hold result, resource count, or routed artifact
is claimed for this A change. The historical pre-change voice timing numbers
remain diagnostic context only until a license-available fresh P&R can compare
the worst voice path.

## Acceptance status

Functional A evidence passes. Timing improvement and full-path acceptance are
pending a successful license-available standalone and shared-H0 synthesis/P&R.
