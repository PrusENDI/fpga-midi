# SDD ledger — plan: docs/superpowers/plans/2026-10-25-v2-fpga-full-pipeline-implementation.md

## Setup

- BASE before Task 1 dispatch: 6bd5597 (`docs: add v2 fpga full pipeline implementation plan`).
- Working tree was already dirty before this plan. Preserved without edits: `docs/mgc3130-coordinate-calibration-spec.md`, `docs/mgc3130-z-coupling-clutch-rebase-realtime-design-2026-10-22.md`, `docs/投稿的文档.pdf`.
- No AGENTS.md was found under the repository parent.
- The plan names `docs/v2-fpga-contract-2026-10-25.md` as a spec, but it does not exist at setup. Ruling: Task 1 creates that contract; until then the listed system/synth/voice/audit documents plus the plan are provisional authority. Cost if wrong: contract details may need a documented correction before later RTL is accepted.
- Current RTL fact: legacy `rtl/control_protocol_pkg.sv` defines 64-bit performance events and legacy CSR addresses through `0x44`; `rtl/loop_event_store.sv` and `rtl/loop_scheduler.sv` are four-track/64-bit V1-style paths. No V2 package, clock generator, scheduler, UART link, or top exists.

## Plan conflict scan

| Scope | Producer / consumer | Finding | Ruling |
|---|---|---|---|
| Task 1 ↔ Task 2 | V2 contract ↔ clock/scheduler | Task 2 consumes the frozen sample_ce/clock semantics but has no conflicting packet fields. | Task 1 freezes only names and clock claims needed by later tasks; Task 2 owns implementation evidence. |
| Task 1 ↔ Task 3 | `v2_contract_pkg.sv` input/event types ↔ calibration/validity | Task 3 adds input-frame semantics absent from Task 1's listed public event fields. | Task 3 may add internal/public input-frame types only if it does not alter `v2_event_t`, CSR ranges, or UART sizes. |
| Task 1 ↔ Task 4 | contract Z/pitch semantics ↔ cursor clutch | Pure-Z invariant and signed pitch fields must agree. | Contract records Z as control-only and Task 4 must preserve pitch on pure-Z vectors. |
| Task 1 ↔ Task 5 | event layout/modes ↔ LIVE/LOOP FSMs | Legacy event package is 64-bit and four-track; plan mandates 96-bit/six-track V2. | New V2 package is authoritative; V1 package/top remains untouched. |
| Task 1 ↔ Task 6 | 96-bit event/track count ↔ six-track store/scheduler | Task 6 must not reuse V1 96-slot/64-bit assumptions. | V2 wrapper uses 6×16 slots, 96-bit event, 128 ticks; docs explicitly separate V1. |
| Task 1 ↔ Task 7 | event list ↔ Potts lead output | Potts output must be V2 event-compatible and leave rest/gap semantics explicit. | Potts may use internal state widths but emits only contract events. |
| Task 1 ↔ Task 8 | NOTE events/voice telemetry ↔ 32-slot engine | Voice engine depends on event type and telemetry bitmap width. | Use contract event types and 32-bit active bitmap; no alternate event serialization. |
| Task 1 ↔ Task 9 | patch/wavetable/FX fields ↔ contract address/ACK | Task 9 updates contract only for concrete tested mismatches. | Task 9 may append tested Q-format/clamp/FX-level semantics; addresses and frame sizes stay frozen. |
| Task 1 ↔ Task 10 | UART/CSR/telemetry ↔ parser/snapshot | Task 10 must consume the exact 11-byte control and 22-byte telemetry formats. | No second parser/layout; any mismatch requires contract update with test evidence. |
| Task 1 ↔ Task 11 | Python protocol ↔ UI model | UI must call Task 1 serializers and never send EventTable/PCM. | Model imports/duplicates no conflicting constants; offline reference remains offline. |
| Task 1 ↔ Task 12 | top ↔ every public contract | Top is the sole integration point and must instantiate one V2 UART RX. | Top uses only V2 package/interfaces and leaves V1 top untouched. |
| Task 2 ↔ Task 8 | sample_ce ↔ voice cycle budget | Voice timing claims require verified 100 MHz/48 kHz scheduler. | Task 8 cannot claim 32 voices until Task 2 synthesis/sim evidence exists. |
| Task 2 ↔ Task 10 | 100 MHz UART/audio concurrency | UART backpressure must not gate sample_ce. | Independent queues and assertions required. |
| Task 2 ↔ Task 12 | clock generator/scheduler ↔ top constraints | Top must use PLL output as 100 MHz and sample_ce as only audio enable. | No second free-running audio clock; SDC names are explicit. |
| Task 3 ↔ Task 4 | calibrated frame ↔ filter/clutch | Invalid/gap/saturated semantics feed cursor state. | Task 4 consumes validity outputs and cannot create pitch on invalid frames. |
| Task 3 ↔ Task 5 | validity ↔ event FSMs | Invalid frames must not create note events. | Rule engines gate on frame_valid/degraded policy from Task 3. |
| Task 3 ↔ Task 12 | input chain ↔ top | Top order is fixed by plan. | Keep input latch compatible with V1 while adding V2 outputs only. |
| Task 4 ↔ Task 5 | cursor output ↔ LIVE/LOOP rules | REBASED must not be interpreted as TURN/APEX/pitch event. | Rule engines consume explicit state and pure-Z invariant. |
| Task 4 ↔ Task 12 | filter ↔ top | Audio domain consumes latest stable point without changing timestamps/ticks. | CDC/queue boundary remains visible in top. |
| Task 5 ↔ Task 6 | recorder FIFO ↔ store/scheduler | LIVE FIFO and LOOP write FIFO must remain independent; six tracks. | Task 6 integrates through V2 wrapper only; V1 recorder/store untouched. |
| Task 5 ↔ Task 7 | loop events ↔ Potts input | Potts sees frozen 128-tick lead contour after record boundary. | Potts is COMMIT-only and cannot block LIVE/sample_ce. |
| Task 5 ↔ Task 12 | two FSMs ↔ top modes | LIVE and LOOP are independent state machines. | Top exposes separate status/faults and does not collapse them into one implicit mode. |
| Task 6 ↔ Task 7 | bank swap boundary ↔ Potts completion | Potts completion must precede bank publication and respect boundary. | COMMIT freezes/drains, then swaps atomically; no mid-tick publication. |
| Task 6 ↔ Task 10 | store control ↔ UART commands/ACK | Accepted/busy/done/fault must map to ACK semantics. | UART only enqueues commands; store owns transaction state. |
| Task 6 ↔ Task 12 | loop store/scheduler ↔ top | Top must not use old four-track/96-slot scan. | V2 loop modules are separate names and instances. |
| Task 7 ↔ Task 12 | Potts budget ↔ boundary policy | 41 µs is a target estimate, not evidence. | Task 7 must measure worst-case cycles; Task 12 reports only measured values. |
| Task 8 ↔ Task 9 | voice patch/table ↔ FX | Patch updates must be shadowed and atomic; FX cannot alter pitch/timing. | Task 9 interfaces to voice engine through bounded controls only. |
| Task 8 ↔ Task 12 | voice engine ↔ top/P&R | 32 voices require 100 MHz P&R evidence. | No completion claim from simulation alone. |
| Task 9 ↔ Task 10 | upload/APPLY ↔ UART transport | Upload blocks/CRC/ACK must be independent of audio path. | Task 10 queues writes and reports tested ACK/NACK reasons. |
| Task 9 ↔ Task 11 | patch/table semantics ↔ UI builders | UI must generate valid upload/APPLY sequence and clamp same as contract. | Python model shares exact constants/CRC. |
| Task 9 ↔ Task 12 | FX level ↔ top/telemetry | FX may be reduced based on measured P&R resources. | Task 12 reports actual level; no unverified full FX claim. |
| Task 10 ↔ Task 11 | UART frames ↔ PC transport | UI depends on byte-level parser and telemetry decoder. | Task 11 starts only after Task 10 stop gate. |
| Task 10 ↔ Task 12 | UART/telemetry ↔ top | Single V2 receiver and no old command receiver. | Top assertion/test checks one RX ownership. |
| Task 11 ↔ Task 12 | UI ↔ board telemetry | Top validation must consume same telemetry bytes UI decodes. | No EventTable or PCM path is added. |

