---
name: fpga-long-run
description: Run long FPGA implementation, synthesis, timing, and board-validation work with lightweight phase checkpoints, fresh evidence, and recovery rules; use full subagent-driven development only for multi-file RTL or interface changes.
---

# FPGA Long-Run

Use this skill for FPGA work that spans multiple sessions or crosses simulation, synthesis, P&R, bitstream, and board testing. It is an explicit lightweight overlay for this repository; do not load the full Superpowers task loop for documentation, status audits, or a single-command verification.

## Select the smallest mode

- **Quick:** one file or one command. Make the change, run the covering check, and report the exact result.
- **Checkpoint:** a multi-step phase. Read the current ledger, define entry and exit evidence, run the phase, update the ledger, and create a local Git checkpoint.
- **Full:** use `superpowers:subagent-driven-development` only when work has multiple independent RTL tasks, a shared interface change, timing closure, or repeated unresolved failures. Keep the full implementer/reviewer loop scoped to that phase.

## Lightweight workflow

1. Identify the repository root and read only the current progress ledger and the relevant plan or readiness review. For this project, prefer `docs/v2-progress-log.md` and the current board-readiness review.
2. State one phase with an entry condition, a concrete exit condition, and the artifact that proves it. Do not call a standalone model, stub, probe, or old bitstream final evidence.
3. Work from small briefs and artifact paths. Do not paste the full session history into an agent prompt. Use parallel agents only for independent read-only audits or isolated changes.
4. Run fresh verification after the phase. Classify evidence as `source`, `simulation`, `synthesis`, `timing`, `bitstream`, or `board`; report gaps explicitly.
5. Update the ledger with the command, exit code, key result, unresolved issue, and next phase. Create a descriptive local checkpoint after a meaningful phase. Do not push to a shared remote unless the user explicitly authorizes it.
6. Before any completion claim, rerun the command that proves that claim and include the observed result. Use `superpowers:verification-before-completion` when the phase is being declared complete.

## FPGA phase gates

Advance only when the current gate has evidence:

`RTL/contract → simulation → synthesis → P&R/timing → bitstream/hash → board smoke → acceptance measurements`

Record device, clock constraints, tool version, source revision, artifact path, and any timing or warning status for synthesis/P&R and board evidence. A bitstream is current only when its hash and source commit are recorded.

## Recovery after interruption

Read the ledger first, then `git status` and recent history. Resume from the last completed gate instead of repeating earlier work. Preserve uncommitted files and generated evidence; never use `git reset`, `git clean`, or destructive overwrite as recovery. If the same blocker recurs, record the root cause and the smallest next experiment, then escalate to full debugging or full SDD only when the mode criteria above are met.

## Compact status format

Report long-run progress as:

`状态：<进行中/通过/阻塞>；阶段：<gate>；证据：<artifact + command/result>；提交：<hash>；下一步：<one action>；阻塞：<none or cause>`
