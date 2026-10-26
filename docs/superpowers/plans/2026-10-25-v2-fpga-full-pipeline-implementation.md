
# V2 FPGA 全链路合成器实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 在 GW5A-25A 上交付可独立综合、布局布线、烧录和验收的 V2 全链路：MGC3130 输入、FPGA 固定点坐标处理、LIVE 出音、六轨 Loop、提交时 Potts 精修、32 声部双振荡器、混音/有限 FX、I2S 输出，以及 PC 参数和遥测 UI。

**Architecture:** V2 使用全新的 rtl/mgc3130_v2_top.sv，不把旧 mgc3130_uart_top.sv 当作最终顶层，也不要求 PC 发送 EventTable。FPGA 内部以 100 MHz 系统时钟运行，使用分数累加器产生平均精确 48 kHz 的 sample_ce，输入和控制在独立队列中跨到音频处理域。LIVE 使用逐帧电平穿越和门控，LOOP 在一圈结束后由固定点 Potts FSM 提交精修；PC 只下发 shadow 配置、波表和控制命令，并接收双缓冲遥测。

**Tech Stack:** SystemVerilog（Gowin GW5A-25A、Gowin DPB/PLL、ModelSim/Questa、Gowin 综合与 P&R）、Python 3 标准库和现有 tools/synthwave_loop.py 黄金参考、Tkinter PC UI、PowerShell 验收脚本。

**Spec:** docs/system-design-summary-2026-10-25.md、docs/synth-backend-design-2026-10-25.md、docs/voice-engine-design-2026-10-25.md、docs/fpga-baseline-audit-2026-10-25.md，以及本计划中的 docs/v2-fpga-contract-2026-10-25.md。冲突时以 V2 contract 和本计划为准；旧 PC EventTable 后端只作为离线黄金参考。

## Global Constraints

- 最终演奏路径必须是 MGC3130 → FPGA 输入/滤波/光标/出音/Loop/声部/混音 → I2S；PC 不发送最终演奏事件，也不发送 PCM。
- 旧 mgc3130_uart_top.sv、旧 LOOP 位流和旧四轨/旧四声部路径保留为 V1 回归基线；V2 只在独立顶层实现。
- FPGA 系统时钟固定为 100 MHz；48 kHz 音频由分数 sample scheduler 产生，不能把 2083 个时钟当成精确整除周期。
- 六轨固定为 lead=0、bass=1、pad=2、arp=3、drums=4、texture_fx=5；六轨都能独立录制、覆盖和提交。
- LIVE 与 LOOP 使用两个独立状态机和两套 golden vector；LIVE 不等待全局 DP，LOOP 提交后才运行 Potts。
- Z 只能作用于力度、亮度/滤波、空间/调制深度和接合速度；纯 Z 变化不能产生 NOTE_ON、NOTE_OFF 或音高跳变。
- 输入校准、无效帧、饱和帧、gap、去耦合、固定点舍入、溢出和降级状态都必须有回放证据。
- 配置写入 shadow，经过 CRC/version 校验并显式 APPLY；UART 阻塞不能阻止 sample_ce、事件队列或 I2S。
- 所有 32 声部、≤5 ms、FX 可用、Potts 时限结论必须由 RTL 仿真、综合/P&R 报告或板级测量支持；估算不能作为完成证据。
- 每个任务结束提交独立文档或代码提交；不得包含用户已有未提交文件。

## 现状与针对性修正

当前事实必须写入验收记录：

1. mgc3130_uart_top.sv 仍使用旧 mgc3130_pattern_input 和 mgc3130_voice_mixer；VOICE_COUNT 默认 4，不能代表 32 声部。
2. 旧顶层、I2S 和 Loop 模块仍以 50 MHz 为主；没有 V2 PLL、分数 48 kHz scheduler 或最终 P&R 时序证据。
3. 旧 Loop 控制使用 115200、10 字节命令和单邮箱；设计文字中的 1 Mbaud、64 位事件、32 位 CSR 尚未形成可互通协议。
4. synth backend、voice engine 和 system summary 的地址定义互相冲突；V2 只能保留一份地址表。
5. 旧顶层有两个模块监听同一 uart_rx；V2 必须只有一个接收器和一个帧解析器。
6. 旧 Loop 存储/调度器文档虽描述六轨目标，RTL 仍有旧四轨宽度和 96 槽扫描边界；V2 必须重新定义事件宽度、背压和边界提交。
7. 波表上传、Potts DP、32×2 声部、遥测、FX、PC V2 UI 和板级验收仍是设计文字，没有端到端证据。