## Per-task self-consistency scan

| Task | Text agrees with its files/tests? | Ruling / risk |
|---|---|---|
| 1 | Yes: files cover contract doc, SV package, Python codec, tests, README; steps cover fail-first, implementation, SV compile, commit. | Missing pre-existing contract is intentional and resolved by Task 1. |
| 2 | Yes: files cover PLL, scheduler, TB, synthesis script, SDC; steps require fail-first test and evidence. | Gowin primitive/tool may be unavailable; V2_SIM bypass and recorded unavailable evidence are required. |
| 3 | Mostly: plan references `tools/v2_fixed_reference.py` and test data but does not list them in Files. | Add them only if needed, document the extra files; do not weaken stop gate. |
| 4 | Yes: RTL/TB/reference/tests cover listed vectors. | Fixed-point alpha representation must be made explicit in contract/reference. |
| 5 | Yes: two FSM RTL/TBs/reference cover independent LIVE/LOOP. | Integration vectors may require helper package files; keep V1 untouched. |
| 6 | Yes: V2 store/scheduler/TB and three docs cover transaction semantics. | `loop_event_ram.sv` may only change via V2 wrapper as mandated. |
| 7 | Yes: RTL/TB/reference/tests/measurement script cover state, backtrace, budget. | 41 µs remains an estimate until measured; do not claim otherwise. |
| 8 | Mostly: files include RTL/TB/ROM/tests/synth but no explicit Python reference file. | Use test-side reference or add a clearly named helper; completion requires P&R evidence. |
| 9 | Yes: loader/FX/TB/patch tests and contract update cover interfaces. | Chorus/reverb downgrade must be recorded based on actual synthesis. |
| 10 | Yes: UART/snapshot/TBs/script/contract mismatch path cover requirements. | 115200 fallback is measured evidence, not default contract change. |
| 11 | Yes: model/UI/tests/docs appendix cover offline/no-EventTable rule. | Tk smoke test must not open real serial hardware. |
| 12 | Yes: top/TB/scripts/report/manifest/README cover final integration. | Board/P&R may be unavailable; report exact missing evidence and do not overclaim. |

