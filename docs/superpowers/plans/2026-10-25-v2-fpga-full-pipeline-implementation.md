
# V2 FPGA 全链路合成器实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 在 GW5A-25A 上交付可独立综合、布局布线、烧录和验收的 V2 全链路：MGC3130 输入、FPGA 固定点坐标处理、LIVE 出音、六轨 Loop、提交时 Potts 精修、32 声部双振荡器、混音/有限 FX、I2S 输出，以及 PC 参数和遥测 UI。

**Architecture:** V2 使用全新的 rtl/mgc3130_v2_top.sv，不把旧 mgc3130_uart_top.sv 当作最终顶层，也不要求 PC 发送 EventTable。FPGA 内部以 100 MHz 系统时钟运行，使用分数累加器产生平均精确 48 kHz 的 sample_ce，输入和控制在独立队列中跨到音频处理域。LIVE 使用逐帧电平穿越和门控，LOOP 在一圈结束后由固定点 Potts FSM 提交精修；PC 只下发 shadow 配置、波表和控制命令，并接收双缓冲遥测。

**As-built boundary:** 当前 RTL 已形成独立 V2 top、PLL/scheduler、输入 replay、timed cursor、LIVE/LOOP 专项、32-slot 六轨 store、DPB-backed loop storage、独立 Potts、32-slot/双振荡器 voice bank、reduced FX standalone、UART/telemetry serializer 和离线 PC model。顶层现在选用 DPB-backed loop storage，并已有真实 recorder contour→Potts 的顶层 ModelSim 测量；reader 可达输入、Potts timeout/pending policy、patch/wavetable CSR、非零 FX、telemetry TX 消费、I2S 端口约束/P&R 和板级路径尚未全部闭合。下面的“目标/Stop gate”不能解释为这些项目已经实现。

**Tech Stack:** SystemVerilog（Gowin GW5A-25A、Gowin DPB/PLL、ModelSim/Questa、Gowin 综合与 P&R）、Python 3 标准库和现有 tools/synthwave_loop.py 黄金参考、Tkinter PC UI、PowerShell 验收脚本。

**Spec:** docs/system-design-summary-2026-10-25.md、docs/synth-backend-design-2026-10-25.md、docs/voice-engine-design-2026-10-25.md、docs/fpga-baseline-audit-2026-10-25.md，以及本计划中的 docs/v2-fpga-contract-2026-10-25.md。冲突时以 V2 contract 和本计划为准；旧 PC EventTable 后端只作为离线黄金参考。

## 2026-10-27 计划修订控制

本节覆盖原计划中被实际 RTL、ModelSim、Gowin P&R 或顶层探针证据推翻的目标。它是本计划的当前版本；下面各任务的修订条目优先于同一任务中保留的历史估算。

- **时钟边界**：V2 只有一个由 GW5A PLL 从 50 MHz 生成的 100 MHz `clk_sys_100m`。输入、控制、FIFO、Potts 和声部引擎都可以在这个时钟域内跨多个周期运行；禁止的是第二个自由运行音频时钟。48 kHz 只由 `sample_ce` 标记音频样本边界。
- **Potts 预算**：删除“41 µs 已成立”的目标。Potts 是 Loop COMMIT 后的多周期后台 FSM，必须以真实 contour 测量最坏周期；它不阻塞 active Loop、LIVE、`sample_ce`、声部或 I2S，只阻塞待提交 bank 的切换。41 µs 只能作为历史估算，不能作为验收阈值。
- **声部口径**：当前 V2 硬指标固定为 **32 simultaneous voices × 2 oscillators = 64 oscillators**。旧文档中的 32×4、128 operator/FM 是后续扩展，不能用于本轮 Task 12 通过或资源宣称。
- **最终路径真实性**：Task 12 的最终 P&R 必须包含有效输入、实际 reader 或等价可达输入、LIVE/LOOP、真实 Loop contour、Potts、32×2 voice、启用的 reduced FX、实际 UART/telemetry 和 I2S。`USE_POTTS=0`、`PRESERVE_INPUT_VALID=0`、stub、不可达保留网和被 `NL0002 swept` 的探针只能作为诊断证据。
- **证据分层**：专项仿真/综合/P&R 通过不自动等于最终顶层通过。Task 8/9/10/11 的专项 gate 可以保持通过，但最终顶层必须重新证明接口接线、时序、资源、延迟和板级行为。
- **历史文档**：`docs/synth-backend-design-2026-10-25.md`、`docs/voice-engine-design-2026-10-25.md`、`docs/system-design-summary-2026-10-25.md` 中的 64-bit EventTable、128 operator、41 µs 和“未写 RTL”章节保留作历史记录；执行时以本计划和 `docs/v2-fpga-contract-2026-10-25.md` 为准，并在最终 validation report 中列出冲突及 superseded 结论。
- **新增早期硬件切片**：Task 2 完成后立即执行 Task 2.5 的单振荡器假事件出声切片，提前验证 PLL、sample scheduler、I2S 和 package pins；该切片不是最终 V2 top 验收证据。
- **继续执行口径**：Task 2.5 是在已有 RTL 之后补做的硬件通路 gate，不表示历史实现已经按 Task 1→2→2.5→3 的顺序完成。已有 Task 3–11 的专项证据可以保留，但必须按下表的差异项补做；Task 12 只能在这些差异项闭合后重新验收。

## 历史开发经验与工具使用（2026-10-27）

本节把本轮对话中已经实际验证过的环境、命令和失败模式固化为后续执行规则。它不是新的功能需求；当它与旧日志或旧计划冲突时，以当前源码和可重现命令的最新证据为准。

### Windows/Gowin CLI 与许可证