## 文件与职责地图

### 新建文件

- docs/v2-fpga-contract-2026-10-25.md：V2 模式、事件、CSR、UART、遥测、时钟和错误语义唯一规范。
- docs/v2-validation-report-2026-10-25.md：仿真、综合、P&R、板级和延迟/频谱证据。
- rtl/v2_contract_pkg.sv：类型、枚举、事件位宽、CSR 地址和错误码。
- rtl/v2_clock_gen.sv、rtl/v2_sample_scheduler.sv：100 MHz PLL 封装和 48 kHz 分数 sample_ce。
- rtl/v2_input_calibration.sv、rtl/v2_position_validity.sv、rtl/v2_cursor_filter.sv：输入固定点链路。
- rtl/v2_live_rule_engine.sv、rtl/v2_loop_event_recorder.sv、rtl/v2_potts_commit_fsm.sv：LIVE、录制和提交精修。
- rtl/v2_voice_engine_mux.sv、rtl/v2_wavetable_loader.sv、rtl/v2_fx_lite.sv：声部、波表和有限 FX。
- rtl/v2_uart_link.sv、rtl/v2_telemetry_snapshot.sv、rtl/mgc3130_v2_top.sv：单一 V2 控制/遥测链路和最终顶层。
- tools/v2_contract.py、tools/test_v2_contract.py、tools/v2_fixed_reference.py、tools/test_v2_fixed_reference.py：协议和逐帧/逐样本黄金参考。
- pc_receiver/fpga_v2_model.py、pc_receiver/fpga_v2_ui.py：参数、遥测和轨迹显示。
- sim/tb_v2_*.sv、scripts/test_v2_*.ps1、scripts/synth_v2_top.tcl、scripts/measure_v2_latency.ps1：分模块和顶层验证。

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
- v2_contract_pkg.sv 导出 v2_mode_e（IDLE/LIVE/RECORD/COMMIT/PLAY/ERROR）、v2_event_t（96 bits）、v2_cmd_t、v2_telemetry_t、CSR/error constants。
- tools/v2_contract.py 导出 encode_control(op,address,data,seq)、decode_control(frame)、encode_event(event)、encode_telemetry(snapshot)、crc16_ccitt(data)。
- 事件固定字段：type[3:0]、track[2:0]、tick[7:0]、duration[7:0]、note[7:0]、velocity[7:0]、pitch_mod[15:0]、timbre_mod[15:0]、flags[7:0]、sequence[15:0]，显式断言总宽度 96 位。
- 控制包：SOF 0xA5、version 0x02、op、address、sequence、data 32 bit、CRC16-CCITT；固定 11 字节。遥测包固定 22 字节：SOF 0x5A、version、type、sequence、x/y/z、note、flags、tick、voice_bitmap、fifo_level、fault_code、CRC16。
- 地址冻结为 0x00–0x44 legacy Loop、0x48–0x5C patch/gesture、0x60–0x7C wavetable/APPLY、0x80–0x9C telemetry/diagnostics、0xA0–0xAF test mode；其余拒绝。
- 只有 v2_uart_link.sv 监听 V2 uart_rx；旧顶层不连接 V2 UART。

**Steps**
- [ ] 写 CRC、端序、11 字节控制包、22 字节遥测包、地址拒绝和 round-trip 的失败测试。
- [ ] 运行 python -m unittest tools.test_v2_contract -v，确认失败信息对应缺失函数。
- [ ] 实现 serializer、显式掩码、CRC 和文档地址表；x/y/z 与 pitch_mod 使用二补码。
- [ ] 增加 SV 宽度/长度/地址断言，编译 package。
- [ ] 运行 Python 和 SV 测试并记录命令。
- [ ] 提交 docs: freeze v2 fpga contract and protocol。

**Stop gate:** 后续 RTL 不得引入第二种事件布局、UART 包、遥测长度或 CSR 地址。

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

