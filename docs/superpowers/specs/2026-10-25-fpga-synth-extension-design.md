# 固定点 Lead 合成器扩展设计

版本：2026-10-25  
状态：依据 FPGA 扩展要求形成的 Lead 优先设计  
适用分支：feat/synth-plugin-fpga-baseline

## 1. 扩展目标

本设计把原来的 4 声部固定点基线提升为可用于扩展要求验证的 Lead 合成引擎。目标不是只做一个波形发生器，而是形成一条可测量、可配置、可迁移 RTL 的固定点 Lead 音频路径：

    Event FIFO
      → 32 voice slots
      → 8 synthesis lanes
      → oscillator + envelope + expression
      → 32-to-1 mix
      → delay / harmony effects
      → saturating output
      → visualization telemetry

扩展目标映射如下：

| 扩展要求 | 本设计的对应实现 |
| --- | --- |
| 复音数 ≥32 或 ≥32 路合成单元 | 32 个逻辑声部槽位，8 条并行合成流水线，每条每轮处理 4 个槽位 |
| ≥3 个演奏表达维度 | velocity、glide、vibrato、z_norm、proximity、cursor_gain 中至少启用三个 |
| ≥2 种音色切换 | Lead Clean、Lead Bright 两个固定 patch bank，另支持波形选择 |
| 硬件内部音效 | 固定长度 delay、echo 和 harmony send；参数为定点常量 |
| 低延迟 | 事件在下一个音频采样边界生效，端到端目标 <5 ms |
| 可视化反馈 | 输出 active voice、peak、RMS、频率估计、波形抽样和事件延迟遥测 |
| 脱机扩展 | 预留 LED cue、节拍辅助、蓝牙/App 和配置下载的事件接口 |

## 2. 复音和流水线结构

### 2.1 逻辑声部

固定 32 个声部槽位。每个槽位保存：

    active
    owner_track
    event_id
    note
    phase_q32
    phase_step_q32
    target_phase_step_q32
    waveform_id
    timbre_bank
    velocity_q15
    envelope_state
    envelope_level_q15
    glide_amount_q15
    vibrato_phase_q32
    vibrato_depth_q15
    vibrato_rate_step_q32
    z_norm_q15
    proximity_q15
    cursor_gain_q15
    release_pending

声部槽位是有界资源。声部耗尽时必须返回 voice_exhausted，不能静默创建第 33 个声部。

### 2.2 八条合成流水线

第一阶段配置：

    VOICE_SLOTS     = 32
    SYNTH_LANES     = 8
    VOICES_PER_LANE = 4

每个音频 sample frame 内，8 条 lane 依次处理各自的 4 个槽位。每条 lane 执行：

    phase update
    → optional vibrato phase offset
    → waveform lookup / procedural waveform
    → ADSR multiply
    → velocity and expression multiply
    → lane accumulate

8 条 lane 的结果随后进入树形加法器。这样既能证明多条并行合成单元，也不会把 32 套完整效果器复制 32 次。

### 2.3 时序预算

在 50 MHz、48 kHz 下，每个音频采样周期约有 1041 个系统时钟。目标预算：

| 阶段 | 最大预算 |
| --- | ---: |
| Event FIFO 同步和解码 | 32 cycles |
| 8 lane 声部计算 | 256 cycles |
| 树形混音 | 64 cycles |
| 效果器抽头和饱和 | 128 cycles |
| 音频接口寄存器 | 32 cycles |
| 保留裕量 | ≥529 cycles |

事件在接收后最迟下一个 sample frame 更新。系统级验收仍需测量外部传输、FIFO 和音频接口；音频路径目标延迟不超过 5 ms，且 jitter 为确定性的整数 sample 数。

## 3. 固定点格式

| 参数 | 格式 | 说明 |
| --- | --- | --- |
| 相位 | unsigned Q0.32 | 溢出自然回绕 |
| 相位步进 | unsigned Q0.32/sample | MIDI 频率表生成 |
| 音频样本 | signed Q1.15 | 波形和最终输出 |
| 包络、增益 | unsigned Q1.15 | 乘法保留保护位 |
| 音色/表达 | unsigned Q0.16 或 signed Q1.15 | 映射参数 |
| lane 累加 | signed Q6.27 | 32 声部混音前保留裕量 |
| 效果反馈 | unsigned Q1.15 | 固定上限，禁止不稳定反馈 |

禁止在 RTL 音频路径使用浮点、运行时除法或运行时三角函数。PC renderer 使用整数或定点等价运算生成 golden vector。

## 4. Lead 振荡器

### 4.1 默认 Wave 引擎

默认引擎是固定点波形振荡器，不是 FM：

- triangle：相位高位折叠；
- saw：相位高位直接映射；
- square：相位比较器；
- sine：256 或 1024 点 LUT；
- noise：固定 seed 的 LFSR，仅用于 Texture/FX，不作为 Lead 默认波形。

Lead 默认使用一个主振荡器。波形选择和亮度由 patch 控制，不改变 EventTable 的 note。

### 4.2 可选 FM-2OP 扩展

为扩展评分预留可选 FM-2OP：

    mod_phase += mod_phase_step
    mod_sample = waveform(mod_phase)
    carrier_phase += carrier_phase_step
    carrier_input = carrier_phase + fm_index * mod_sample
    output = waveform(carrier_input)

