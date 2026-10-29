# V2 A/B 并行执行计划

## 目标

把 2026-10-29 时序与资源优化计划拆成两个互不修改同一组 RTL 文件的 workstream，并让 Codex 与 dsh 使用同一个可复现 full-path gw_sh harness。

本文件是执行分工；总体验收门槛仍以 docs/superpowers/plans/2026-10-29-v2-timing-optimization.md 为准。

## 基线与 worktree

仓库：
C:\weizijian\documents\gowin fpga\mgc3130_uart

代码基线：
af447aa chore: ignore local parallel worktrees

A：
- 目录：C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-voice-timing
- 分支：work/v2-voice-timing
- 角色：Codex RTL agent

B：
- 目录：C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-potts-resource
- 分支：work/v2-potts-resource
- 角色：dsh 或 Codex build agent

两个 worktree 当前都从 af447aa 派生。两个 agent 不得直接写主工作区。

## H0：共享 harness 前置门

A、B 开始前，主线程必须先创建一个 H0 提交。H0 只包含共享执行基础设施：

- sim/v2_top_fullpath_probe.sv
- scripts/synth_v2_top_fullpath_20261029.tcl
- scripts/verify_v2_fullpath_run.ps1
- harness 相关的 progress log 记录

H0 必须固定：

- 器件 GW5A-LV25MG121NES
- 明确的 source file list
- top module 与 SystemVerilog 标准
- USE_MGC_READER、USE_GOWIN_RAM、USE_POTTS、POTTS_HORIZON、FX_ENABLE、FX_LEVEL
- mgc3130_v2.cst 与 mgc3130_v2_top_observable.sdc
- use_sspi_as_gpio 1
- use_cpu_as_gpio 1
- 每次 run 的唯一 impl 输出目录
- source commit、dirty state、tool version、command、exit code 和 report path manifest
- RP0006、NL0002、PR2017、PR2028、E2/5、CPU/SSPI regular_io、resource、setup/hold 的机器检查

H0 通过 review 后，主线程把同一个 H0 commit 提供给 A、B。两个 worktree 必须执行 cherry-pick；没有 H0 commit 时，两个 agent 都只能做只读审查，不能各自创建 harness。

## A：voice metadata timing

### 目标

修复 age、releasing、velocity 选择路径的长组合逻辑，同时保持 32 voices × 2 oscillators 的功能契约。

### 允许修改

- rtl/v2_voice_engine_banked.sv
- rtl/v2_voice_state_bank.sv（仅在需要显式 read/write latency boundary 时）
- sim/tb_v2_voice_engine_banked.sv
- sim/tb_v2_voice_replay.sv
- 对应 voice test scripts
- docs/parallel/v2-voice-timing-report.md

### 禁止修改

- rtl/v2_potts_commit_fsm.sv
- sim/v2_top_fullpath_probe.sv
- scripts/synth_v2_top_fullpath_20261029.tcl
- scripts/verify_v2_fullpath_run.ps1
- B 的 sweep、Potts tests 和报告
- docs/v2-progress-log.md

### A 的独立 gate

- victim priority 仍为 released → oldest → lowest velocity → lowest voice ID。
- bounded steal-release、pending note、revoice、vibrato 和 active bitmap 语义保持不变。
- voice ModelSim/replay tests 通过。
- Python suite 通过。
- 使用 H0 harness 的新证据显示 voice 关键路径改善；没有 H0 时不得自行建立替代 harness。
- 提交一个 A 分支 commit，并写 voice-specific report。

## B：Potts 与资源收敛

### 目标

在保留真实 reader、Loop、Potts、32×2 voice、非零 reduced FX、UART/telemetry 和 I2S 的条件下，将 Potts/full-path 资源降到 GW5A 限制以内，并采集新鲜综合/P&R 证据。

### 允许修改

- rtl/v2_potts_commit_fsm.sv
- sim/tb_v2_potts_commit_fsm.sv
- sim/tb_mgc3130_v2_top_potts.sv
- scripts/test_v2_top_potts.ps1
- scripts/sweep_v2_fullpath_resources.ps1
- docs/v2-potts-h32-resource-note-2026-10-29.md
- docs/parallel/v2-potts-resource-report.md

### 禁止修改

- rtl/v2_voice_engine_banked.sv
- rtl/v2_voice_state_bank.sv
- H0 harness 的三个文件
- A 的 voice tests 和 report
- docs/v2-progress-log.md

### B 的独立 gate

- HORIZON=128 portable default 不变。
- HORIZON=32 只作为明确记录的 board 32-slot capacity match。
- 96-bit event、backtrace、event count、overflow、progress、saturation 和 tie-break 不变。
- Potts top regression 和 Python tests 通过。
- synthesis 无 RP0006；硬上限 23,040 logic，推荐目标 ≤22,000。
- required path 不得出现 NL0002 swept。
- 通过 H0 harness 运行新鲜资源/P&R，不能引用旧 report 或旧 bitstream。
- 提交一个 B 分支 commit，并写 resource-specific report。

## 共享 harness 使用规则

A、B 从各自 worktree 调用同一 wrapper 和 Tcl，命令形式为：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path -LicenseServer '106.55.34.119:10559' -RunId 'h0_<stream>_<commit>'
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_v2_fullpath_run.ps1 -RunDir "impl/v2_top_fullpath_h0_<stream>_<commit>"
~~~

每个 agent 使用独立 run id，例如：

- impl/v2_fullpath_h0_a_voice_<commit>/
- impl/v2_fullpath_h0_b_potts_<commit>/

两个 P&R 进程如果争用同一 license seat，dsh 只排队执行，不修改 Tcl 来绕过限制。ModelSim 可以并行。

diagnostic profile 可以使用 preserve 参数做归因，但只能作为诊断证据。最终 acceptance profile 必须保留真实可达路径，不能用 USE_POTTS=0、stub、常量 contour 或 swept net 代替。

## 主线程集成门

A、B 完成后，主线程按以下顺序处理：

1. 审查两个 diff 和两个 stream report。
2. 确认两个 commit 都没有修改对方文件或 H0 文件。
3. 将 A、B commit 合并到集成分支。
4. 从合并后的新 commit 运行 H0 harness，使用新的 impl 目录。
5. 更新 docs/v2-progress-log.md、validation report 和 board-readiness review。
6. 只有资源合法且 100 MHz timing gate 通过后，才进入 bitstream/hash/board gate。

## 统一回报格式

每个 stream report 必须包含：

~~~text
状态：VERIFIED / BLOCKED / NEEDS_REVIEW
worktree：
branch：
base commit：
H0 commit：
stream commit：
命令：
测试结果：
综合资源：
P&R/timing：
修改文件：
未解决问题：
主线程下一步：
~~~

本次文档重写只更新计划和交接材料，不启动 agent、不运行 gw_sh，也不生成新的 bitstream。