## Task 3：实现 FPGA 输入有效性、校准和固定点坐标语义

**Files**
- Create: rtl/v2_input_calibration.sv、rtl/v2_position_validity.sv、sim/tb_v2_input_validity.sv。
- Modify: rtl/mgc3130_input_latch.sv。

**Interfaces**
- v2_input_frame_t：sequence、timestamp_ticks、signed raw x/y/z、touch、presence、valid_xyz、saturated、gap、calibration_epoch。
- 校准顺序固定为 raw sign extension → validity/saturation → neutral offset → z coupling subtraction → gain → workspace clamp → output validity。
- validity 输出 frame_valid、lost、degraded、gap_count、calibration_reason；无效/饱和位置永远不能进入音符生成。

**Steps**
- [ ] 用 neutral、depth、workspace、invalid、saturation、gap 采集生成 tools/testdata/v2_input。
- [ ] 为符号扩展、钳位顺序、gap、epoch 变化写 Python/SV 失败测试。
- [ ] 实现 shadow/active profile，固定点乘法、舍入、饱和和原因位。
- [ ] 与 tools/v2_fixed_reference.py 逐帧比对，要求整数结果和原因位全相等。
- [ ] 综合算术块，记录 LUT/FF/DSP。
- [ ] 提交 feat: add v2 fixed point input calibration and validity。

**Stop gate:** invalid、lost 或 saturated 帧不能创建音符或改变 pitch 状态。

---

## Task 4：实现光标滤波、Z clutch/rebase 和 golden vectors

**Files**
- Create: rtl/v2_cursor_filter.sv、sim/tb_v2_cursor_filter.sv、tools/v2_cursor_reference.py、tools/test_v2_cursor_reference.py。

**Interfaces**
- 输入有效校准帧和 alpha_low=0.12、alpha_high=1.0、z_engage=30000、z_release=36000、max_step_q16、settle_ticks。
- 输出绝对 cursor x/y/z、normalized pitch、velocity/depth controls 和 DISENGAGED/ENGAGED/REBASED/DEGRADED。
- 冻结区隐藏 anchor；离开时第一帧设为新 anchor，输出零位移；REBASED 只保持一帧。
- filter 在输入帧率采样；audio sample_ce 只消费最新稳定 control point，不改变时间戳和 Loop tick。

**Steps**
- [ ] 写左边缘接合、高 Z 冻结/恢复、invalid gap、slew 饱和和纯 Z 向量。
- [ ] 先写失败测试：rebase 无跳变、纯 Z 无 pitch 改变、每帧位移不超限。
- [ ] 实现 5 点中值、IIR、slew 和 anchor-relative clutch 固定点版本。
- [ ] RTL 复现状态机，输出一帧 REBASED。
- [ ] Python/RTL 逐帧比较并综合。
- [ ] 提交 feat: add v2 cursor filter with clutch rebase。

**Stop gate:** 离开冻结区不能生成 TURN/APEX 或 pitch 事件。

---

## Task 5：实现独立 LIVE 和 LOOP 规则引擎

**Files**
- Create: rtl/v2_live_rule_engine.sv、rtl/v2_loop_event_recorder.sv、sim/tb_v2_live_rule_engine.sv、sim/tb_v2_loop_event_recorder.sv、tools/v2_rule_reference.py、tools/test_v2_rule_reference.py。

**Interfaces**
- LIVE 输出 note_on、note_off、note_revoice、control-only；左边缘 arm、音级滞回、最小 4 tick。
- gate 可选 touch/bow；X 边缘穿越可以同音 revoice；Z 只改 velocity/brightness/gain；纯 Z 无 note event。
- LOOP 记录六轨、monotonic tick、duration、velocity、control flags；LIVE FIFO 与 LOOP write FIFO 独立。
- 两个 FSM 各自暴露 fault_code、event_count、left_edge_armed、gate_state。

**Steps**
- [ ] 为左到右、反向拒绝、边缘最终右移点、纯 Z、touch split、bow reversal、同音 revoice、invalid gap、轨道独立写 vectors。
- [ ] 为 tick 顺序、4 tick 间隔、边缘条件和 FIFO 背压写失败测试。
- [ ] 实现两个显式 FSM，不用隐式共享 mode。
- [ ] 运行 reference/RTL 对照和六轨 store 集成。
- [ ] 提交 feat: add v2 live and loop rule engines。