FM 仅在 engine = fm2op 时启用。调制器、载波、ratio、index 和 feedback 都使用有界定点参数。FM 不改变事件的 note/tick，也不产生新事件。

## 5. ADSR、glide 和 vibrato

包络状态机：

    OFF → ATTACK → DECAY → SUSTAIN → RELEASE → OFF

- Attack、Decay、Release 采用定点递推或系数 LUT；
- NOTE_OFF 只释放所属 event_id 的声部；
- NOTE_REVOICE 保留 phase 和 envelope，仅更新 target_phase_step；
- glide 以固定 slew 逼近目标相位步进；
- vibrato 使用独立相位累加器和小深度查表；
- 停止和 Loop 边界由 ALL_NOTES_OFF 触发有界 release/flush。

## 6. Lead 表达维度

Lead UI 必须提供旋钮或等效连续控件，并且每个旋钮都显示固定范围和当前定点值。

### 6.1 声音旋钮

    Engine          Wave | FM-2OP
    Waveform        triangle | saw | sine | square
    Timbre Bank     Clean | Bright
    Brightness      0..1
    Drive           0..1
    Glide           0..1

### 6.2 动态旋钮

    Attack          1..2000 ms
    Decay           1..4000 ms
    Sustain         0..1
    Release         1..4000 ms
    Velocity Gain   -1..1
    Proximity Gain  -1..1

### 6.3 运动旋钮

    Vibrato Rate    0..12 Hz
    Vibrato Depth   0..100 cents
    Vibrato Delay   0..1000 ms
    Z → Brightness  -1..1
    Z → Space       -1..1
    Cursor → Gain   -1..1

第一阶段至少启用三个表达维度：velocity、glide、vibrato。MGC3130 事件可再启用 z_norm、proximity 和 cursor_gain。Z 只影响 brightness、gain、space 或 modulation depth，不能生成或改写音高事件。

## 7. 音色和片上效果

### 7.1 两个固定 Lead patch bank

Lead Clean：

    waveform = triangle
    brightness = 0.35
    attack = 35 ms
    release = 520 ms
    vibrato_depth = 8 cents

Lead Bright：

    waveform = saw
    brightness = 0.75
    attack = 12 ms
    release = 360 ms
    vibrato_depth = 14 cents

UI 可以切换两个 bank，也可以在范围内调整参数。配置会记录 bank 和最终量化后的参数。

### 7.2 效果器

第一阶段实现固定长度、固定点的：

- delay：至少两个抽头；
- echo：有限反馈，反馈系数受上限约束；
- harmony send：对已经确定的 note 事件生成受限的和声音级副本，不从 XYZ 推测音符；
- dry/wet 混音和最终饱和。

效果器参数由 UI 旋钮控制，但不得导致无限反馈或运行时动态分配。

## 8. 可视化遥测

PC UI 和未来 FPGA 通过相同的 telemetry 字段显示：

    sample_index
    active_voice_count
    voice_exhausted_count
    mixed_peak
    mixed_rms
    clipping_count
    first_affected_sample
    event_latency_samples
    waveform_probe[0..N-1]
    frequency_peaks[]

第一阶段 PC UI 显示：

- 32 个声部槽位的占用条；
- 当前 Lead 音色 bank；
- peak/RMS 电平表；
- 波形 probe；
- 事件到样本的延迟；
- 频谱峰值摘要。

LED、蓝牙/App 和手机控制属于后续 adapter。当前先保证 telemetry 字段和配置文件可扩展。

## 9. 配置文件扩展

在 synth-config/v1 中加入：

    engine_profile: extended-32v-8lane
    voice_slots: 32
    synthesis_lanes: 8
    lead_engine: wave
    lead_timbre_bank: clean
    lead_modulation:
      velocity_gain: 1.0
      glide: 0.35
      vibrato_rate_hz: 4.2
      vibrato_depth_cents: 10
      z_to_brightness: 0.45
      z_to_space: 0.25
      proximity_to_gain: 0.60
    effects:
      delay_enabled: true
      echo_enabled: true
      harmony_enabled: true

旧的 4 声部配置仍可读取；加载扩展 profile 时必须明确显示 32 voice / 8 lane，而不能静默改变配置。

## 10. 验收计划

扩展阶段必须提供：

1. 32 个同时 note_on 的逐样本测试；
2. 32 voice 状态和声部耗尽测试；
3. Clean/Bright 两个 bank 的频谱峰值对比；
4. velocity、glide、vibrato 三个表达维度测试；
5. Z 只改变表达、不改变 note/tick/event_count 的回归测试；
6. delay、echo、harmony 的有限反馈和 clipping 测试；
7. 50 MHz / 48 kHz 时序预算或 RTL 仿真报告；
8. event_latency_samples 和 peak/RMS telemetry；
9. PC renderer 与 RTL golden vector 的误差范围；
10. 资源统计：声部寄存器、相位累加器、LUT、加法器、乘法器、效果器 RAM。

## 11. 范围边界

本阶段先实现：

- Lead 固定点波形引擎；
- 32 voice / 8 lane 配置模型；
- Lead 旋钮和表达映射；
- PC 离线 renderer 与 telemetry；
- 可选 FM-2OP 接口和后续扩展点。

本阶段暂不实现：

- 蓝牙协议和手机 App；
- LED 实物控制；
- 在线曲谱下载；
- 物理建模声部；
- 32 套独立效果器；
- 修改 Capture & Loop 主流程。

