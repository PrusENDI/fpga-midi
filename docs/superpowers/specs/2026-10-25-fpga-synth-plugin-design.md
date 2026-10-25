# FPGA 合成器插件总体设计

版本：2026-10-25
状态：已批准的第一阶段设计；本文件只定义独立合成器插件，不修改 PC Capture & Loop 主流程。

## 1. 目标与边界

本插件是现有 PC Capture & Loop 的独立音频后端参考实现，同时为后续 GW5A-25A FPGA 实时合成核心提供固定点黄金模型。插件读取已经生成的 EventTable 或独立实时事件流，将音乐事件转换为 WAV、分轨 stems 和逐采样对照向量。

主流程继续负责：

- MGC3130 采集、校准、滤波和光标处理；
- Lead、Bass、Pad、Arp、Drums、Texture 事件生成；
- Loop 长度、时间轴、音高和事件诊断；
- EventTable JSON 导出。

插件负责：

- 事件校验和固定点适配；
- 有限声部管理；
- 振荡器、包络、力度和表达参数；
- 混音、限幅和有限效果器；
- WAV/stems 和 RTL golden vector 输出。

插件不得：

- 修改 `tools/synthwave_loop.py`、`pc_receiver/synthwave_ui.py` 或现有 Loop 编译逻辑；
- 根据采集曲线重新生成、改写或补写音符；
- 播放预渲染的整段 PCM 代替实时声部合成；
- 依赖 PC 时间、动态声部字典或无界搜索来定义 FPGA 行为。

## 2. 外部约束

图片中的 FPGA 设计要求作为本插件的硬件约束：

1. 基础目标至少 4 个独立可控声部，并支持多声部同时发声、单音变调、ADSR 和混音。
2. 控制信号到音频输出的硬件路径目标延迟不超过 10 ms。
3. 输出必须由 FPGA 按实时事件逐采样生成，禁止整段 PCM 预存后触发。
4. 后续扩展目标是 32 个复音或 32 个并行合成单元、至少 3 个表达维度、两种以上音色切换和片上效果器。
5. 现场验证需要使用多组不同频率和同时发声事件，频谱中能观察到对应独立峰值，并用 RTL 仿真证明事件到样本的路径。
6. 资源统计按独立振荡器、加法器、FM 运算器和物理建模单元统计；波表内部的谐波数量不重复计数。

第一阶段以当前工程的 GW5A-25A、50 MHz 系统时钟、48 kHz 音频采样和现有 I²S/PCM 边界为基线。Tang Nano 20K、Primer 25K、Mega 60K 和 Mega 138K 只作为后续资源迁移目标，不改变第一阶段接口。

## 3. 独立目录与运行方式

插件使用独立顶层目录，不导入主流程模块：

```text
synth_plugin/
  README.md
  cli.py
  event_schema.py
  fixedpoint.py
  oscillator.py
  envelope.py
  voice_bank.py
  mixer.py
  effects.py
  renderer.py
  patches/
  vectors/
  tests/
```

第一阶段 CLI 形式：

```powershell
python -m synth_plugin.cli render `
  --events path\event_table.json `
  --output path\mix.wav `
  --stems path\stems