## Rulings

- Ruling: Preserve V1 files and user dirty files exactly — required by the user and plan; cost if wrong is duplicated maintenance, accepted to protect regression baseline.
- Ruling: Push attempts are authorized by the user; if authentication fails, retain local commits and report the failure.

## Progress

- Task 1: pending dispatch.
- Task 1: complete (commits 4d3308d, 8cc7d59, b999c98; task review clean after scoped fixes). Evidence: Python 5/5, ModelSim vlog 0 errors/0 warnings, git diff --check. User dirty files preserved.
- Environment correction: `gw_sh.exe` exists at `C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe` but is not on PATH.
- Task 2: complete (commits bbbba36, f7cc0b5; review clean after BCLK SDC correction). Evidence: ModelSim 100M-cycle scheduler PASS, V2_SIM compile PASS, scheduler script PASS, git diff --check. Gowin synthesis attempted with absolute gw_sh path but stopped at RP0008 no PLL resource for declared device; no Fmax/P&R claim.
- Task 3: complete (commits d36f344, 7a52fee, 78c5188, de1d964; review clean after scoped fixes). Evidence: Python 8/8, ModelSim V2 input TB PASS, V1 latch vlog 0 errors, git diff --check. No Gowin arithmetic synthesis or RTL/Python equivalence claim.
- Task 4: complete (commits 4efb90e, 6a6821c; review clean after median/stable metadata/pitch/velocity fixes). Evidence: Python 12/12, ModelSim cursor TB PASS, standalone Gowin synthesis final REG947/ALU692/LUT10613/DSP14; no P&R/Fmax claim; git diff --check.

## Gate audit correction (2026-10-26)

The previous Task 1–4 complete lines were premature and are superseded by this section. A task review scoped to code defects is not a replacement for the plan Stop gate.