**Stop gate:** LIVE vectors 全通过后才演示 LIVE；LOOP overflow、abort、boundary vectors 全通过后才演示 LOOP。

---

## Task 6：升级 Loop 存储、调度器和边界事务

**Files**
- Create: rtl/v2_loop_event_store.sv、rtl/v2_loop_scheduler.sv、sim/tb_v2_loop_transactions.sv。
- Modify only through V2 wrapper: rtl/loop_event_ram.sv.
- Update docs/loop-event-store-interface.md、docs/loop-scheduler-interface.md、docs/loop-control-plane-interface.md。

**Interfaces**
- 两 bank、六轨、每轨 16 event slots、96-bit v2_event_t；逻辑 loop 为 128 ticks。
- PREPARE_RECORD、PREPARE_OVERDUB、COMMIT、ABORT、STOP、CLEAR_TRACK、CLEAR_ALL 均有 accepted/busy/done/fault。
- commit：freeze shadow → drain record FIFO → wait boundary → swap bank → publish counts；同拍请求等下一个 boundary。
- scheduler valid/ready；boundary 先 ALL_NOTES_OFF；背压时不跳 tick。
- 满轨 ERR_TRACK_OVERFLOW 且保留 active；空录音 abort。

**Steps**
- [ ] 定义 96-bit RAM lane mapping 和六轨地址计算。
- [ ] 为首录、叠录保留、满轨、空 abort、STOP boundary、commit 背压、active 保留写失败测试。
- [ ] 通过 wrapper 实现 V2，不改变 V1。
- [ ] 运行 RTL RAM、Gowin DPB model 和独立综合，记录 BSRAM/scan cycles。
- [ ] 更新三份接口文档，明确 V1 与 V2 状态。
- [ ] 提交 feat: add v2 six track loop transactions。

**Stop gate:** V2 top 不得使用旧四轨事件宽度或 96-slot scan 假设。

---

## Task 7：实现固定点 Potts COMMIT FSM 并测量预算

**Files**
- Create: rtl/v2_potts_commit_fsm.sv、sim/tb_v2_potts_commit.sv、tools/v2_potts_reference.py、tools/test_v2_potts_reference.py、scripts/measure_v2_potts.ps1。

**Interfaces**
- 输入 128-tick lead contour、固定 A minor pentatonic、lambda_q16、最小 4 tick 和 rest mask。
- state 为 cost[tick][degree][length_class]，有限宽度饱和和 backpointer RAM；暴露 busy/progress/done/overflow/backtrace_valid。
- 输出六轨兼容 lead event list；rest 无事件，gap 前最后有效转折保留。
- tie-break 固定为 cost 更低、段更长、degree 更低。

**Steps**
- [ ] Python fixed-point reference 和 exhaustive small-grid tests。
- [ ] RTL vectors 覆盖全 rest、单音、tie、min length、饱和。
- [ ] BRAM ping-pong rows、one-cell/cycle candidate、backtrace 和 event FIFO。
- [ ] 100 MHz 实际测量最坏 commit contention；41 µs 只作估算目标。
- [ ] 验证 COMMIT 不阻塞 sample_ce、LIVE audio 或 UART，只阻塞 bank swap。
- [ ] 提交 feat: add measured v2 fixed point potts commit。

**Stop gate:** RTL 与 Python 相同且实测预算适合 boundary policy 才能称为全局精修。

---

## Task 8：构建并验证 32 声部、64 振荡器时分复用引擎

**Files**
- Create: rtl/v2_voice_engine_mux.sv、rtl/v2_note_increment_rom.sv、sim/tb_v2_voice_engine.sv、tools/test_v2_voice_vectors.py、scripts/synth_v2_voice_engine.tcl。

**Interfaces**
- 32 slots、每 slot 两 oscillator、phase Q0.32、envelope Q1.15、velocity/timbre/track/note/active。
- valid/ready 接收 NOTE_ON/OFF/REVOICE；返回 active_bitmap[31:0]、voice_overflow、revoice_count、mixed_sample。
- free slot first；全满时 overflow 且不破坏已有声部；revoice 保持 phase，通过 bounded glide 改 increment。
- A/B/C 共享 1024×16 表，显式饱和；cycle budget 包含 BRAM read latency、包络、乘法和累加。

