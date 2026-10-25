# 面向 Loop 控制流的 FPGA 并行合成器后端设计

版本：2026-10-25  
状态：依据现有 Loop 文档重新整理的后端架构  
适用分支：feat/synth-plugin-fpga-baseline

## 1. 设计结论

现有 Loop 系统已经具备合成器需要的时间和控制边界：

- 六轨 EventTable；
- 双 bank active/shadow 存储；
- 128 tick Loop；
- 每 tick 三轮 NOTE_OFF → NOTE_ON → CONTROL_POINT；
- valid/ready 背压；
- Loop boundary 提交；
- STOP/flush/all-notes-off；
- RECORD、OVERDUB、PLAY、CLEAR 和 COMMIT 操作。

因此合成器后端不应重新实现一个独立的 Loop 播放器。它应作为 Loop scheduler 的下游，接收已经排序和握手完成的事件，并用并行硬件过程把事件转换为 32 声部音频。

核心数据流：

    Capture & Loop UI
      → EventTable / control command
      → loop event adapter
      → event FIFO
      → voice manager
      → 8 synthesis lanes × 4 voice slots
      → track bus
      → FX bus
      → limiter / PCM
      → mix, stems, telemetry

PC 离线 renderer 使用同一套事件顺序、voice policy、lane 分配和边界语义；它不是重新分析 XYZ 或重新生成旋律。

## 2. 与现有 Loop 的边界

### 2.1 上游继续负责的事情

Capture & Loop 主流程继续负责：

- MGC3130 采集和 Host Filter；
- Lead 左侧起笔门控；
- 固定 PitchSpace；
- 128 tick 或 auto-length Loop 编译；
- 六轨事件生成；
- EventTable 导出；
- 录制、叠录、清轨和清空的用户意图。

合成器后端不能改变 note、tick、duration、track 或事件数量。

### 2.2 合成器后端负责的事情

合成器负责：

- 将 EventTable 适配为固定事件格式；
- 按 scheduler 顺序处理 NOTE_OFF、NOTE_ON、CONTROL_POINT 和 ALL_NOTES_OFF；
- 分配和释放 32 个声部；
- 运行 8 条固定合成 lane；
- 生成 Lead 音色和其他轨道的有限 patch；
- 处理 Z、proximity、velocity、glide、vibrato 等表达；
- 混音、效果、限幅和分轨；
- 输出确定性 telemetry 和 golden vectors。

### 2.3 不重复实现的内容

后端不再实现：

- 第二套 tick 计数器；
- 第二套 Loop boundary 提交协议；
- 第二套 RECORD/OVERDUB 存储；
- 根据 XYZ 重新猜测音符；
- 根据 Z 自动创建新 NOTE_ON；
- 预渲染整段 PCM 再触发播放。

## 3. 并行硬件过程

这里的“多进程”指 FPGA 内部同时工作的同步硬件过程，不是操作系统线程。每个过程使用固定时钟、固定队列和明确握手。

### 3.1 控制过程

模块名：synth_control_process

职责：

- 接收 Capture & Loop UI 或未来 UART/CSR 的配置命令；
- 保存 active/shadow 合成器配置；
- 在安全边界应用 patch、效果和全局增益；
- 处理 RESET、STOP、PLAY、MUTE、SOLO、RENDER_PROFILE 等命令；
- 向 telemetry 输出命令状态。

配置修改默认使用 shadow 配置，在 Loop boundary 或显式 APPLY 时一次性生效。这样旋钮连续变化不会在一个音频 sample 中产生不确定的半更新状态。

### 3.2 事件接收过程

模块名：synth_event_ingress

职责：

- 接收 scheduler 的 event_valid/event_ready；
- 校验 track、type、tick、note、velocity；
- 将事件写入有限深度 event FIFO；
- 保留 event_id、parent_event_id、order 和 source 信息；
- 记录 invalid_event、FIFO overflow 和 event latency。

事件过程与音频 sample 过程分离。事件传输暂时背压时，Loop scheduler 保持 valid 和数据；音频过程继续消费已经进入 FIFO 的事件。

### 3.3 声部管理过程

模块名：synth_voice_manager

