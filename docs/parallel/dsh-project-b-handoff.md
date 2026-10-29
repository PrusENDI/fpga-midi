# dsh 项目 B 交接：共享 H0 harness 下的 Potts/resource stream

## 任务定位

你接手 V2 A/B 并行计划中的 B stream。A stream 由 Codex 在 voice worktree 处理 voice metadata timing；你只负责 Potts 语义、full-path 资源归因和 Gowin 证据采集。

总计划：
C:\weizijian\documents\gowin fpga\mgc3130_uart\docs\superpowers\plans\2026-10-29-v2-timing-optimization.md

A/B 分工：
C:\weizijian\documents\gowin fpga\mgc3130_uart\docs\parallel\v2-ab-parallel-execution-plan.md

## 工作区

仓库：
C:\weizijian\documents\gowin fpga\mgc3130_uart

B worktree：
C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-potts-resource

分支：
work/v2-potts-resource

代码基线：
af447aa

进入工作区后先检查：

~~~powershell
Set-Location 'C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-potts-resource'
git status --short --branch
git rev-parse HEAD
~~~

主线程会另行提供 H0 harness commit。收到后必须在 B worktree cherry-pick 该 commit，并记录为 H0 commit。没有 H0 commit 时，不得创建自己的 full-path Tcl、probe 或 verifier；只能做只读审查和 Potts 单元准备。

禁止：
- 在主工作区修改文件
- git reset --hard
- git clean
- push
- 修改 A worktree
- 修改 docs/v2-progress-log.md

## B stream 允许修改

- rtl/v2_potts_commit_fsm.sv
- sim/tb_v2_potts_commit_fsm.sv
- sim/tb_mgc3130_v2_top_potts.sv
- scripts/test_v2_top_potts.ps1
- scripts/sweep_v2_fullpath_resources.ps1
- docs/v2-potts-h32-resource-note-2026-10-29.md
- docs/parallel/v2-potts-resource-report.md

H0 文件只能读取和调用，不能修改：

- sim/v2_top_fullpath_probe.sv
- scripts/synth_v2_top_fullpath_20261029.tcl
- scripts/verify_v2_fullpath_run.ps1

## 必须保持的语义

- HORIZON=128 portable default 不变。
- HORIZON=32 只作为明确记录的 board 32-slot capacity match。
- 96-bit event layout、backtrace、event count、overflow、progress、tie-break、saturation 不变。
- Potts 是后台多周期 FSM，不能阻塞 sample_ce、UART status read 或 active-bank playback。
- full-path 必须保留真实 reader、Loop、Potts、32×2 voice、FX=1/level=1、UART/telemetry 和 I2S。
- 不能用 USE_POTTS=0、stub、常量 contour、减少 voice、关闭 FX 或 NL0002 swept 伪造通过。

## 当前基线证据

真实 full-path 配置曾得到：

~~~text
USE_MGC_READER=1
USE_GOWIN_RAM=1
USE_POTTS=1
PRESERVE_LOOP_PLANE=1
PRESERVE_POTTS_PLANE=1
POTTS_HORIZON=32
FX_ENABLE=1
FX_LEVEL=1
~~~

综合结果：

~~~text
RP0006: 25538 logic = 21610 LUT + 3928 ALU > 23040 GW5A limit
~~~

这次没有新 routed netlist 或 bitstream。旧的 21,513 logic、Fmax 2.616 MHz、2,383 setup violations、TNS -19,983.029 ns 只能作为历史诊断证据。

E2 约束必须在 H0 harness 中保持：

- clk_50m = E2/5
- use_sspi_as_gpio 1
- use_cpu_as_gpio 1
- 无 PR2017/PR2028

## 执行顺序

### 1. 等待并接入 H0

主线程提供 H0 commit 后：

~~~powershell
git cherry-pick <H0 commit supplied by main lane>
git show --stat --oneline HEAD
~~~

确认 H0 文件存在且工作树只包含预期文件。不要在 B 中重写 H0。

### 2. 运行 B 基线测试

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_top_potts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_top.ps1
python -m unittest discover -s tools -p 'test_*.py'
git diff --check
~~~

失败时保留完整日志并报告 BLOCKED，不要修改测试期望来消除失败。

### 3. 做 Potts 资源优化

优先把 implementation-wide integer、重复宽乘法和不必要的宽中间量改为显式 fixed-point 位宽；保持每个 DP cell 的多周期 FSM、saturation 和 tie-break。

先验证 H32/H128 的共享前 32 点事件序列，再运行 top Potts regression 和 Python reference tests。

### 4. 使用共享 H0 harness 做新鲜资源/P&R

每次使用唯一 run id，例如：

~~~text
impl/v2_fullpath_h0_b_potts_<commit>/
~~~

命令由 H0 文档定义，必须显式传入唯一 run id，形式为：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path -LicenseServer '106.55.34.119:10559' -RunId "h0_b_potts_<commit>"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_v2_fullpath_run.ps1 -RunDir "impl/v2_top_fullpath_h0_b_potts_<commit>"
~~~

检查 synthesis、P&R、timing、pin、device.cfg 和 verifier 输出。许可证连接失败时保留原始错误并报告 BLOCKED；不能读取旧目录补充结果。

### 5. 提交 B 结果

创建 docs/parallel/v2-potts-resource-report.md，至少写入：

~~~text
状态：VERIFIED / BLOCKED / NEEDS_REVIEW
worktree：
branch：
base commit：af447aa
H0 commit：
stream commit：
命令：
测试 PASS 数：
logic/LUT/ALU/DPB/DSP：
Fmax/setup/hold：
E2/5、CPU/SSPI regular_io、PR2017/PR2028：
修改文件：
未解决问题：
主线程下一步：
~~~

提交一个清晰 commit，不要 push。回报只包含 commit hash、报告路径、测试结果、资源/P&R 证据和阻塞项。