**Steps**
- [ ] vectors 覆盖 1、8、32 note、33rd overflow、release、revoice phase、ADSR、detune、saturation。
- [ ] 先跑 Python fixed-point voice reference。
- [ ] 实现 voice state RAM 和 round-robin microsequencer，禁止推断 32 条并行 pipeline。
- [ ] RTL 频率/peak 和 1 LSB sample compare。
- [ ] 100 MHz 综合/P&R，记录 LUT/FF/BSRAM/DSP/Fmax/slack/cycles/sample。
- [ ] 提交 feat: add verified v2 voice engine。

**Stop gate:** 32 note、33rd overflow 和 P&R timing 全通过才接受“32 voices”。

---

## Task 9：加入波表上传、Patch 语义和资源受限 FX

**Files**
- Create: rtl/v2_wavetable_loader.sv、rtl/v2_fx_lite.sv、sim/tb_v2_wavetable_fx.sv、tools/test_v2_patch_vectors.py。
- Update docs/v2-fpga-contract-2026-10-25.md。

**Interfaces**
- A/B/C 表上传含 table ID、block、16-bit samples、version、CRC16；只写 shadow BRAM，暴露 busy/crc_ok/crc_error/active_version。
- APPLY 只在 Loop boundary 或 idle 原子切换；CRC 失败保留 active。
- Patch 固定 oscillator mix、brightness、detune、ADSR、glide、vibrato、Z→gain/brightness/space、track enable，所有 Q 格式/钳位写入 contract。
- FX 顺序 gain → one-pole low-pass → delay → one-comb reverb；chorus 只有 P&R 留有余量时启用。V2_FX_LEVEL 和 telemetry 报告实际等级。
- FX 不能访问 raw input，也不能改变 pitch/timing。

**Steps**
- [ ] 写 upload/CRC/rollback、patch clamp 和纯 Z invariant tests。
- [ ] 实现 shadow BRAM 与 boundary APPLY。
- [ ] 实现固定点 gain/filter/delay/comb、反馈限制和饱和。
- [ ] 先综合 full FX，失败则 reduced FX，并记录原因。
- [ ] 跑频响、脉冲响应和 Z 表达测试。
- [ ] 提交 feat: add v2 wavetable patch and bounded fx。

**Stop gate:** FX 不能延迟输入、Loop、voice、I2S 主路径；报告必须写明最终等级。

---

## Task 10：实现单一 UART/CSR 控制和无撕裂遥测

**Files**
- Create: rtl/v2_uart_link.sv、rtl/v2_telemetry_snapshot.sv、sim/tb_v2_uart_link.sv、sim/tb_v2_telemetry.sv、scripts/test_v2_uart.ps1。
- Modify: docs/v2-fpga-contract-2026-10-25.md only for tested concrete mismatch.

**Interfaces**
- v2_uart_link 是唯一 V2 uart_rx 接口；解码 11-byte controls，返回带 seq/error 的 ACK/NACK，patch/wavetable/Loop 命令使用独立 FIFO。
- 默认 1,000,000 baud，同时实测 115,200 fallback；TX 阻塞不影响 sample_ce。
- telemetry snapshot 原子捕获 cursor、note、tick、bitmap、FIFO、latency、peak/RMS、fault，复制到 TX FIFO 后再更新字段。
- ACK 语义区分 shadow stored、CRC failure、timeout、overflow、bad address、busy、APPLY accepted。

**Steps**
- [ ] 测 bad CRC、duplicate seq、TX backpressure、shadow readback、boundary APPLY、telemetry tearing、两种 baud。
- [ ] 实现 RX parser、command FIFOs、ACK/NACK、timeout。
- [ ] 实现双缓冲 telemetry 和 22-byte serializer。
- [ ] 阻塞 TX 同时生成音频事件，确认 sample_ce 不丢。
- [ ] 提交 feat: add v2 uart control and telemetry。

**Stop gate:** PC UI 连接前必须通过字节级、背压和 snapshot tests。

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