- ModelSim 位置为 `C:\modeltech64_10.6d\win64`；Gowin CLI 为 `C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe`。调用时必须记录绝对路径、Tcl 文件、输出目录和退出码。
- `scripts/gw.sh` 是 Git Bash 入口，实际通过 PowerShell 调用 `scripts/run_gowin_cli.ps1`；Windows PowerShell 直接使用：

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
    -TclScript scripts/synth_v2_voice_engine.tcl
  ```

- `run_gowin_cli.ps1` 会设置 `GOWIN_HOME`、`GW_HOME` 和 Gowin `IDE\bin` 的 `PATH`，从 Gowin 安装目录启动 `gw_sh.exe`，并可通过 `-LicenseServer` 显式传递服务器。不要修改安装目录中的 `gwlicense.ini`。
- License Manager 显示 `Server is OK` 只能证明许可证服务状态；受限执行环境可能无法打开 license-server socket，导致 `gw_sh.exe` 在进入 Tcl 前退出。此时应区分“许可证有效”和“当前进程网络不可达”，用外部网络允许的 CLI 重新运行，而不是修改许可证或把退出码 1 当成综合失败。
- CLI 连接修复的最小检查是运行 `scripts/hello_gw.tcl`（当前脚本输出 `HELLO`）或等价 Tcl，确认进入 Tcl；用于验证包装器的专用 probe 可额外输出 `GW_WRAPPER_TCL_OK`。随后必须完成真实 `run syn`/`run pnr`，并在 `impl/<run>/impl/gwsynthesis`、`impl/<run>/impl/pnr` 留下报告。只进入 Tcl 不算 P&R 通过。

### 推荐的检查顺序

1. 先执行 `git status --short --branch`、`git log -1 --oneline`，再用 `rg`、`Get-Content` 检查实际 RTL、top、Tcl 和 SDC。禁止用 `git reset`、`git clean` 或覆盖未提交文件来“恢复干净环境”。
2. Python 协议/参考模型使用 `python -m unittest ... -v`；ModelSim 使用仓库中的 `scripts/test_*.ps1`，并保留 `compile.log`、console log 和 PASS 行。
3. Gowin 运行使用 `scripts/run_gowin_cli.ps1` 或 `scripts/gw.sh`，每次都用独立 `impl/<run-name>` 目录。不要把 GUI 中的旧报告、旧 bitstream 或未标注源码版本的 artifact 当作当前结果。
4. 文档或脚本修改后运行 `git diff --check`；报告命令、commit、设备、时钟约束、资源、Fmax/slack、bitstream SHA-256 和是否为 probe/stub。
5. 复现失败时优先检查 Tcl 的 top module、文件清单、`mgc3130_v2.sdc` 时钟名和 `USE_*` 参数，再检查 RTL；不要先放宽约束掩盖关键路径。

### Task 8 时序失败的已验证根因

- 初始 voice P&R 的 38.678 MHz、后续 58.253 MHz 和 alias probe 的 76.756 MHz 都是真实时序失败，不是许可证或 SDC 假象。有效路径从 `scan_slot`/active 状态进入变量索引的声部状态读写，单周期内同时完成状态读取、两个 oscillator 计算、累加、包络/释放更新和饱和输出。
- 未打包的 unpacked per-voice arrays 会被 Gowin 推成 RAMREG/逻辑阵列；报告中的 0 BSRAM 是危险信号。单纯改时钟约束、删除 alias 或把频率降到 50 MHz 不能证明 100 MHz 架构可行。
- 有效的修复方向是显式 DPB/BSRAM state bank、固定 lane mapping、BRAM read latency、compute/writeback 分阶段流水线，并在每次结构变化后重新做 ModelSim、综合和 P&R。旧 artifact 在后续命令边界修改后可能不再可复现，必须以当前源码的新建目录结果为准。
- 50 MHz 诊断 run 只能说明某个旧结构在较宽周期下能工作；它不是 V2 100 MHz 通过，也不能替代前端/声部的多周期化。

### 同一 100 MHz 时钟域的经验

- 控制、FIFO、Potts 和声部可以共享 PLL 产生的 `clk_sys_100m`，但不能要求所有工作在一个 100 MHz 周期内完成。共享时钟域与单周期组合实现是两个不同问题。
- Task 12 的失败来自有效输入、cursor/live、声部状态读写和 Potts 路径被保留后形成的长组合路径/高扇出，而不是“控制和声部必须分开时钟”这一结论。正确方案是多周期 FSM、寄存器/FIFO 边界和 `sample_ce` 音频边界；禁止另建自由运行音频时钟。
- 当前 structural probe 约 100.453 MHz 只使用了 `USE_POTTS=0`、invalid/stub 输入和保留网；同一 top 接入真实 reader 约 93.434 MHz、有效 reader-stub 约 97.691 MHz，均有 setup violations。这些数字必须并列记录，不能只保留最好看的 probe 结果。

### Potts、顶层和证据分层经验

- Potts 是 Loop COMMIT 后台 FSM，不是每个 `sample_ce` 都必须完成的音频运算。全零 contour、常量 rest mask、不可达 start 或 `USE_POTTS=0` 只能用于结构诊断；最终必须由真实 recorder contour 驱动，并测量 cycle count、timeout、pending 和 bank-swap 延迟。
- `scripts/synth_v2_top.tcl` 历史上把 `v2_top_synth_probe` 设为 top；该命令成功不等于 `mgc3130_v2_top` full-path P&R 成功。`scripts/test_v2_top.ps1` 默认 `USE_MGC_READER=0`，因此 `V2 top simulation PASS` 只证明 stub/default 仿真路径。
- `mgc3130_v2_top.sv` 当前 `fx_enable=0`、`fx_level=0`，`tlm_frame_ready=0`；所以 standalone FX/telemetry serializer 通过不能填最终 top gate。必须把真实 reduced FX、telemetry serializer、ACK/NACK 与 telemetry TX 仲裁和 I2S 端口都接入后重新测量。
- 出现 `NL0002 swept`、被优化掉的 preserve net、常量 contour 或未消费的输出时，只能把结果写入诊断章节，不能写入最终 acceptance 表。功能仿真通过、综合通过、独立模块 P&R 通过和最终 top/板级通过必须分栏记录。

### 结论写法

- “通过”必须带范围：例如“976 帧输入 replay 通过”“32×2 voice standalone P&R 通过”“structural timing probe 100.453 MHz”。
- “最终完成”必须同时有真实可达 top 的 RTL、综合/P&R、I2S/UART/telemetry 和板级证据。41 µs Potts、≤5 ms 延迟、32 声部资源和 FX 可用性都不能用估算代替。
- 每次修复应先记录事实和失败命令，再更新 contract/计划，最后才修改 RTL；否则旧报告很容易掩盖当前源码已经改变的存储推断、时序和接口行为。

## Global Constraints

- 最终演奏路径必须是 MGC3130 → FPGA 输入/滤波/光标/出音/Loop/声部/混音 → I2S；PC 不发送最终演奏事件，也不发送 PCM。
- 旧 mgc3130_uart_top.sv、旧 LOOP 位流和旧四轨/旧四声部路径保留为 V1 回归基线；V2 只在独立顶层实现。
- FPGA 系统时钟固定为 100 MHz；48 kHz 音频由分数 sample scheduler 产生，不能把 2083 个时钟当成精确整除周期。
- 六轨固定为 lead=0、bass=1、pad=2、arp=3、drums=4、texture_fx=5；六轨都能独立录制、覆盖和提交。
- LIVE 与 LOOP 使用两个独立状态机和两套 golden vector；LIVE 不等待全局 DP，LOOP 提交后才运行 Potts。
- Z 只能作用于力度、亮度/滤波、空间/调制深度和接合速度；纯 Z 变化不能产生 NOTE_ON、NOTE_OFF 或音高跳变。
- 输入校准、无效帧、饱和帧、gap、去耦合、固定点舍入、溢出和降级状态都必须有回放证据。
- 配置写入 shadow，经过 CRC/version 校验并显式 APPLY；UART 阻塞不能阻止 sample_ce、事件队列或 I2S。
- 当前 V2 声部验收规格为 32 simultaneous voices × 2 oscillators = 64 oscillators；128 operator/FM 仅作为后续扩展，不得混入当前资源或完成口径。
- 输入校准、cursor 和 LIVE/LOOP 前端必须使用多周期 FSM 或固定延迟寄存器流水线；每个算术阶段必须有明确寄存器边界，单级组合路径以 ≤2 ns 为目标并由 P&R 报告确认。200 Hz 输入允许每帧约 500,000 个 100 MHz 周期，禁止为追求单周期而形成长组合路径。
- Loop V2 当前目标为两 bank、六轨、每轨 32 个 96-bit event slots；现有 16-slot RTL 只能作为历史/专项证据，不能关闭最终容量 gate。
- 32 声部满载时默认使用确定性的 voice-steal 策略：released → oldest → lowest velocity → lowest voice_id；抢占必须有 bounded release，不能用瞬时截断代替平滑收尾。
- 每个声部必须支持固定点 vibrato LFO；`VIBRATO_HZ` 和 `VIBRATO_CENTS` 使用 contract 已定义的 UQ8.8 格式，调制 oscillator increment 的正负偏移，纯 vibrato 不产生 note event。
- 任意用户波表必须有明确的高音抗混叠策略；默认优先采用按频段/八度选择的 band-limited tables，polyBLEP 只允许用于有明确定义的基础波形模式。
- Potts 是可被测量的多周期后台计算；必须报告真实 contour 的最坏 cycle count、boundary timeout/pending 策略和 bank swap 延迟。41 µs、≤5 ms、FX 可用和最终资源结论都必须由对应的 RTL 仿真、综合/P&R 报告或板级测量支持，估算不能作为完成证据。
- 任何最终 P&R 结论必须来自真实可达路径，禁止用 stub、关闭 valid、关闭 Potts、常量输入或被综合删除的保留网替代验收路径。
- 最终顶层必须实际接通 V2 contract 的 CSR shadow/active/APPLY、telemetry TX ready/valid 和非零 reduced FX；仅有 serializer、常量 FX 或未消费的 telemetry frame 不能关闭 Task 12。
- 每个任务结束提交独立文档或代码提交；不得包含用户已有未提交文件。

## 当前证据基线与未闭合项

以下状态来自 2026-10-26 至 2026-10-28 的 `docs/v2-validation-report-2026-10-25.md`、当前工作区 RTL 和历史 P&R 日志；它们用于确定本计划的剩余工作，不替代 Task 12 的最终验收：

| 范围 | 当前状态 | 允许的结论 |
| --- | --- | --- |
| Task 1–5 | 合同、时钟、输入、cursor、LIVE/LOOP 专项 gate 已有回放或仿真证据 | 可以复用专项证据；仍需最终 top 接线回归 |
| Task 6 Loop | 32-slot/track store、recorder、scheduler、DPB replay 与 boundary timeout 已有专项证据 | 可以称存储/事务专项通过；最终 top P&R 和板级 gate 仍开放 |
| Task 7 Potts | 真实 recorder contour 已送入顶层 Potts；backtrace、后台 UART/sample 进度、timeout/pending policy 均有 RTL 回归证据 | 可以称真实 contour 仿真专项通过；不能称 41 µs 或最终 commit P&R 预算通过 |
| Task 8 voice | 当前 banked RTL 已实现 32 slot、双振荡器、voice-steal、bounded release 和 vibrato；Python/RTL/DPB replay 通过 | 可以称功能专项通过；当前源码的 100 MHz P&R 因 Gowin CLI code 1/no Tcl output 未闭合，旧 101.832 MHz artifact 仅作历史证据 |
| Task 9 wavetable/FX | DPB wavetable 和 reduced FX 专项通过 | 最终 top 必须启用非零 FX 并重新测量 |
| Task 10 UART/telemetry | 字节级 parser、serializer、双缓冲 snapshot 专项通过 | 顶层 `frame_ready`、实际 TX 消费和物理 baud 仍未闭合 |
| Task 11 PC/UI | 离线模型/UI gate 通过，Python 174 项通过 | 不包含真实串口和板级证据 |
| Task 12 top | 结构 probe 有 100.453 MHz、零 setup/hold violation；valid-input probe 和 valid+Potts probe 未通过 100 MHz | 最终 full-path P&R、I2S、telemetry、FX、延迟和板级 gate 仍开放 |

当前已知的最终顶层阻塞项：`potts_contour` 仍为零数组且默认 `USE_POTTS=0`；顶层 FX 以 `fx_enable=0`、`fx_level=0` 常量关闭；`tlm_frame_ready` 固定为 0，telemetry serializer 没有被 UART TX 消费；I2S/BCLK 端口约束和 package-pin legality 尚未形成最终证据；应用 CSR 的 shadow/active/APPLY/readback coverage 尚未完成。

计划容量修订：V2 `v2_loop_event_store`、`v2_loop_event_recorder` 和 `v2_loop_scheduler` 现已统一为 `DEPTH=32`、5-bit slot/read index 和六路 6-bit count；scheduler 在 slot 31 扫描结束。portable RTL store 使用扁平化地址，硬件 probe 使用六 lane 显式 DPB，不能通过只改 RAM 深度或保留旧计数宽度关闭 gate。BSRAM 占用以新的完整 P&R 报告为准，不能使用比例估算。

## 按当前 RTL 的实施状态

| Task | 当前已实施内容 | 计划差异与继续条件 |
| --- | --- | --- |
| 1 | 96-bit event、11-byte control、22-byte telemetry、CSR/Python codec 和 SV package 已存在；contract 专项测试通过 | 新增的 32-slot capacity、voice-steal counters/priority、N-tone selectors、wavetable band selector 尚未进入 contract；先补 contract 冻结再继续下游 |
| 2 | GW5A PLL 50→100 MHz、fractional scheduler、lock/reset replay 和独立 clock P&R 已有证据 | I2S 输出约束只在 Task 12 关闭；不能把 clock probe 当作全设计 timing |
| 2.5 | 独立 audio smoke top、testbench、48 kHz/I2S cadence 和 source-matched P&R 已通过 | 仍需最终 V2 top 的 I2S/板级波形和 package-pin gate |
| 3 | latch→calibration→validity 976 帧 replay、invalid/gap/saturation/epoch 语义通过 | `v2_input_calibration` 仍以组合 transform 为主；前端多周期/≤2 ns 目标未闭合 |
| 4 | 顶层使用 `v2_cursor_filter_timed`，cursor replay 和 clutch/rebase 通过 | 旧 cursor 综合为 14 DSP；没有默认 profile ≤4 DSP 的证据 |
| 5 | LIVE/LOOP 独立规则和 recorder、背压 vectors 通过 | LIVE candidate 仍含组合 qualification；没有完整前端 timing gate |
| 6 | 六轨双 bank、32 slots/track、recorder/store/scheduler RTL 与 GW5A DPB probe 通过 | 32-slot portable RTL 与 DPB-backed probe 已有独立证据；DPB wrapper 尚未接入最终 V2 top 的 full-path P&R |
| 7 | Potts Python/RTL standalone 与真实 recorder contour top regression 通过；含 backtrace、后台进度和 boundary timeout/pending policy | 默认 top 仍为 `USE_POTTS=0`，非空 rest-mask、full-path timing 和 board evidence 未完成 |
| 8 | 32-slot、双振荡器、256-bit DPB bank、release/revoice、确定性 voice-steal、bounded release、vibrato 和诊断计数已实现；Python/RTL/DPB replay 通过 | 当前源码的 100 MHz P&R 仍待 Gowin CLI 恢复可复现输出；旧独立 P&R 数值不作当前证据 |
| 8.5 | 独立 N-tone RTL、ModelSim capture、纯 Python 频谱检查和 standalone synthesis 已通过 N=1/2/4/8/16/32；A0 已接入 top CSR/I2S smoke | 可以称独立测试模式专项通过；最终 top 的资源、板级 CSR/telemetry 和 full-path P&R 仍开放 |
| 9 | wavetable/reduced FX standalone RTL、ModelSim 和资源 probe 存在 | loader 的实际选择只有 table/bank/index/CRC 语义，没有 band/octave selector；最终 top 未实例化 loader/patch bank，FX 固定关闭 |
| 10 | UART parser、CRC、duplicate、backpressure、双缓冲 snapshot 专项通过 | top 将 `tlm_frame_ready` 固定为 0，serializer 未被 TX 消费；CSR application、物理 1 Mbaud/115200 和板级回传未完成 |
| 11 | PC model/UI、fake transport、upload builder 和离线测试通过 | 不包含真实串口、板级 telemetry 或 I2S |
| 12 | 独立 top 仿真通过；结构 timing probe 曾到 100.453 MHz | 当前 P&R 是 probe/stub/关闭 Potts/关闭 FX 路径；full-path timing、I2S、telemetry、latency、board gate 未通过 |

最近可复现的专项验证：`python -m unittest tools.test_v2_contract tools.test_v2_potts_reference tools.test_v2_voice_vectors tools.test_v2_patch_vectors -v` 通过 25 项；`scripts/test_v2_top.ps1` 仿真通过。两者都不关闭最终顶层 gate。

## 文件与职责地图

### 新建文件

- docs/v2-fpga-contract-2026-10-25.md：V2 模式、事件、CSR、UART、遥测、时钟和错误语义唯一规范。
- docs/v2-validation-report-2026-10-25.md：仿真、综合、P&R、板级和延迟/频谱证据。
- rtl/v2_contract_pkg.sv：类型、枚举、事件位宽、CSR 地址和错误码。
- rtl/v2_clock_gen.sv、rtl/v2_sample_scheduler.sv：100 MHz PLL 封装和 48 kHz 分数 sample_ce。
- rtl/v2_input_calibration.sv、rtl/v2_position_validity.sv、rtl/v2_cursor_filter.sv：输入固定点链路。
- rtl/v2_live_rule_engine.sv、rtl/v2_loop_event_recorder.sv、rtl/v2_potts_commit_fsm.sv：LIVE、录制和提交精修。
- rtl/v2_voice_engine_mux.sv、rtl/v2_wavetable_loader.sv、rtl/v2_fx_lite.sv：声部、波表和有限 FX。
- rtl/v2_test_mode.sv：独立 N-tone 频谱可观测测试模式，不进入默认演奏路径。
- rtl/v2_uart_link.sv、rtl/v2_telemetry_snapshot.sv、rtl/mgc3130_v2_top.sv：单一 V2 控制/遥测链路和最终顶层。
- tools/v2_contract.py、tools/test_v2_contract.py、tools/v2_fixed_reference.py、tools/test_v2_fixed_reference.py：协议和逐帧/逐样本黄金参考。
- pc_receiver/fpga_v2_model.py、pc_receiver/fpga_v2_ui.py：参数、遥测和轨迹显示。
- sim/tb_v2_*.sv、scripts/test_v2_*.ps1、scripts/synth_v2_top.tcl、scripts/measure_v2_latency.ps1：分模块和顶层验证。
- Task 2.5 的 `rtl/v2_audio_smoke_top.sv`、`sim/tb_v2_audio_smoke.sv`、`scripts/test_v2_audio_smoke.ps1`，以及 Task 8.5 的 `sim/tb_v2_test_mode.sv`、`scripts/test_v2_test_mode.ps1`、`tools/test_v2_spectrum.py`。

### 允许修改的现有文件

- rtl/mgc3130_input_latch.sv：只增加 V2 所需有效帧/序列/时间戳输出，保持 V1 端口兼容。
- rtl/i2s_pcm5102a_tx.sv：仅在 V2 接线确认后增加明确 sample_ce/跨时钟端口，不改变 V1 实例行为。
- 新增独立 V2 工程清单和 mgc3130_v2.sdc；不删除旧源文件。
- docs/README.md：增加本计划和 V2 contract 入口。

---

## Task 1：冻结 V2 contract、模式边界和统一地址空间

**Files**
- Create: docs/v2-fpga-contract-2026-10-25.md
- Create: rtl/v2_contract_pkg.sv
- Create: tools/v2_contract.py
- Create: tools/test_v2_contract.py
- Modify: docs/README.md

**Interfaces**
- 当前 `v2_contract_pkg.sv` 导出 v2_mode_e、96-bit `v2_event_t`、v2_cmd_t、v2_telemetry_t、CSR/error constants 以及 vibrato parameter ranges；`0xA0–0xAF` 和 `TEST_SELECT` 的通用 selector 布局已经存在。voice-steal policy/counters、N-tone selector 的具体语义和 wavetable band selector 仍是本修订新增的待冻结字段。
- tools/v2_contract.py 导出 encode_control(op,address,data,seq)、decode_control(frame)、encode_event(event)、encode_telemetry(snapshot)、crc16_ccitt(data)。
- 事件固定字段：type[3:0]、track[2:0]、tick[7:0]、duration[7:0]、note[7:0]、velocity[7:0]、pitch_mod[15:0]、timbre_mod[15:0]、flags[7:0]、sequence[15:0]，显式断言总宽度 96 位。
- 控制包：SOF 0xA5、version 0x02、op、address、sequence、data 32 bit、CRC16-CCITT；固定 11 字节。遥测包固定 22 字节：SOF 0x5A、version、type、sequence、x/y/z、note、flags、tick、voice_bitmap、fifo_level、fault_code、CRC16。
- 当前地址已冻结为 0x00–0x44 legacy Loop、0x48–0x5C patch/gesture、0x60–0x7C wavetable/APPLY、0x80–0x9C telemetry/diagnostics、0xA0–0xAF test mode；其余拒绝。当前 `WT_SELECT` 只有 table/bank 语义，band 语义和 test selectors 仍待扩展。
- 只有 v2_uart_link.sv 监听 V2 uart_rx；旧顶层不连接 V2 UART。

**Steps**
- [ ] 写 CRC、端序、11 字节控制包、22 字节遥测包、地址拒绝和 round-trip 的失败测试。
- [ ] 运行 python -m unittest tools.test_v2_contract -v，确认失败信息对应缺失函数。
- [ ] 实现 serializer、显式掩码、CRC 和文档地址表；x/y/z 与 pitch_mod 使用二补码。
- [ ] 已完成现有宽度/长度/地址断言和 Python/SV codec 对照；继续工作时补冻结 32-slot capacity、voice-steal priority/counters、N-tone selector、vibrato readback 和 wavetable band selector。
- [ ] 运行 Python 和 SV 测试并记录命令。
- [ ] 提交 docs: freeze v2 fpga contract and protocol。

**Stop gate:** 后续 RTL 不得引入第二种事件布局、UART 包、遥测长度或 CSR 地址。

### Task 1 contract increment frozen 2026-10-27

The contract now freezes the remaining cross-task widths and selectors. Loop
storage is two banks × six tracks × 32 slots, with five-bit slot addresses and
six-bit per-track counts. Voice allocation is 32 voices × two oscillators with a
16-bit monotonic steal counter and the priority released → oldest → lowest
velocity → lowest voice ID. `TEST_SELECT_0` selector 1 is the N-tone mode (1–32,
default 8), selector 2 is vibrato readback, and `WT_SELECT` adds band[11:9] and
octave[15:12] while retaining table_id[2:0]/bank[8]. The vibrato readback word
uses phase[15:0] and signed delta_cents[31:16]. Python and SystemVerilog tests
cover the new constants, masks, selector codec, and cross-language parity.

- [x] Freeze 32-slot/track capacity, slot/count widths, and total bank capacity.
- [x] Freeze voice-steal priority and 16-bit allocation counter.
- [x] Freeze N-tone selector/count range and vibrato readback selector/layout.
- [x] Freeze wavetable band/octave selector packing and write mask.
- [x] Run Python and ModelSim contract tests, including mutation checks.

---

## Task 2：闭合 100 MHz 时钟和 48 kHz 音频时序

**Files**
- Create: rtl/v2_clock_gen.sv、rtl/v2_sample_scheduler.sv、sim/tb_v2_sample_scheduler.sv、scripts/synth_v2_clock.tcl、mgc3130_v2.sdc。

**Interfaces**
- v2_clock_gen(clk_in,rst_n,clk_sys_100m,pll_locked)。
- v2_sample_scheduler(clk_sys,rst_n,sample_ce,sample_index)。
- scheduler 用 32 bit 相位累加器，加入 48,000、与 100,000,000 比较并减回，产生 2083/2084 周期交替，长期平均精确 48 kHz。
- sample_ce 是唯一音频速率使能，禁止第二个自由运行 audio clock。

**Steps**
- [ ] Testbench 统计一秒内 48,000 个 sample_ce、校验总周期和 2083/2084 间隔。
- [ ] 先运行 scripts/test_v2_sample_scheduler.ps1 使测试失败，再实现。
- [ ] PLL 使用 Gowin 原语，V2_SIM 下旁路；实现 scheduler。
- [ ] 独立综合并记录 PLL lock、Fmax、时钟名。
- [ ] 增加 100 MHz、I2S/BCLK 约束，运行 git diff --check。
- Task 2 实际可约束的端口只有 50 MHz 输入和 PLL 产生的 100 MHz 系统时钟；当前 SDC 只约束这两个真实时钟。I2S BCLK 是同步输出，须等 Task 12 的 V2 transmitter/top 端口存在后加入并验证输出时序约束；不得用虚拟异步 clock group 切断内部路径。Task 2 不宣称 I2S I/O 约束已完成。
- [ ] 提交 feat: add verified v2 clock and sample scheduler。

**Stop gate:** 没有综合报告和 scheduler 仿真通过，不能声称 48 kHz 或计算声部预算。

---

## Task 2.5：最早出声切片和 I2S 引脚冒烟验证

**Files**
- Create: rtl/v2_audio_smoke_top.sv、sim/tb_v2_audio_smoke.sv、scripts/test_v2_audio_smoke.ps1。
- Reuse: rtl/v2_clock_gen.sv、rtl/v2_sample_scheduler.sv、rtl/i2s_pcm5102a_tx.sv；只有端口不兼容时才修改 I2S wrapper，不能改变 V1 实例行为。
- Evidence: 独立 smoke synthesis/P&R log、I2S waveform capture 和 package-pin legality report。

**Interfaces**
- `v2_audio_smoke_top` 只连接 50 MHz input、PLL 100 MHz、`sample_ce`、一个固定频率正弦 DDS、I2S BCLK/LRCK/DIN 和 reset/lock diagnostics。
- 假事件只用于触发一个 oscillator；不连接 MGC3130、Loop、Potts 或 PC EventTable。
- smoke top 与最终 `mgc3130_v2_top` 保持独立，不能成为最终产品路径的替代品。

**Steps**
- [x] 写失败 testbench：检查 PLL lock/reset、48 kHz sample cadence、BCLK/LRCK 比率、固定正弦频率和 sample_ce 不丢失。
- [x] 运行 `scripts/test_v2_audio_smoke.ps1`，确认仿真先失败，再接入 smoke top。
- [x] 用 Gowin CLI 独立综合/P&R，检查 50 MHz 输入、100 MHz PLL 和实际 I2S 输出端口的时钟关系。
- [x] 检查 `.cst` package pins 合法性；有板卡时捕获 DAC 端 BCLK/LRCK/DIN 和正弦波形。
- [x] 记录该切片的 Fmax、I/O、PLL、I2S 分频、波形截图和限制；不得把 smoke 结果填入最终 full-path acceptance 表。

**Stop gate:** 仿真、综合/P&R 和 package-pin 检查通过后，才能把 I2S 通路标记为可供 Task 12 使用。没有板级捕获时，只能关闭仿真/I/O 约束 gate，不能声称 DAC 已经出声。由于 Task 3–5 的专项 RTL 证据已经存在，本任务是当前计划的回填 gate；不要求为了历史顺序重做已经通过的输入、cursor 和规则 vectors。

### Task 2.5 回填证据 — 2026-10-27

`scripts/test_v2_audio_smoke.ps1` 的新鲜 ModelSim 回归通过：`tb_v2_audio_smoke PASS`，
479 个 sample cadence 检查点、I2S 30,720 个 BCLK 边沿和 480 个 LRCK 上升沿均满足断言。
独立 Gowin CLI P&R 产物位于 `impl/v2_audio_smoke_20261027/`，顶层为
`v2_audio_smoke_top`，器件为 `GW5A-LV25MG121NES`。E1 约束为当前器件可达 PLLA
输入，报告记录 50 MHz 输入经 PLLA 生成 100 MHz 时钟，实际 Fmax 137.296 MHz；
setup/hold 违规端点均为 0，setup/hold TNS 均为 0.000 ns，最坏 setup slack
+2.716 ns。资源为 187 logic（156 LUT、31 ALU）、126 FF、5 I/O 和 1/6 PLLA，
五个端口的 package-pin report 均标记为 constrained/合法。bitstream
`impl/v2_audio_smoke_20261027/impl/pnr/v2_audio_smoke.fs` 的 SHA-256 为
`4641A8C3C1CF28AD62B1C95C59753D3BD56B2BA7F862563A0F5CF9F5D8936A24`。

此前用板级标注的 E2 作为 `clk_50m` 时，Gowin 报告 `PR2028 constrained location is
useless` 和 `PR2017 clk_50m cannot be placed ... dedicated pin (CPU/SSPI)`，因此
不能把 E2 版本当作可达 P&R 证据。当前 `.cst` 保留 E1，并在注释中记录 E2
板级分配仍待解决。没有板级捕获，所以本切片关闭的是仿真、I/O 约束和 P&R gate，
不宣称 DAC 已在板上出声；该结果也不进入最终 V2 full-path acceptance 表。

---

## Task 3：实现 FPGA 输入有效性、校准和固定点坐标语义

**Files**
- Create: rtl/v2_input_calibration.sv、rtl/v2_position_validity.sv、sim/tb_v2_input_validity.sv。
- Modify: rtl/mgc3130_input_latch.sv。

**Interfaces**
- v2_input_frame_t：sequence、timestamp_ticks、signed raw x/y/z、touch、presence、valid_xyz、saturated、gap、calibration_epoch。
- 校准顺序固定为 raw sign extension → validity/saturation → neutral offset → z coupling subtraction → gain → workspace clamp → output validity。
- validity 输出 frame_valid、lost、degraded、gap_count、calibration_reason；无效/饱和位置永远不能进入音符生成。
- 当前校准/validity 功能按固定顺序输出并已有 replay；下一轮时序修订才要求把 sign/offset/coupling/gain/clamp 拆为多周期流水线或 FSM。当前 `v2_input_calibration` 的组合 transform 不得作为已满足 ≤2 ns 的证据。

**Steps**
- [ ] 用 neutral、depth、workspace、invalid、saturation、gap 采集生成 tools/testdata/v2_input。
- [ ] 为符号扩展、钳位顺序、gap、epoch 变化写 Python/SV 失败测试。
- [ ] 实现 shadow/active profile，固定点乘法、舍入、饱和和原因位。
- [ ] 与 tools/v2_fixed_reference.py 逐帧比对，要求整数结果和原因位全相等。
- [ ] 综合算术块，记录 LUT/FF/DSP；报告每级组合路径，默认目标为 ≤2 ns，并确认前端没有跨到 audio sample path 的长组合路径。
- [ ] 提交 feat: add v2 fixed point input calibration and validity。

**Current gate:** invalid、lost 或 saturated 帧不能创建音符或改变 pitch 状态，976 帧 replay 已覆盖。**Final gate:** 前端流水线达到目标吞吐，且无未寄存的长校准路径。

---

## Task 4：实现光标滤波、Z clutch/rebase 和 golden vectors

**Files**
- Create: rtl/v2_cursor_filter.sv、sim/tb_v2_cursor_filter.sv、tools/v2_cursor_reference.py、tools/test_v2_cursor_reference.py。

**Interfaces**
- 输入有效校准帧和 alpha_low=0.12、alpha_high=1.0、z_engage=30000、z_release=36000、max_step_q16、settle_ticks。
- 输出绝对 cursor x/y/z、normalized pitch、velocity/depth controls 和 DISENGAGED/ENGAGED/REBASED/DEGRADED。
- 冻结区隐藏 anchor；离开时第一帧设为新 anchor，输出零位移；REBASED 只保持一帧。
- filter 在输入帧率采样；audio sample_ce 只消费最新稳定 control point，不改变时间戳和 Loop tick。
- 当前顶层使用 `v2_cursor_filter_timed` 的多周期 FSM；旧 `v2_cursor_filter` 仍保留为 bit-exact reference。cursor 输出通过稳定快照进入音频域，不把旧单周期实现当作最终时序证据。

**Steps**
- [ ] 写左边缘接合、高 Z 冻结/恢复、invalid gap、slew 饱和和纯 Z 向量。
- [ ] 先写失败测试：rebase 无跳变、纯 Z 无 pitch 改变、每帧位移不超限。
- [ ] 实现 5 点中值、IIR、slew 和 anchor-relative clutch 固定点版本。
- [ ] RTL 复现状态机，输出一帧 REBASED；workspace range 的除法使用常量倒数乘法或共享多周期算术，不在每个路径推断独立 divider。
- [ ] Python/RTL 逐帧比较并综合；默认 profile 目标 ≤4 DSP，可配置 workspace profile 单独报告资源；目标为单级组合路径 ≤2 ns，记录 DSP/LUT/FF/Fmax 和 Python 误差上界，不能以单周期组合实现换取低延迟。
- [ ] 提交 feat: add v2 cursor filter with clutch rebase。

**Current gate:** cursor replay、纯 Z invariant、clutch/rebase 已通过。**Final gate:** 默认 profile ≤4 DSP、前端流水线不能成为 audio sample critical path，且 P&R 报告不得出现未规划的长组合路径。

---

## Task 5：实现独立 LIVE 和 LOOP 规则引擎

**Files**
- Create: rtl/v2_live_rule_engine.sv、rtl/v2_loop_event_recorder.sv、sim/tb_v2_live_rule_engine.sv、sim/tb_v2_loop_event_recorder.sv、tools/v2_rule_reference.py、tools/test_v2_rule_reference.py。

**Interfaces**
- LIVE 输出 note_on、note_off、note_revoice、control-only；左边缘 arm、音级滞回、最小 4 tick。
- gate 可选 touch/bow；X 边缘穿越可以同音 revoice；Z 只改 velocity/brightness/gain；纯 Z 无 note event。
- LOOP 记录六轨、monotonic tick、duration、velocity、control flags；LIVE FIFO 与 LOOP write FIFO 独立。
- 两个 FSM 各自暴露 fault_code、event_count、left_edge_armed、gate_state。
- 当前 LIVE/LOOP 使用独立状态机、ready/valid 和 recorder holding register；LIVE 仍有组合 candidate qualification。下一轮必须补规则输出的寄存器/FIFO 边界和 bounded latency 证据。

**Steps**
- [ ] 为左到右、反向拒绝、边缘最终右移点、纯 Z、touch split、bow reversal、同音 revoice、invalid gap、轨道独立写 vectors。
- [ ] 为 tick 顺序、4 tick 间隔、边缘条件和 FIFO 背压写失败测试。
- [ ] 实现两个显式 FSM，不用隐式共享 mode；为 200 Hz 输入定义 bounded latency、FIFO 深度和背压行为。
- [ ] 运行 reference/RTL 对照和六轨写接口的背压/overflow/abort/boundary 验证；实际六轨 store 在 Task 6 创建，其 recorder/store 联合回归必须在 Task 6 关卡关闭前通过。
- [ ] 提交 feat: add v2 live and loop rule engines。

**Current gate:** LIVE/LOOP 功能 vectors 和六轨 recorder 专项通过。**Final gate:** 前端模块和音频域之间没有未寄存的长组合路径，并由真实 full-path P&R 证明。

---

## Task 6：升级 Loop 存储、调度器和边界事务

**As-built status:** 当前 V2 recorder/store/scheduler 接口统一为两 bank、六轨、每轨 32 slots，slot/read index 为 5 bit，count 为 6 bit，scheduler 以 slot 31 为扫描边界。portable `v2_loop_event_store` 用于 RTL 回归；`v2_loop_event_store_dpb` 提供六 lane GW5A DPB 实现并已完成独立物理 probe，且已选入 `mgc3130_v2_top`。顶层 DPB 选择已有 ModelSim 回归，但 Task 12 仍需重新验证顶层资源、时序和板级路径。

**Files**
- Create: rtl/v2_loop_event_store.sv、rtl/v2_loop_scheduler.sv、sim/tb_v2_loop_transactions.sv。
- Modify only through V2 wrapper: rtl/loop_event_ram.sv.
- Update docs/loop-event-store-interface.md、docs/loop-scheduler-interface.md、docs/loop-control-plane-interface.md。

**Interfaces**
- 两 bank、六轨、每轨 32 event slots、96-bit v2_event_t；逻辑 loop 为 128 ticks。每轨计数使用足以表示 0..32 的位宽，旧 16-slot store 只作为 V1/历史 probe。
- PREPARE_RECORD、PREPARE_OVERDUB、COMMIT、ABORT、STOP、CLEAR_TRACK、CLEAR_ALL 均有 accepted/busy/done/fault。
- commit：freeze shadow → drain record FIFO → wait boundary → swap bank → publish counts；同拍请求等下一个 boundary。
- scheduler valid/ready；boundary 先 ALL_NOTES_OFF；背压时不跳 tick。
- 满轨 ERR_TRACK_OVERFLOW 且保留 active；空录音 abort。

当前实现的 `record_count` 是六路 6-bit count 拼接成 36 bit，可表达 0..32；copy boundary 为 192 个槽，slot/read index 为 5 bit。recorder/store hand-off、overflow 和 scheduler 扫描必须保持这些宽度一致，不能回退到旧 16-slot 假设。

**Steps**
- [x] 更新 V2 contract 的容量、计数位宽和 96-bit RAM lane mapping，定义六轨地址计算；不得只改 RAM 深度而保留旧 16-slot 计数或扫描边界。
- [x] 为首录、叠录保留、满轨、空 abort、STOP boundary、commit 背压、active 保留写失败测试。
- [x] 通过 wrapper 实现 V2，不改变 V1。
- [x] 运行 RTL RAM、Gowin DPB model 和独立综合，记录 BSRAM/scan cycles；容量和 BSRAM 占用必须以新的 P&R 报告为准，不使用百分比估算。
- [x] 接入 Task 5 recorder，运行实际六轨 store 联合回归，包括背压、overflow、abort、boundary 和 active bank 保留；接口模型测试不能代替此项。
- [x] 更新三份接口文档，明确 V1 与 V2 状态。
- [ ] 提交 feat: add v2 six track loop transactions。

**Stop gate:** V2 top 不得使用旧四轨事件宽度、16-slot/track 或 96-slot scan 假设；32-slot/track 的满轨、背压和 active-bank 保留必须通过真实 recorder/store/scheduler 联合回归。

### Task 6 回填证据 — 2026-10-27

`powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_loop_transactions.ps1`
现在运行三组新鲜回归：portable `v2_loop_event_recorder`、portable
recorder→store→scheduler transaction，以及 GW5A `prim_sim.v` 上的
`v2_loop_event_store_dpb`。三组均报告 PASS。回归覆盖 32 个事件的满轨写入、
第 33 次写入的 track overflow、slot 31 读回/调度、scheduler 背压保持、
COMMIT boundary、PREPARE_RECORD copy、ABORT 和 active-bank 保留；recorder 的
`track_event_count` 为 6 bit，store `record_count` 为 36 bit。

`rtl/v2_loop_event_store.sv` 是 portable RTL fallback，使用扁平化
bank/track/slot 地址；`rtl/v2_loop_event_store_dpb.sv` 是物理存储 wrapper，
六个 16-bit DPB lane 组成 96-bit event。独立 probe
`impl/v2_loop_transactions_probe_20261027/` 由
`scripts/synth_v2_loop_transactions_probe.tcl` 复现，器件为
`GW5A-LV25MG121NES`，100 MHz `clk_sys_100m` 约束下实际 Fmax **109.898 MHz**，
setup/hold 违规端点 **0/0**，TNS **0.000/0.000 ns**，最坏 setup slack
**+0.901 ns**。资源为 **889 logic**、**317 logic FF**、**6 DPB/BSRAM**、
**15 I/O**；bitstream
`impl/v2_loop_transactions_probe_20261027/impl/pnr/v2_loop_transactions_probe.fs`
的 SHA-256 为
`776BF548924AA33B8B80B4CFE79C45DD559B197AB57FF6F21BA258E8DDC05C2F`。

该 P&R probe 只保留 loop storage/scheduler 物理平面并使用紧凑诊断端口；
recorder/store hand-off 的完整行为由上述 portable/DPB ModelSim 联合回归覆盖。
DPB wrapper 已接入最终 V2 top 的 RTL 仿真路径，但尚未完成 full-path P&R，
因此这组结果关闭的是 Task 6 的容量、接口和独立物理存储 gate，不关闭 Task 12 的最终顶层、I2S、
UART、telemetry、FX 或板级验收。

---

## Task 7：实现固定点 Potts COMMIT FSM 并测量后台预算

**As-built status:** `v2_potts_commit_fsm` 已有独立 Python/RTL vectors；`mgc3130_v2_top` 从 recorder 的 NOTE_ON holding register 捕获 128-tick lead contour，并在 COMMIT 时把该快照送入 FSM。新增的 `scripts/test_v2_top_potts.ps1` 用 8 个递增 tick 的真实 recorder 写入驱动顶层 Potts，测得 `busy_cycles=1,868,573`（同一 RTL/仿真时钟域）、`backtrace_valid=1`、`overflow=0`、`event_count=1`，并确认 store bank publication 仍等待显式 loop boundary。该回归还在 Potts busy 期间发出 READ 状态帧并验证 `sample_index` 继续前进。`potts_rest_mask` 仍是显式空 mask，默认 `USE_POTTS=0`，因此这关闭的是顶层真实 contour/后台预算仿真 gate，不是最终 Potts full-path P&R gate。

The DPB and portable V2 stores now share an explicit boundary timeout. The
default is 3,400,000,000 `clk_sys_100m` cycles (34 seconds); a timeout clears
only the pending shadow metadata, retains the active bank, leaves
`commit_ack=0`, and latches `commit_timeout` plus `commit_wait_cycles`. ABORT
clears the pending request and diagnostics. `scripts/test_v2_loop_store_timeout.ps1`
uses an eight-cycle override to verify timeout, active-bank retention, and a
subsequent successful boundary commit. `scripts/test_v2_top_commit_timeout.ps1`
repeats the policy through the real top and checks that the 48 kHz scheduler is
not stopped while the request waits.

**Files**
- Create: rtl/v2_potts_commit_fsm.sv、sim/tb_v2_potts_commit.sv、tools/v2_potts_reference.py、tools/test_v2_potts_reference.py、scripts/measure_v2_potts.ps1、sim/tb_v2_loop_store_timeout.sv、scripts/test_v2_loop_store_timeout.ps1、sim/tb_mgc3130_v2_top_commit_timeout.sv、scripts/test_v2_top_commit_timeout.ps1。

**Interfaces**
- 输入 128-tick lead contour、固定 A minor pentatonic、lambda_q16、最小 4 tick 和 rest mask。
- state 为 cost[tick][degree][length_class]，有限宽度饱和和 backpointer RAM；暴露 busy/progress/done/overflow/backtrace_valid。
- 输出六轨兼容 lead event list；rest 无事件，gap 前最后有效转折保留。
- tie-break 固定为 cost 更低、段更长、degree 更低。

**Steps**
- [x] Python fixed-point reference 和 exhaustive small-grid tests。
- [x] RTL vectors 覆盖全 rest、单音、tie、min length、饱和。
- [ ] BRAM ping-pong rows、one-cell/cycle candidate、backtrace 和 event FIFO。
- [x] 用真实六轨 Loop 的 lead contour 驱动 FSM；禁止用全零 contour、常量 rest mask 或不可达启动信号作为最终证据。
- [x] 在仿真时钟域测量真实 contour 的 busy 时长、backtrace 和 bank-swap pending；当前记录为 1,868,573 个系统周期，尚未换算成 100 MHz 硬件预算。
- [ ] 在 100 MHz P&R/板级条件下复测 worst-case cycle count、busy 时长、backtrace 时长和 bank-swap pending 时长；记录 boundary timeout 值和超时后的 active-bank 保留策略。历史 41 µs 只保留为估算背景，不是阈值。
- [x] RTL 顶层回归验证 COMMIT/Potts 不阻塞 `sample_ce` 或只读 UART 状态查询；store timeout 保留 active bank 并清除 shadow pending。最终 P&R/板级和写入侧 BUSY/NACK 仍属于 Task 10/12。
- [ ] 提交 feat: add measured v2 fixed point potts commit。

**Stop gate:** RTL 与 Python 在真实 contour 上逐事件一致；最坏 cycle count、boundary timeout、pending policy 和 active-bank 保留均有日志；在这些证据完成前只能称为“Potts 功能专项通过”，不能称为“全局精修已接入”或“41 µs 已成立”。

---

## Task 8：构建并验证 32 声部、64 振荡器时分复用引擎

**As-built status (2026-10-28):** `v2_voice_engine_banked` 已实现 32 slot、双 oscillator、256-bit/16-lane DPB state bank、release/revoice、确定性 voice-steal、bounded steal-release 和 UQ8.8 vibrato。满载 NOTE_ON 按 released → oldest → lowest velocity → lowest voice ID 选择 victim，使用单项 mailbox 延迟复用，并提供 `voice_steal_count` 与 vibrato readback。当前源码的 portable/DPB replay 和基础 RTL gate 已通过；本次新增逻辑后的 Gowin CLI P&R 仍返回 code 1 且无 Tcl 输出，因此旧的 2026-10-26 P&R 数值不能作为当前源码证据，Task 8 的 100 MHz P&R stop gate 继续开放。

**Files**
- Create: rtl/v2_voice_engine_mux.sv、rtl/v2_note_increment_rom.sv、sim/tb_v2_voice_engine.sv、tools/test_v2_voice_vectors.py、scripts/synth_v2_voice_engine.tcl。

**Interfaces**
- 32 slots、每 slot 两 oscillator、phase Q0.32、envelope Q1.15、velocity/timbre/track/note/active。
- valid/ready 接收 NOTE_ON/OFF/REVOICE；返回 active_bitmap[31:0]、voice_overflow、voice_steal_count、revoice_count、mixed_sample，并提供 vibrato phase/delta readback。
- free slot first；全满时按 released → oldest → lowest velocity → lowest voice_id 抢占；被抢占声部经过 bounded steal-release 后再复用，不能瞬时清零；若 contract 禁止抢占才报告 overflow 且保留已有声部。revoice 保持 phase，通过 bounded glide 改 increment。
- 每个声部有固定点 vibrato LFO phase/rate/depth；`VIBRATO_HZ`/`VIBRATO_CENTS` 遵循 V2 contract 的 UQ8.8 范围，vibrato 只调制 oscillator increment，不生成 NOTE_ON/OFF 或音高事件。
- A/B/C 共享 1024×16 表，显式饱和；cycle budget 包含 BRAM read latency、包络、乘法和累加。

**Steps**
- [x] vectors 覆盖 1、8、32 note、33rd voice-steal、release-priority、oldest/lowest-velocity tie-break、bounded steal-release、revoice phase、ADSR、detune、vibrato、saturation。
- [x] 先跑 Python fixed-point voice reference。
- [x] 实现 voice state RAM、vibrato LFO state 和 round-robin microsequencer，禁止推断 32 条并行 pipeline；记录 voice steal/overflow 的诊断计数。
- [x] RTL 频率/peak 和 1 LSB sample compare。
- [ ] 100 MHz 综合/P&R，记录 LUT/FF/BSRAM/DSP/Fmax/slack/cycles/sample。
- [ ] 提交 feat: add verified v2 voice engine。

**Stop gate:** 32 simultaneous notes、33rd deterministic voice-steal、平滑抢占、双振荡器 sample compare、vibrato vectors 和独立 voice P&R timing 全通过，才接受“32 voices × 2 oscillators”专项结论；最终 top 仍必须重新验证该路径。

---

## Task 8.5：独立 N-tone 频谱测试模式

**As-built status (2026-10-28):** 已新增独立 `rtl/v2_test_mode.sv`、`sim/tb_v2_test_mode.sv`、`scripts/test_v2_test_mode.ps1` 和 `tools/test_v2_spectrum.py`。模块只响应 `TEST_SELECT_0` 的 selector 1，生成 220 Hz × k 的 1–32 个固定 DDS 正弦声部，关闭 FX、vibrato、包络和 EventTable 输入；写入 count=0 停止并清零 phase。ModelSim capture 与无第三方 FFT 依赖的 Python 频率检查覆盖 N=1、2、4、8、16、32，重复 selector、phase reset、停止和非法 count fault。`mgc3130_v2_top` 现已把 A0 写入/读回接到该模块，并在 test_active 时旁路 FX 将样本送到 I2S；top smoke 还确认不会分配 voice。该模块的 standalone synthesis 已有独立资源报告，但最终 top 资源、telemetry readback、板级路径和 full-path P&R 仍开放。

**Files**
- Create: rtl/v2_test_mode.sv、sim/tb_v2_test_mode.sv、scripts/test_v2_test_mode.ps1、tools/test_v2_spectrum.py、sim/v2_test_mode_synth_probe.sv、scripts/synth_v2_test_mode.tcl、mgc3130_v2_test_mode.sdc、docs/v2-test-mode-synthesis-2026-10-28.md。
- Update: docs/v2-fpga-contract-2026-10-25.md with selectors `0xA0–0xAF` and readback/telemetry semantics.

**Interfaces**
- test mode 由独立 CSR 选择 N=1..32 个纯正弦 voice slots，频率固定为 `220 Hz × k`，关闭 FX、vibrato 和 envelope modulation，只用于观测。
- test mode 不接收 PC EventTable，不改变默认 LIVE/LOOP 状态机，不写 active Loop。
- 输出 active test bitmap、expected frequency table、sample counter 和 fault 状态，供 UART/内部 sample capture 使用。

**Steps**
- [x] 为 N=1、8、16、32 和重复 selector 写 RTL vectors，检查每个频率、phase reset 和停止行为。
- [x] 运行 `scripts/test_v2_test_mode.ps1`，导出固定窗口的内部样本并完成频率检查。
- [x] 用 `tools/test_v2_spectrum.py` 做 4096-sample Hann-window radix-2 FFT 和固定窗口频率投影检查，验证独立峰数量、频率误差和 sideband ratio ≤ 0.02；记录 48 kHz 采样率、±10 Hz 峰值搜索和幅度阈值 1.0。
- [x] 综合测试模式并记录其资源；top smoke 确认 test mode 不分配 voice，默认 LIVE/LOOP 路径回归通过。

**Stop gate:** N-tone 仿真和频谱报告通过后，Task 12 才能使用测试模式作为 32-slot 可观测性证据；它不能替代真实 LIVE/LOOP 声音链路。

---

## Task 9：加入波表上传、Patch 语义和资源受限 FX

**As-built status:** `v2_wavetable_loader` 和 `v2_fx_lite` 已有 standalone RTL/仿真/资源 probe。loader 当前实现 table/bank/sample index、shadow/active、CRC/APPLY 语义，没有 band/octave selector；`mgc3130_v2_top` 没有实例化 loader 或 patch shadow/active 路径，FX 实例被 `fx_enable=0`、`fx_level=0` 常量关闭。因此 standalone reduced-FX 通过不能关闭 Task 9 的 full-path gate。

**Files**
- Create: rtl/v2_wavetable_loader.sv、rtl/v2_fx_lite.sv、sim/tb_v2_wavetable_fx.sv、tools/test_v2_patch_vectors.py。
- Update docs/v2-fpga-contract-2026-10-25.md。

**Interfaces**
- 目标接口：A/B/C 表上传含 table ID、band/octave selector、block、16-bit samples、version、CRC16；只写 shadow BRAM，暴露 busy/crc_ok/crc_error/active_version。当前 loader 只有 table/bank/index 语义，band/octave selector 需要先冻结并实现。任意用户波表必须能选择与音高匹配的带限表，不能默认把全带宽 32 次谐波表用于所有音区。
- APPLY 只在 Loop boundary 或 idle 原子切换；CRC 失败保留 active。
- Patch 固定 oscillator mix、brightness、detune、ADSR、glide、vibrato、Z→gain/brightness/space、track enable，所有 Q 格式/钳位写入 contract。
- FX 顺序 gain → one-pole low-pass → delay → one-comb reverb；chorus 只有 P&R 留有余量时启用。默认验收等级为启用的 reduced FX（gain + low-pass + delay + one-comb）；`V2_FX_LEVEL` 和 telemetry 必须报告实际等级，不能以 `fx_enable=0` 或 `fx_level=0` 作为最终证据。
- FX 不能访问 raw input，也不能改变 pitch/timing。
- 抗混叠策略优先使用按频段/八度的 band-limited wavetable；polyBLEP 只作为基础 saw/square 等明确定义波形的可选模式，不能宣称它自动修复任意上传波表。

**Steps**
- [ ] 写 upload/CRC/rollback、band selector、patch clamp 和纯 Z invariant tests；覆盖高音区表选择及 Nyquist 边界。
- [ ] 实现 shadow BRAM 与 boundary APPLY。
- [ ] 实现固定点 gain/filter/delay/comb、反馈限制和饱和。
- [ ] 先综合 full FX，失败则 reduced FX，并记录原因。
- [ ] 跑频响、脉冲响应、Nyquist 边界、高音谐波衰减和 Z 表达测试。
- [ ] 提交 feat: add v2 wavetable patch and bounded fx。

**Stop gate:** reduced FX 在真实 voice/I2S 样本路径中非零启用，频响、脉冲响应、固定延迟、反馈饱和和 underrun 证据通过；FX 不能改变输入事件、Loop tick、voice pitch/timing 或 I2S sample cadence。报告必须写明最终等级和资源。

### Task 9 continuation checkpoint — 2026-10-28

新增 `scripts/test_v2_wavetable_fx.ps1` 与 `scripts/test_v2_patch_bank.ps1`，
把现有 wavetable/FX 和 patch-bank testbench 变成可从当前 checkout 重跑的
专项 gate。两项 ModelSim 回归均通过，覆盖 incomplete-table/patch rejection、
CRC、idle/boundary APPLY、active readback、version increment、reduced-FX
非零状态和饱和路径。Task 9 的 standalone reduced-FX gate 已有可复现命令；
band/octave selector、最终 top 的非零 FX 接线、UART/CSR shadow/active 闭环、
频响/脉冲响应和板级 I2S evidence 仍是后续工作。

---

## Task 10：实现单一 UART/CSR 控制和无撕裂遥测

**As-built status:** `v2_uart_link` 的字节级 parser/CRC/duplicate/backpressure 和 `v2_telemetry_snapshot` 的双缓冲 serializer 有专项证据；`mgc3130_v2_top` 目前只接通基本 mode/track/record/overdub/clear/commit/stop 控制，patch/wavetable/telemetry CSR 仍未形成 shadow/active/APPLY/readback 闭环，且 `tlm_frame_ready` 固定为 0，遥测帧不会进入 UART TX。当前 TX 只有 command ACK/NACK 路径；最终实现还需要在唯一物理 TX 前增加 response/telemetry 仲裁和 ready/valid 回压。

**Files**
- Create: rtl/v2_uart_link.sv、rtl/v2_telemetry_snapshot.sv、sim/tb_v2_uart_link.sv、sim/tb_v2_telemetry.sv、scripts/test_v2_uart.ps1。
- Modify: docs/v2-fpga-contract-2026-10-25.md only for tested concrete mismatch.

**Interfaces**
- v2_uart_link 是唯一 V2 uart_rx 接口；解码 11-byte controls，返回带 seq/error 的 ACK/NACK，patch/wavetable/Loop 命令使用独立 FIFO。
- 默认 1,000,000 baud，同时实测 115,200 fallback；TX 阻塞不影响 sample_ce。
- telemetry snapshot 原子捕获 cursor、note、tick、bitmap、FIFO、latency、peak/RMS、fault，复制到 TX FIFO 后再更新字段；顶层必须在唯一物理 UART TX 前实现 ACK/NACK 与 telemetry 的仲裁，并把 serializer 的 `frame_valid/ready/byte/last` 接入该仲裁器，不能把 `frame_ready` 固定为 0。
- ACK 语义区分 shadow stored、CRC failure、timeout、overflow、bad address、busy、APPLY accepted。

**Steps**
- [ ] 测 bad CRC、duplicate seq、TX backpressure、shadow readback、boundary APPLY、telemetry tearing、两种 baud；同时证明顶层 telemetry frame 被 TX 消费且 UART 阻塞时音频不丢 sample_ce。
- [ ] 实现 RX parser、command FIFOs、ACK/NACK、timeout。
- [ ] 实现双缓冲 telemetry 和 22-byte serializer。
- [ ] 阻塞 TX 同时生成音频事件，确认 sample_ce 不丢。
- [ ] 提交 feat: add v2 uart control and telemetry。

**Stop gate:** PC UI 连接前必须通过字节级、背压和 snapshot tests；Task 12 关闭前还必须有顶层实际 TX 消费、CSR shadow/active/APPLY/readback 和物理 1 Mbaud/115200 证据。

---

## Task 11：构建 PC V2 参数和遥测 UI

**Files**
- Create: pc_receiver/fpga_v2_model.py、pc_receiver/fpga_v2_ui.py、tools/test_fpga_v2_model.py。
- Update docs/pc-ui-spec-2026-10-22.md with V2 appendix。

**Interfaces**
- fpga_v2_model.py 导出 V2Parameters、V2Telemetry、apply_patch_delta()、decode_telemetry(frame)、build_upload(table_id,samples,version) 和可替换 fake transport。
- 控件：LIVE/LOOP、BPM、gate、lambda/density、fixed scale、patch、ADSR、glide、vibrato、bend、Z gain/brightness/space、FX、A/B/C upload/APPLY。
- 显示：XY+Z color、note、tick、六轨、32 voice bitmap、FIFO、latency、peak/RMS、PLL/fault/CRC、active patch/table version。
- UI 明确 synthwave_loop.py 是 offline golden reference，不向 V2 发送 EventTable；串口线程只向 Tk queue 投递。

**Steps**
- [ ] 测参数钳位、packet bytes、telemetry decode、CRC failure、fake transport。
- [ ] 实现 model/transport，不在单测打开真实串口。
- [ ] 独立入口构建和销毁 Tk root 的 smoke test；不修改现有 UI 行为。
- [ ] 读取 telemetry log 并构造有效 wavetable APPLY sequence。
- [ ] 提交 feat: add v2 fpga parameter and telemetry ui。

**Stop gate:** UI 无硬件也能显示回放遥测并生成有效 APPLY 序列。

---

## Task 12：独立 V2 top、综合、板级和验收

**As-built status:** `rtl/mgc3130_v2_top.sv` 已存在，但当前参数化 top 默认 `USE_MGC_READER=0`、`USE_POTTS=0`，输入为 stub/idle，Potts contour 全零，FX 关闭，telemetry `frame_ready` 固定为 0。A0 N-tone 已接入 UART/I2S smoke，STATUS 读回也会反映已激活的 Loop bank；其余诊断/默认路径仍未达到最终验收。`scripts/test_v2_top.ps1` 的仿真因此只能证明 stub/default probe 路径；`scripts/synth_v2_top.tcl` 当前把 `v2_top_synth_probe` 设为综合 top，也不是最终 `mgc3130_v2_top` full-path P&R。下列步骤是把诊断 top 收敛为最终 top 的剩余工作。

**Files**
- Existing diagnostic artifacts: rtl/mgc3130_v2_top.sv、scripts/synth_v2_top.tcl、scripts/test_v2_top.ps1、sim/tb_mgc3130_v2_top.sv、docs/v2-validation-report-2026-10-25.md、mgc3130_v2.sdc；这些文件需要扩展或重写证据，不得把当前 probe/default 结果直接标为最终通过。
- Still missing for final gate: scripts/measure_v2_latency.ps1、impl/v2_top/README.md，以及真实 full-path P&R/board capture outputs。
- Update: separate V2 project manifest; do not replace old top.

**Interfaces**
- 顶层保留现有 MGC3130、UART、I2S、reset 和诊断 pin；约束从现有 `.cst` 复制后做显式 diff，并对每个 V2 package pin 运行合法性检查。`PR2028 constrained location is useless`、`PR2017 clk_50m cannot be placed according to constraint` 等约束错误必须为零。
- 固定顺序：input_latch → calibration/validity → cursor_filter → (live_rule || loop_recorder) → loop_store/scheduler → potts_commit → voice_engine_mux → fx_lite → i2s。
- v2_uart_link 是唯一 UART receiver；旧 command receiver 不实例化。
- 所有跨域队列、fault recovery、ALL_NOTES_OFF 在顶层可见并有 assertions。
- STOP 关闭 gate、flush event/audio queue、发送 ALL_NOTES_OFF、保留 active Loop；RESET 清诊断但不清 active music。

**Steps**
- [ ] 建独立 top 和仿真 MGC3130 source；断言不实例化 V1 top。
- [x] top smoke 断言 `frame_degraded`/`frame_gap` 真实连到 LIVE rule engine；主 top 仍需补 invalid/gap 行为向量。
- [ ] 顶层测试左到右 LIVE、纯 Z、invalid/gap、六轨 record/overdub/commit/play、STOP、CRC/APPLY、1/8/32 voice、33rd voice-steal、bounded steal-release、vibrato、N-tone test mode、I2S sample count、telemetry；LOOP commit 必须把真实 recorder contour 送入 Potts。
- [ ] V2 synthesis/P&R/timing 使用真实可达路径：valid input、实际 reader 或等价可达输入、LIVE/LOOP、real Potts、32×2 voice、非零 reduced FX、UART/telemetry 和 I2S 全部保留；记录 logic/FF/DSP/BSRAM/Fmax/slack/sample cycles/FIFO/FX level，并保存无 `NL0002 swept` 的日志。
- [ ] 结构 probe、stub、关闭 `USE_POTTS`、关闭 `PRESERVE_INPUT_VALID`、常量 contour、不可达 preserve net 只能放在诊断章节，不能填最终 P&R acceptance 表。
- [ ] 对实际 V2 I2S/BCLK 端口加入同步输出时序约束，检查端口路径、时钟关系和板级波形；不得把 Task 2 的系统时钟 SDC 当作完整 I2S I/O 约束。
- [ ] 独立 bitstream 板测：合法 package pins、参数帧、telemetry 实际回传、I2S/BCLK/LRCK/DIN 波形、无 underrun、GPIO trigger-to-waveform latency；没有板级波形时不得声称 I2S 或延迟已通过。
- [ ] 若真实 full-path P&R 在完成至少一轮前端多周期流水化修复后仍低于 100 MHz，才进入 fallback review：评估 80 MHz PLL、重新计算 sample scheduler、最多 24 voices、关闭 chorus，并重新执行仿真/综合/P&R/资源/延迟验证。80 MHz 是有证据的功能折中，不等价于 100 MHz 主验收通过。
- [ ] 运行 python -m unittest discover -s tools -p 'test_*.py' 和全部 V2 PowerShell scripts，日志放 impl/v2_top/validation。
- [ ] 填 validation report：command、commit、bitstream hash、board revision、measured values、每条 acceptance pass/fail。
- [ ] 提交 feat: integrate and validate v2 fpga top。

## 最终验收门

1. Input：校准/validity vectors pass；纯 Z 永不改 note。
2. LIVE：左边缘 arm、向右起笔、滞回、4 tick、gate split、revoice pass。
3. LOOP：六独立轨、双 bank、full/empty/abort/STOP/boundary pass。
4. Potts：真实 contour 的 RTL 与 Python 逐事件一致；worst-case cycles、boundary timeout、pending policy 和 active-bank 保留有证据。不得引用 41 µs 估算代替测量。
5. Voice：32 simultaneous voices × 2 oscillators、确定性 voice-steal、平滑抢占、vibrato vectors、100 MHz **最终 top** P&R timing pass；独立 voice probe 只能作为专项证据。
6. Audio：实际 I2S/BCLK/LRCK/DIN 约束和板级波形证明 48 kHz、无 underrun；实测 trigger-to-waveform 在 validation report 明确的目标内，目标未测量前不预先写死为 ≤5 ms。
7. Protocol：control/telemetry、CRC、APPLY、ACK/NACK、recovery 在 1 Mbaud pass；115200 结果记录；telemetry frame 必须实际到达 TX。
8. Test mode：N-tone 频谱峰数量、频率误差、无额外 sideband 的报告通过；不能替代 LIVE/LOOP。
9. UI：显示 telemetry、配置 patch/wavetable，不发送 EventTable。
10. Evidence：报告有仿真日志、综合/P&R、板捕获和 bitstream hash。

## 必须执行的降级顺序

- 先移除 chorus，再将 reverb 降为一个 comb，保留 gain/low-pass/delay。
- 只有在前端流水化和关键路径修复后仍不能达到 100 MHz，才允许进入 80 MHz fallback review；fallback 时声部上限为 24，必须重新生成时钟、sample、频谱、资源和延迟证据。
- 若最终 top 时序仍失败，按报告记录的关键路径先降 FX，再评估 16 voice；降到 16 voice 后不能宣称当前 32 voice 硬指标通过。独立 32-component additive test mode 只能作为单独演示，不得替代 32×2 voice acceptance。
- 若 BRAM 不足，保留 A/B 一对并关闭 C，记录确切缺失功能。
- 严禁退回 PC EventTable 播放或预录 PCM。

## 计划自检

- 覆盖：输入校准、前端多周期流水线、Z rebase、LIVE/LOOP、32-slot/track 六轨事务、真实 contour Potts、32×2 voice/voice-steal/vibrato、N-tone test mode、波表抗混叠/启用 reduced FX、UART/telemetry 实际 TX、PC UI、package pin/I2S、真实 top P&R/板测和有条件 80 MHz fallback 均有独立任务和证据。
- 每个步骤都给出具体文件、接口、测试命令和提交点，没有把实现留给未定义的后续工作。
- 类型一致：v2_event_t、11-byte control、22-byte telemetry、CSR 区间、mode 名称和 STOP/fault 语义从 Task 1 贯穿到 Task 12。
- 设计依赖顺序：Task 1 → Task 2 → Task 2.5 → Task 3–5 → Task 6–7 → Task 8 → Task 8.5 → Task 9–11 → Task 12；Task 2.5 是硬件音频通路早期 gate，Task 8.5 是独立可观测性 gate。
- 从当前工作区继续执行的顺序：先补 Task 1 的容量/voice-steal/N-tone/band-selector contract 增量；复用已通过的 Task 2 时钟证据并回填 Task 2.5；随后只修 Task 3–5 的最终多周期/时序差异，再按 Task 6、7、8、8.5、9、10 的未闭合项推进，复核已通过的 Task 11 离线 gate，最后执行 Task 12 full-path P&R、板测和报告。历史上已通过的专项 vectors 不因 Task 2.5 回填而重做。

### Task 8 continuation checkpoint — 2026-10-28

The replay failure found in the previous checkpoint was traced to two RTL timing
issues: the steal hold counter used the unsynchronised `rd_releasing` flag while
writing `calc_slot`, and a release envelope underflowed from 0 to `16'hFFFF`
while the hold was active. The banked engine now carries `calc_releasing`, uses
a 16-bit hold sized for eight complete 32-slot passes, saturates the quiet tail
at zero, and activates the pending note on the same writeback edge that retires
the victim. This preserves the final victim sample and makes the sample-boundary
bitmap match the Python oracle.

Current checks:

```text
python -m unittest tools.test_v2_voice_vectors -v                 # 8 passed
python -m unittest discover -s tools -p 'test_*.py'               # 174 passed
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_voice_engine_banked.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_voice_banked.ps1
git diff --check
```

The file-driven replay covers 1,827 rows / 1,784 samples and passes with a
one-LSB tolerance for both the portable memory model and the installed GW5A
DPB simulation model. A fresh run of
`scripts/synth_v2_voice_engine_banked_20261026.tcl` against this post-fix
source still exits with code 1 before `gw_sh.exe` emits Tcl output, so the
existing 2026-10-26 routed artifact remains historical and Task 8's current
100 MHz P&R gate is not closed.