- Task 1: REOPENED. Existing package/document froze ranges but omitted concrete CSR register/field/operation/ACK/event constants, and negative-index typedefs are not enforceable SV assertions. Corrective work is assigned to the existing Task 1 implementer.
- Task 2: REOPENED. The hardware PLL never synthesized; the old PLL configuration was not measured and the internal-feedback MDIV factor was omitted from the frequency calculation. Corrective work investigates PLLA with the installed manufacturer model and real synthesis/P&R. No 100 MHz hardware claim is accepted before those tests.
- Task 3: IMPLEMENTED, GATE OPEN. No RTL/reference integer/reason equality replay or arithmetic synthesis exists. Cross-module audit also found unsigned sensor XYZ cast to signed16, making Z>36000 unreachable downstream. Corrective input-boundary contract: signed17 arithmetic container; X/Y centered by subtracting32768, Z zero-extended preserving0..65535. V1 outputs unchanged. Needs contract + replay evidence before acceptance.
- Task 4: IMPLEMENTED, GATE OPEN. Independent Python/RTL tests and standalone synthesis exist, but required frame-by-frame golden comparison is absent. Also need source-to-cursor high-Z integration vectors after the input-boundary fix. Resource reports are module-only, not 100MHz timing evidence.
- Task 5: implementation candidate `97e5808`, NOT ACCEPTED/NOT PUSHED. Reviewer identified loss under LIVE and LOOP backpressure, initial arm without rightward confirmation, and NOTE_OFF spacing/reference mismatch in predecessor commit. Final SHA needs full review and corrections after Task1/2 gates close.
- Tasks 6–12: NOT STARTED. Do not advance past unresolved gates.

Ruling: Treat the user's Stop gates as binding and reopen incorrectly completed tasks — evidence gaps cannot be waived as non-blockers — cost is rework of early modules before later integration, preferable to unverifiable completion claims.

## Corrective execution

- Task 1: corrective candidate `230e67a` reviewed; gate remains open. Important findings: indexed calibration/full patch access absent; APPLY boundary conflict; incomplete UART status/errors and version/upload rules; reserved-bit/event legality and machine-readable CSR packing checks incomplete. Existing Task 1 implementer is fixing the unified findings; Task 5 must later import the corrected contract.
- Task 2: `dfbf4ae` corrected PLL to GW5A PLLA with real 50 MHz model input and a routed clock/scheduler probe. Review verified the evidence, then requested synchronized reset release and an explicit I2S constraint phase. Corrective `e18a68d` adds async-assert/sync-release reset and updates plan/report; scoped review pending. Probe-only routed Fmax 194.654 MHz, setup/hold TNS 0; this is not final-top timing.
- Ruling: Constrain only actual clock ports at Task 2; add synchronous I2S/BCLK output timing at Task 12 when the real transmitter/top ports exist, without false asynchronous cuts — no such V2 ports exist at Task 2 — cost if wrong is integration timing rework; Task 12 must not close without its I/O constraints.
- Ruling: Resolve Task 5/6 ordering cycle by testing the six-track write contract in Task 5 and requiring actual recorder/store integration in Task 6 before its gate closes — Task 6 is the first creation of the real V2 store — cost if wrong is integration rework at Task 6; interface-model results cannot claim store integration.
- Preservation recheck: SHA256 of both pre-existing modified documents and the actual untracked PDF still matches the setup audit. V1 top/voice/protocol/Loop and PC receiver have no diff from initial `6bd5597`. Newly untracked root `work/` and `transcript` were identified by the Task 1 implementer as its ModelSim artifacts and left in place.
- Task 2: complete (corrections dfbf4ae, e18a68d; scoped review clean). Hardware 50-to-100 MHz model, reset qualification, exact scheduler count, synthesis and probe P&R verified. Final-top and I2S timing remain Task 12 requirements.
- Task 1: complete (corrections 097ff47, fe3ab72, 4325d2f; scoped review clean). Contract now freezes indexed families, Q/range/scope metadata, signed wire encoding, CSR validators, UART/WT/APPLY semantics and executable mutation tests. Task5 duplicate constants remain its own gate.
- Task 3: complete (corrections `4b18a02`, `b59e5c5`, `dc50db0`, `4bf003d`; scoped review clean). Real latch→calibration→validity replay covers 976 rows, raw signed17/unsigned17 boundary, invalid zero outputs, explicit metadata, free-running timestamp model, adjacent reports and idle leakage. Preserved Gowin arithmetic synthesis reports 72 LUT, 124 FF, 0 latch, 0 ALU, 0 BSRAM, 0 DSP; EX2420/EX3101 sign-extension warnings are disclosed. No P&R/timing claim; cursor integration remains Task 4 evidence.