**Files**
- Create: rtl/mgc3130_v2_top.sv、scripts/synth_v2_top.tcl、scripts/test_v2_top.ps1、scripts/measure_v2_latency.ps1、docs/v2-validation-report-2026-10-25.md、sim/tb_mgc3130_v2_top.sv、impl/v2_top/README.md、mgc3130_v2.sdc。
- Update: separate V2 project manifest; do not replace old top.

**Interfaces**
- 顶层保留现有 MGC3130、UART、I2S、reset 和诊断 pin；约束从现有 .cst 复制后做显式 diff。
- 固定顺序：input_latch → calibration/validity → cursor_filter → (live_rule || loop_recorder) → loop_store/scheduler → potts_commit → voice_engine_mux → fx_lite → i2s。
- v2_uart_link 是唯一 UART receiver；旧 command receiver 不实例化。
- 所有跨域队列、fault recovery、ALL_NOTES_OFF 在顶层可见并有 assertions。
- STOP 关闭 gate、flush event/audio queue、发送 ALL_NOTES_OFF、保留 active Loop；RESET 清诊断但不清 active music。

**Steps**
- [ ] 建独立 top 和仿真 MGC3130 source；断言不实例化 V1 top。
- [ ] 顶层测试左到右 LIVE、纯 Z、invalid/gap、六轨 record/overdub/commit/play、STOP、CRC/APPLY、1/8/32 voice、33rd overflow、I2S sample count、telemetry。
- [ ] V2 synthesis/P&R/timing，记录 logic/FF/DSP/BSRAM/Fmax/slack/sample cycles/FIFO/FX level。
- [ ] 对实际 V2 I2S/BCLK 端口加入同步输出时序约束，检查端口路径、时钟关系和板级波形；不得把 Task 2 的系统时钟 SDC 当作完整 I2S I/O 约束。
- [ ] 独立 bitstream 板测：参数帧、telemetry、I2S、GPIO trigger latency。
- [ ] 运行 python -m unittest discover -s tools -p 'test_*.py' 和全部 V2 PowerShell scripts，日志放 impl/v2_top/validation。
- [ ] 填 validation report：command、commit、bitstream hash、board revision、measured values、每条 acceptance pass/fail。
- [ ] 提交 feat: integrate and validate v2 fpga top。

## 最终验收门

1. Input：校准/validity vectors pass；纯 Z 永不改 note。
2. LIVE：左边缘 arm、向右起笔、滞回、4 tick、gate split、revoice pass。
3. LOOP：六独立轨、双 bank、full/empty/abort/STOP/boundary pass。
4. Potts：RTL 与 Python 一致，实测 commit 预算适合 boundary policy。
5. Voice：32 simultaneous notes、33rd overflow、100 MHz P&R timing pass。
6. Audio：I2S 48 kHz、无 underrun、实测 trigger-to-waveform 在声明目标内。
7. Protocol：control/telemetry、CRC、APPLY、ACK/NACK、recovery 在 1 Mbaud pass；115200 结果记录。
8. UI：显示 telemetry、配置 patch/wavetable，不发送 EventTable。
9. Evidence：报告有仿真日志、综合/P&R、板捕获和 bitstream hash。

## 必须执行的降级顺序

- 先移除 chorus，再将 reverb 降为一个 comb，保留 gain/low-pass/delay。
- 若时序仍失败，降到 16 voice；只有在同一频谱测试通过时才保留独立 32-component additive test mode。
- 若 BRAM 不足，保留 A/B 一对并关闭 C，记录确切缺失功能。
- 严禁退回 PC EventTable 播放或预录 PCM。

## 计划自检

- 覆盖：输入校准、Z rebase、LIVE/LOOP、六轨事务、Potts、32 voice、波表/FX、UART/telemetry、PC UI、top/P&R/板测均有独立任务和证据。
- 每个步骤都给出具体文件、接口、测试命令和提交点，没有把实现留给未定义的后续工作。
- 类型一致：v2_event_t、11-byte control、22-byte telemetry、CSR 区间、mode 名称和 STOP/fault 语义从 Task 1 贯穿到 Task 12。
- 依赖顺序：Task 1–2 先于时序 RTL；Task 3–5 先于 LIVE；Task 6–7 先于 LOOP；Task 8 先于 FX/top；Task 10–11 先于 UI 联调；Task 12 是唯一完成声明点。

