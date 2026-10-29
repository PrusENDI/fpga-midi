# dsh 项目 B 交接：Potts 与 V2 Full-Path 资源收敛

## 交接目标

dsh 接手 V2 计划中的项目 B，负责 Potts 资源压缩、full-path P&R harness、资源归因和 Gowin 证据采集。项目 A（voice metadata 时序修复）由另一个 agent 在另一个 worktree 独立处理。

## 工作区与基线

仓库：
C:\weizijian\documents\gowin fpga\mgc3130_uart

工作区：
C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-potts-resource

分支：work/v2-potts-resource
基线：af447aa chore: ignore local parallel worktrees
计划：docs/superpowers/plans/2026-10-29-v2-timing-optimization.md

必须先执行：

~~~powershell
Set-Location 'C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-potts-resource'
git status --short --branch
git rev-parse HEAD
~~~

工作区应为空，HEAD 应为 af447aa。禁止在主工作区工作，禁止 git reset --hard、git clean 和 push。

## 当前已知证据

当前基线已包含可参数化的 POTTS_HORIZON：portable 默认仍为 128，板级实验可显式使用 32。最近一次真实 full-path 配置为：

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

该配置已经进入 Gowin synthesis，但失败于：

~~~text
RP0006: 25538 logic = 21610 LUT + 3928 ALU > 23040 GW5A limit
~~~

因此没有新的 routed netlist 或可上板 bitstream。上一份 package-legal P&R 只是旧诊断证据：21,513 logic、Fmax 2.616 MHz、2,383 setup violations、TNS -19,983.029 ns、hold 0；它不能作为本任务的通过证据。

E2 约束必须保留：clk_50m = E2/5，Tcl 必须设置 -use_sspi_as_gpio 1 和 -use_cpu_as_gpio 1，最终报告不能出现 PR2017/PR2028。

## 允许修改范围

可以修改或新增：

- rtl/v2_potts_commit_fsm.sv
- Potts 相关 testbench 和脚本，例如 sim/tb_mgc3130_v2_top_potts.sv、scripts/test_v2_top_potts.ps1
- sim/v2_top_fullpath_probe.sv
- scripts/synth_v2_top_fullpath_20261029.tcl
- scripts/sweep_v2_fullpath_resources.ps1
- docs/parallel/dsh-project-b-report.md

不要修改：

- rtl/v2_voice_engine_banked.sv
- rtl/v2_voice_state_bank.sv
- 项目 A 的 voice testbench
- docs/v2-progress-log.md（由主线程统一更新）
- 主工作区文件、另一个 worktree 的文件、公共 .gitignore

## 必须保持的语义

- HORIZON=128 是 portable 默认值。
- HORIZON=32 只用于明确记录的板级 32-slot capacity match。
- 96-bit V2 event layout、backtrace、event count、overflow、progress、tie-break 和 saturation 语义不能改变。
- Potts 是后台多周期 FSM，不能阻塞 sample_ce、UART status read 或 active-bank playback。
- full-path 实验必须保留真实 reader、Loop、Potts、32×2 voice、非零 FX、UART/telemetry 和 I2S。
- 不能通过 USE_POTTS=0、stub、常量 contour、减少 voice、关闭 FX 或 NL0002 swept 获得“通过”。

## 执行顺序

### 1. 基线回归

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_top_potts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_top.ps1
python -m unittest discover -s tools -p 'test_*.py'
git diff --check
~~~

若失败，记录完整输出，不要用修改测试期望的方式掩盖失败。

### 2. 创建 full-path probe 与 Tcl harness

创建 sim/v2_top_fullpath_probe.sv，显式实例化 mgc3130_v2_top，使用上面的 full-path 参数。创建 scripts/synth_v2_top_fullpath_20261029.tcl，使用唯一输出目录：

~~~text
impl/v2_top_fullpath_20261029_dsh
~~~

Tcl 必须加载当前 RTL、mgc3130_v2.cst、mgc3130_v2_top_observable.sdc，并设置：

~~~tcl
set_option -use_sspi_as_gpio 1
set_option -use_cpu_as_gpio 1
run syn
run pnr
~~~

### 3. Potts 资源优化

优先使用显式位宽的 fixed-point 中间量替代 implementation-wide integer 和重复宽乘法；保持每个 DP cell 的多周期 FSM 结构。任何改动都必须先通过 Potts RTL regression，再进入 Gowin synthesis。

建议同时覆盖 H32 与 H128：共享前 32 点输入时，事件序列和 tie-break 必须一致；默认 H128 测试不能被板级 H32 选项替换。

### 4. 运行 gw_sh

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path -LicenseServer '106.55.34.119:10559'
~~~

如果许可证连接失败，保留错误输出并在报告中写明；不能把旧 P&R 报告当成本次结果。

### 5. 资源 sweep

如果可以，使用 scripts/sweep_v2_fullpath_resources.ps1 为每个配置创建独立 impl 目录。至少记录 H128/H32 和 FX level 0/1 的 synthesis 结果。资源目标是 ≤22,000 logic，给 P&R 留出余量；23,040 是硬上限，不是推荐目标。

## 通过条件

项目 B 只有在以下证据齐全时才可标记 VERIFIED：

- Potts top regression PASS。
- Python/SV 全套相关测试 PASS。
- synthesis 无 RP0006，logic ≤23,040；推荐 ≤22,000。
- required full-path 没有 NL0002 swept。
- 若进入 P&R：E2/5、CPU/SSPI regular IO、无 PR2017/PR2028、setup/hold/Fmax 均已从本次新报告读取。
- 所有输出路径、source commit、命令、exit code 和许可证错误（若有）均写入报告。

## 回报文件格式

创建 docs/parallel/dsh-project-b-report.md，至少包含：

~~~text
状态：VERIFIED / BLOCKED / NEEDS_REVIEW
分支：work/v2-potts-resource
基线：af447aa
最终提交：<commit>
命令：<exact commands>
功能证据：<logs and PASS counts>
综合证据：<logic/LUT/ALU/DPB/DSP or RP0006>
P&R证据：<Fmax/setup/hold/pins/device.cfg, or not run>
修改文件：<file list>
未解决问题：<none or exact blocker>
主线程下一步：<one action>
~~~

完成后在分支上提交一个清晰 commit，只把 commit hash、报告路径、测试结果和阻塞项发回主线程。主线程会审查 diff、合并进度文档，并决定是否进入下一轮优化。

## 给 dsh 的可复制提示词

见同目录的 dsh-project-b-prompt.txt；它是上面要求的压缩版，适合直接粘贴到 dsh。