```

插件只通过文件契约接收主流程结果。后续若需要连接 FPGA 或实时输入，增加独立 adapter，不修改 EventTable 生成器。

## 4. 参考引擎与 FPGA 核心的共同模型

PC 参考引擎和未来 RTL 必须共享以下语义：

```text
event validation
→ bounded event FIFO
→ voice allocation
→ phase accumulator
→ waveform generator
→ envelope state machine
→ expression mapping
→ voice accumulator
→ saturating mixer
→ optional fixed-size effects
```

PC 版本可以逐样本运行并输出 WAV；FPGA 版本以 `sample_ce` 驱动同一状态转移。PC 版本允许记录更多诊断，但不能使用 FPGA 版本无法表达的隐藏行为作为听感依赖。

## 5. 固定点和时间基线

| 量 | 第一阶段格式/规则 | 说明 |
| --- | --- | --- |
| 系统时钟 | 50 MHz | 沿用当前顶层 |
| 音频采样 | 48 kHz | 使用 fractional sample tick |
| 相位 | unsigned Q0.32 | 一圈对应 `2^32` |
| 相位步进 | unsigned Q0.32 / sample | 由固定 MIDI 频率表产生 |
| 音频样本 | signed Q1.15 | 混音前使用更宽累加器 |
| 包络、增益 | unsigned Q1.15 | 乘法后保留保护位 |
| 混音累加 | 至少 signed Q5.27 | 最终饱和到 Q1.15 |
| MIDI 音高 | 7 bit | 只接受 0–127 |
| 力度 | 8 bit | 0–127，0 触发释放/无声规则由事件定义 |
| 表达参数 | 8 bit 无符号或有符号 | 由事件类型固定解释 |

除法、浮点和运行时三角函数不进入 FPGA 基线。频率、包络系数、波表和效果器系数在构建期生成或写入常量 ROM。

## 6. 声部核心

第一阶段使用 4 个固定槽位。每个声部至少保存：

```text
active
owner_track
note
phase
phase_step
target_phase_step
velocity_gain
envelope_level
envelope_state
waveform_id
timbre
release_pending
```

每个声部是完整的独立发声单元：有自己的相位累加器、频率控制、包络和增益控制。声部之间不得共享会造成相位或包络串扰的状态。

### 6.1 振荡器

基线波形按以下顺序实现：

1. 三角波：由相位高位折叠生成，优先节省 BRAM；
2. 方波/脉冲：相位比较器生成；
3. 正弦波：256 或 1024 点 LUT；
4. 锯齿波：相位高位线性映射。

一个声部基线只启用一个主振荡器。第二振荡器、FM 调制器和谐波叠加作为扩展单元单独统计资源，不隐藏在波表谐波数量中。

### 6.2 ADSR

包络状态固定为：

```text
OFF → ATTACK → DECAY → SUSTAIN → RELEASE → OFF
```

首版优先使用线性或分段定点递推；指数曲线使用查表近似。NOTE_OFF 只释放拥有该事件的声部，不得关闭其他声部。NOTE_REVOICE 保留相位和包络，只改变目标频率并按固定步长滑移。

## 7. 六轨 patch 约束

六条轨道共用声部核心，通过有限 patch 参数区别职责：

| 轨道 | 基线 patch | 受控参数 |
| --- | --- | --- |
| Lead | 三角/锯齿可选、短 glide、ADSR | note、velocity、color、proximity |
| Bass | 方波/三角、短释放 | note、velocity、低通亮度 |
| Pad | 慢包络、有限复音展开 | chord notes、timbre、空间发送 |
| Arp | 短 gate、单/少量声部 | note、velocity、方向控制 |
| Drums | 固定噪声/脉冲包络 ROM | drum id、velocity、decay |
| Texture | 定长噪声、drone 或控制点 | color、depth、effect send |

Patch 只能改变声部参数和效果发送，不能增加事件、改变 tick 或把 Z 变成新音高。

## 8. 表达维度

第一阶段至少支持三个独立表达维度：

- 音高：`note`、`pitch_bend` 或 `NOTE_REVOICE`；
- 动态：`velocity`、`proximity`；
- 音色/空间：`color_layer`、`z_norm`、`cursor_gain`、`CONTROL_POINT`。

表达参数必须经过固定步长或一阶 slew，避免单帧跳变。它们只作用于幅度、波形选择、滤波亮度、glide 或 delay/reverb send，不产生额外 NOTE_ON。

## 9. 实时路径和延迟

事件进入后采用有限深度 FIFO。事件处理和采样处理分离：UART、传感器或 PC 传输暂时阻塞时，已经进入音频 FIFO 的事件仍按音频时钟完成。

硬件延迟预算：

```text
事件接收/同步       ≤ 2 ms（目标）
事件 FIFO 等待       ≤ 2 ms（目标）
声部状态更新         ≤ 1 sample
混音流水线           ≤ 1 ms（目标）
输出接口缓冲         ≤ 4 ms（目标）
总计                 < 10 ms
```

实际验收必须测量最坏路径，不能只用平均值。PC 离线插件用相同的事件时序生成逐样本结果，不把离线渲染时间计入该硬件延迟。

## 10. 资源扩展路线

| 阶段 | 声部/单元 | 目标 |
| --- | ---: | --- |
| Baseline | 4 个完整声部 | 48 kHz、ADSR、三种波形、定点混音 |
| Expansion A | 8–16 个声部 | 增加音色切换和有限 delay |
| Expansion B | 32 个声部或并行合成单元 | 依据 GW5A-25A 资源和时序报告决定并行/时分复用 |
| Effects | 固定长度 delay/reverb/chorus | 片上 RAM、固定抽头、有限反馈 |

每一阶段都必须保留综合报告、最高频率、资源使用和音频验证结果。未完成综合或现场验证时，不宣称达到下一阶段。

## 11. 验证

### PC 参考模型

- 同一输入事件、配置和 seed 必须产生完全相同的 WAV 和 stems；
- 每个声部可以单独静音、独奏和导出；
- NOTE_ON/OFF、NOTE_REVOICE、CONTROL_POINT 和 ALL_NOTES_OFF 的状态转移可追踪；
- 混音超过范围时执行确定性饱和，并输出 clipping 计数。

### 频谱和时域

- 使用 C4、E4、G4 等多个不同频率事件，检查频谱峰值；
- 同时触发多个声部，检查峰值独立且没有异常互调主峰；
- 检查 attack、release、glide 和停止后的残留；
- 检查控制信号到第一个受影响样本的延迟。

### RTL 对照

未来 RTL 测试必须比较：

```text
sample_index
sample_valid
mixed_sample
active_voice_count
envelope_state
phase
```

允许的量化差异必须在接口文档中明确；不能用“听起来接近”替代逐样本或频率误差验收。

## 12. Git 和文档交付规则

插件开发不在 `feat/loop-event-store` 主工作区中进行，使用独立分支 `feat/synth-plugin-fpga-baseline`。

每个大阶段至少包含：

1. 对应设计或接口文档；
2. 可运行的测试或向量；
3. 明确的验证结果和未完成项；
4. 单独的 Git 提交并推送到远程分支。

本阶段只提交设计规范和事件接口文档；不修改主流程代码，不接入现有顶层。

## 13. 待实现阶段

1. 固定点工具和 EventTable 适配器；
2. 单声部振荡器与 ADSR；
3. 4 声部声部管理与混音；
4. 六轨 patch 和 stems；
5. 固定长度效果器；
6. RTL golden vector 和综合对照；
7. 需要时再设计独立 FPGA adapter 和顶层集成。