职责：

- 维护 32 个固定声部槽位；
- 将 NOTE_ON 分配到空闲或已释放槽位；
- 处理 NOTE_OFF、NOTE_REVOICE 和 ALL_NOTES_OFF；
- 维护 event_id、track、note 与 voice slot 的所有权；
- 输出 voice_exhausted 和 deterministic steal 诊断；
- 将每个槽位映射到固定 synthesis lane。

默认分配优先级：

1. 同一 track 的空闲槽；
2. RELEASE 状态槽；
3. 最早进入 RELEASE 的槽；
4. 明确配置的 voice stealing；
5. 没有可用槽时拒绝并锁存 voice_exhausted。

默认不抢占 ATTACK、DECAY 或 SUSTAIN 中的 Lead 声部，避免 Loop 中的长音被新事件静默切断。

### 3.4 八条合成过程

模块名：synth_lane[0..7]

固定配置：

    VOICE_SLOTS     = 32
    SYNTH_LANES     = 8
    VOICES_PER_LANE = 4

每条 lane 固定绑定 4 个 voice slot。lane 不动态迁移声部，避免时序和调试结果变化。

每条 lane 内部并行或流水执行：

    voice state read
      → phase accumulator
      → vibrato / glide phase adjustment
      → waveform or LUT
      → ADSR multiply
      → velocity / expression multiply
      → lane accumulator

8 条 lane 同时工作，输出送入树形加法器。这样 32 声部的相位、包络、波形和表达状态可以被独立观察，资源统计也能按 lane、LUT、乘法器和寄存器归因。

### 3.5 轨道总线过程

模块名：track_bus_process

六条轨道分别保留独立的增益、静音、独奏和 patch 选择：

    lead → lead_bus
    bass → bass_bus
    pad → pad_bus
    arp → arp_bus
    drums → drums_bus
    texture → texture_bus

同一 lane 可以处理不同 track 的 voice，但 track bus 不能共享会造成包络或相位串扰的状态。

### 3.6 效果过程

模块名：fx_bus_process

效果器放在 track bus 之后，避免把 delay/reverb 复制 32 次。第一阶段包含：

- 两抽头 delay；
- 有界 echo feedback；
- harmony send；
- dry/wet 混音；
- 最终 limiter 和 saturating output。

效果器使用片上 RAM 或固定深度寄存器。效果参数在安全边界锁存，反馈系数有硬上限。

### 3.7 telemetry 过程

模块名：synth_telemetry_process

以较低速率独立运行，采集：

    loop_tick
    loop_boundary_count
    active_voice_bitmap
    active_voice_count
    voice_exhausted_count
    event_fifo_level
    event_latency_samples
    mixed_peak
    mixed_rms
    clipping_count
    waveform_probe
    frequency_peaks
    last_control_op
    fault_code

telemetry 不参与音频反馈，避免诊断读取改变音频时序。

## 4. Loop 事件与合成器的时序关系

### 4.1 事件优先级

合成器保持 scheduler 的顺序：

1. NOTE_OFF；
2. NOTE_ON；
3. CONTROL_POINT；
4. LOOP_BOUNDARY；
5. ALL_NOTES_OFF/STOP 的紧急关音路径。

同一 tick 和同一类型内按槽位索引、order、event_id 稳定排序。背压时不得跳过或重排事件。

### 4.2 duration

scheduler 已经根据 NOTE_ON duration 派生 NOTE_OFF。合成器不再运行另一套 duration 计时器，以免同一个音收到两次关闭。

duration 为零时：

- 等待显式 NOTE_OFF；
- 或在 ALL_NOTES_OFF/Loop boundary 时关闭。

### 4.3 Loop boundary

在 boundary 处：

1. 接收 scheduler 的最后一格事件；
2. 接收 ALL_NOTES_OFF；
3. 清理尚未释放的 voice；
4. 接收 LOOP_BOUNDARY；
5. 锁存新 bank 和新配置；
6. 从 tick 0 重新接受事件。

新 bank 的 tick 0 事件不能与旧 bank 的尾部事件混用。切换期间 voice bitmap、event FIFO 和 active bank 状态必须可被 telemetry 观察。

### 4.4 STOP 和 FLUSH

STOP 是紧急控制路径：

- 取消未交付的普通 NOTE_ON；
- 清空 event FIFO；
- 发送 ALL_NOTES_OFF；
- 让所有 voice 进入 RELEASE 或 OFF；
- 保留 active Loop 数据；
- 禁止旧 valid 在停止后再次握手。

PLAY 必须从 tick 0 重新开始，不能依赖停止时保存的 synthesis phase。

## 5. 当前 PC 操作到后端操作的映射

| 当前操作 | 上游行为 | 合成器后端行为 |
| --- | --- | --- |
| RECORD | 准备 shadow、清空选定轨道 | 清空/静音目标 track 的新事件，等待录音提交 |
| OVERDUB | 复制 active 到 shadow 并叠录 | 保留当前 voice 到安全边界，之后使用新 active 事件 |
| STOP | abort/flush、停止调度 | 紧急清 FIFO、ALL_NOTES_OFF、冻结输出 |
| PLAY | 从 tick 0 启动 scheduler | 清零 transport phase，按事件驱动 32 voice |
| COMMIT | 在 Loop boundary 交换 bank | 在边界锁存新 patch 和新事件 bank |
| CLEAR_TRACK | 编辑 shadow 并提交 | 下一个安全边界关闭该 track voice |
| CLEAR_ALL | 清空 shadow 并提交 | 下一个安全边界关闭全部 voice |
| SELECT_TRACK | 修改模式控制的目标轨道 | 改变录音/编辑目标，不改变现有发声所有权 |
| BPM | 在启动或边界锁存 | 只改变下一 Loop 的 tick/sample 映射 |
| Lead 旋钮 | 修改 synth shadow config | APPLY/边界时更新 Lead patch，不重写 EventTable |
| MUTE/SOLO | 合成器控制层操作 | 只改变 track bus gain，不删除事件 |
| RENDER | PC 离线命令 | 使用同样的 event/voice/lane 状态生成 WAV/stems |

这样用户在 Capture & Loop UI 里做的是“录什么、何时提交”，在 Synthesizer Config UI 里做的是“这些事件怎么发声”。

## 6. Lead 后端设计

### 6.1 主引擎

Lead 默认使用固定点 Wave 引擎：

- triangle：相位高位折叠；
- saw：相位高位映射；
- square：相位比较；
- sine：固定 LUT；
- 可选 FM-2OP：一个调制器和一个载波。

FM 不改变 note/tick，只改变 oscillator phase input。Wave 和 FM 两种模式共用 ADSR、glide、vibrato、voice ownership 和 telemetry。

### 6.2 UI 旋钮

Synthesizer Config UI 的 Lead 面板提供：

    Engine          Wave | FM-2OP
    Timbre Bank     Clean | Bright
    Waveform        triangle | saw | sine | square
    Brightness      0..1
    Drive           0..1
    Glide           0..1
    Attack          1..2000 ms
    Decay           1..4000 ms
    Sustain         0..1
    Release         1..4000 ms
    Vibrato Rate    0..12 Hz
    Vibrato Depth   0..100 cents
    Vibrato Delay   0..1000 ms
    Z → Brightness  -1..1
    Z → Space       -1..1
    Proximity Gain  -1..1
    Cursor → Gain   -1..1
    Delay Send      0..1
    Harmony Send    0..1

旋钮写入 shadow config。显示值同时给出人类单位和量化后的 Q 值，便于 PC 与 RTL 对照。

### 6.3 表达约束

- velocity 影响起音增益；
- glide 影响 NOTE_REVOICE 的相位步进逼近；
- vibrato 影响相位偏移；
- z_norm 影响 brightness、space 或 modulation depth；
- proximity 影响 gain；
- cursor_gain 影响连续动态；
- color_layer 选择有限音色 bank。

任何旋钮和表达字段都不能产生 NOTE_ON、修改 note 或改变 tick。

## 7. 配置和接口

### 7.1 合成器控制命令

独立插件内部命令：

    CONFIG_BEGIN
    SET_GLOBAL
    SET_LEAD_PATCH
    SET_TRACK_PATCH
    SET_MUTE
    SET_SOLO
    APPLY_AT_BOUNDARY
    RENDER
    STOP
    RESET

未来映射到 FPGA CSR/UART 时，命令仍采用 valid/ready 或 mailbox 语义。配置使用 shadow/active 双版本，避免部分配置生效。

### 7.2 EventTable adapter

adapter 读取现有 EventTable 的：

    type, track, tick, duration, note, velocity
    color_layer, z_norm, proximity, cursor_gain
    pitch_bend, amp_mod, timbre_mod, diagnostic_refs

adapter 不重排 Loop 事件，不重新解释 XYZ。它为缺省字段填充 patch 默认值，并生成稳定 event_id/order。

### 7.3 PC renderer

PC renderer 必须模拟以下硬件边界：

- event FIFO 有限深度；
- 32 voice slots；
- 8 synthesis lanes；
- NOTE_OFF 优先于 NOTE_ON；
- Loop boundary 和 ALL_NOTES_OFF；
- shadow/active config 在边界切换；
- 32 voice 混音保护位；
- 固定点 delay/echo/harmony；
- telemetry 采样。

渲染时间可以比实时慢，但输出状态转移不能依赖系统墙钟或线程调度。

## 8. 验收和测试

### 8.1 Loop 语义

- 六轨事件按 scheduler 顺序进入 backend；
- NOTE_OFF duration 只关闭拥有者；
- boundary 不混用新旧 bank；
- STOP 后没有旧 NOTE_ON；
- OVERDUB 保留未编辑轨；
- CLEAR_TRACK/CLEAR_ALL 只影响目标轨；
- event FIFO 背压不跳 tick。

### 8.2 并行能力

- 32 个同时 NOTE_ON；
- 8 lane 同时输出；
- voice bitmap 与 active count 正确；
- 33rd NOTE_ON 产生 voice_exhausted；
- 32 voice 与 4 voice profile 的输出差异可解释；
- lane 统计能定位峰值、乘法器和 LUT 资源。

### 8.3 音频

- Clean/Bright 频谱中出现独立主峰；
- glide 不重新触发 ADSR；
- vibrato 频偏在配置范围内；
- Z 变化不改变 note/tick/event_count；
- delay/echo/harmony 有界；
- clipping 和 RMS/peak 诊断稳定；
- 同一输入和配置的 render hash 一致。

### 8.4 延迟和可视化

- event_latency_samples 不超过扩展目标；
- 音频路径达到 <5 ms 的设计预算；
- waveform_probe、frequency_peaks、active_voice_count 可在 PC UI 显示；
- telemetry 读取不改变音频结果。

## 9. 分阶段实现

### 阶段 A：PC 事件驱动参考后端

- EventTable adapter；
- bounded event FIFO；
- 32 voice manager；
- 8-lane fixed-point oscillator；
- Lead patch 和旋钮配置；
- deterministic mix/stems；
- telemetry 和 golden vector。

### 阶段 B：Loop 对齐控制模型

- shadow/active config；
- boundary apply；
- STOP/FLUSH；
- RECORD/OVERDUB/CLEAR 的后端状态映射；
- 32 voice stress tests。

### 阶段 C：RTL/FPGA adapter

- 事件流 valid/ready；
- lane bank；
- voice manager；
- effects RAM；
- CSR/UART command mapping；
- synthesis, P&R, timing and board tests。

### 阶段 D：扩展接口

- LED cue telemetry；
- beat assistant；
- Bluetooth/App command adapter；
- score download and recording playback metadata。

每个阶段单独提交设计/接口文档、测试和验证结果，不修改 Capture & Loop 主流程。

## 10. 设计取舍

这个后端把“Loop 操作”和“声音表现”分开：

- Loop scheduler 决定什么时候发生什么事件；
- voice manager 决定事件占用哪个固定声部；
- synthesis lanes 并行产生每个 sample；
- UI patch 只决定声音参数；
- effects 和 telemetry 在下游独立运行。

这比把所有事件重新展开成一段 PCM 更能体现 FPGA 的并行、流水和确定性，也能直接复用现有 Loop 控制层的边界语义。

