# Melodic Synthwave 合成器：当前讨论记录与 FPGA 原生目标架构

> **主规范引用**：当前产品与算法决策以 [MGC3130 Melodic Synthwave 交互合成器系统设计](mgc3130-melodic-synthwave-system-design-2026-10-19.md) 为准；本文保留 FPGA 架构推演和历史讨论。坐标与校准统一见 [坐标与校准规范](mgc3130-coordinate-calibration-spec.md)。

状态：风格已冻结，架构仍为讨论稿。本文记录 2026-10-19 前已经形成的判断，并明确 PC 参考实现与最终 FPGA 产品架构的边界。它不是 FPGA RTL 实现计划，也不把尚未评审的资源数字当成承诺。

## 0. 已冻结的音乐风格

产品风格从“纯 Ambient”收敛为 **Melodic Synthwave**：使用 Synthwave 的稳定四拍、脉冲低音、复古合成器音色和明确旋律，同时保留 Ambient 的长混响、长延迟、渐变包络和空间留白。后续算法、轨道映射和试听验收都以此配置为默认目标。

| 项目 | 固定首版值 |
| --- | --- |
| 拍号/Loop | 4/4，8 小节，128 个 16 分 tick |
| 速度 | 默认 100 BPM，可调范围 90–120 BPM |
| 网格 | 直拍 16 分网格，默认 swing 50%；需要律动时最多放宽到 54–56% |
| 调性 | 小调；Lead 以小调五声为主，弱拍可加入 2/6 级经过音 |
| 和声 | 默认 `i–VI–III–VII`，A 小调示例为 `Am–F–C–G`，每和弦 1 小节，循环两次 |
| Lead | 1.5–2 个八度，动机重复与变奏并存，高潮目标 60%–75%，末音回主音 |
| 空间 | 大混响、500 ms 以上长延迟、慢速滤波 LFO；保留明显尾音 |

Ambient 规则仍作为表现层约束：不追求密集音符，长音、渐变和留白优先；但节奏骨架、Bass 和 Drums 必须比纯 Ambient 更明确。

## 1. 已确认的产品行为

- 产品模式先固定为 **CAPTURE & LOOP**，暂不实现 LIVE 音符触发。
- 操作者画完一整句后，系统判断乐句结束；随后运行完整 Synthwave Lead 算法，生成六轨 Loop。
- 曲线表达旋律轮廓、动作结构和表现力；固定节拍网格表达节奏，二者使用独立时钟域。
- 目标风格固定为 Melodic Synthwave：小调五声主旋律、四拍节奏、脉冲低音、`i–VI–III–VII` 和声循环、适度留白、高潮位于全曲约 60%–75%、主音终止，并保留 Ambient 空间效果。
- 只有 Lead 直接跟随完整手绘轨迹；Bass、Pad、Arp、Drums 和 Texture/FX 都是独立录制轨道，不由 Lead 或模板自动派生。它们由 MGC3130 的 Touch/Tap 事件逐轨触发和记录。第六轨 Texture/FX 暂定用于 Drone、噪声、氛围纹理和效果自动化。
- 输出是事件表，不保存音频。事件表写入 Loop 的 shadow bank，并在安全的 Loop 边界提交。

## 2. 当前 PC 参考设计

当前 PC 验证链路为：

```text
MGC3130 / FPGA 报告
    -> PC capture
    -> 弧长重采样
    -> 小环与抖动处理
    -> X 单调约束、平滑、归一化
    -> Douglas–Peucker onset
    -> 16 分网格量化与漂移补偿
    -> 音阶候选
    -> Viterbi
    -> Lead/Bass/Pad/Arp/Drums/Texture-FX 事件表
    -> FPGA shadow event bank
```

这条链路的优点是算法易改、便于观察中间结果，并已用真实 MGC3130 采集验证输入输出格式。它应继续保留为 **golden reference** 和调参工具。

它的缺点也已经明确：停止采集后，PC 才开始做几何处理、地标提取、模板生成和旋律规划。FPGA 只负责传输、Loop 存储、节拍调度和音频合成，核心“曲线变成乐句”的计算没有利用 FPGA 的并行、片上 RAM 和确定性时序。

## 3. FPGA 原生目标架构

最终产品改为以下数据流，仍然不做 LIVE 发音：

```text
MGC3130 I²C reader
    -> 采集时间戳与有效性检查
    -> 轨迹 RAM
    -> 三维固定点预处理
    -> 并行卷积/导数/停留特征
    -> 音乐地标提取
    -> Synthwave 乐句模板生成
    -> 有界半马尔可夫 Viterbi
    -> 六轨事件表写入 shadow bank
    -> Loop 边界提交
    -> loop_scheduler
    -> voice manager / DDS / mixer / I²S
```

采集阶段只记录和分析，不触发 Lead 音符。停止条件成立后启动 `phrase_compile`，编译完成才产生可播放的 shadow bank。若已有 Loop 正在播放，编译在后台进行，提交仍只能发生在 Loop 边界；首次录制则在编译完成前保持静音或继续播放预置底床。

## 4. 各级硬件职责

### 4.1 采集和轨迹 RAM

- I²C reader 输出 `xyz_valid`、XYZ、报告序号和硬件时间戳。
- 用片上 BSRAM 保存一整句的固定上限轨迹，例如 512 帧；超过上限时锁存 `capture_overflow`，保留已采集部分并拒绝继续扩展。
- 每帧保存校准坐标、有效位和帧间隔；不保存音频采样。
- 采集 RAM 使用双口：一侧写入新报告，另一侧供编译器读取。

### 4.2 三维固定点预处理

- XYZ 先转为局部音乐坐标 `u/v/w`：`u` 表示乐句进度，`v` 表示轮廓，`w` 表示深度/表现力。
- 使用 Q0.16 坐标；速度、加速度、曲率和停留时间使用 Q4.12；代价使用 Q8.8 或 Q16.16。
- 采用固定窗口 FIR/Savitzky–Golay 平滑、三维距离和 Mahalanobis 门限，抑制抖动及短小回绕。
- 小环不再依赖通用浮点几何库，而采用有限窗口、网格量化和距离门限；这样可以在 FPGA 中固定资源、固定周期地判断毛刺。
- X 的单调约束通过分段单调状态机实现：短暂反向视为抖动，超过门限才形成新的结构段。

### 4.3 并行卷积和特征

卷积用于发现局部意图，不直接决定音符。硬件并行计算以下通道：

- 位置：`u/v/w`；
- 一阶和二阶差分；
- 速度大小、曲率近似、停留计数；
- 深度变化和释放斜率。

卷积核放在 ROM，优先使用短窗口（例如 5 或 7 点）和定点系数。固定核检测上行、下行、拱顶、谷底、平台、转折、重音和释放。多个通道可映射到 DSP，窗口数据由移位寄存器提供，避免软件逐点循环。

### 4.4 音乐地标与 Synthwave 模板

卷积响应经过峰值抑制和最小间隔约束后，输出有限数量的音乐地标，建议上限 8–16 个：

```text
上行 / 下行 / 拱顶 / 谷底 / 平台 / 转折 / 重音 / 释放 / 停留
```

地标生成器再从固定 ROM 模板中选择或混合 Synthwave 句法：

- 动机起句、四分/八分脉冲、级进上行、高潮长音、级进回落、主音终止；
- 休止位置与长短音比例；
- 前四小节半终止；
- 60%–75% 的高潮窗口；
- 静态和弦 vamp 与弱拍经过音。

模板只决定结构候选，不能覆盖轨迹的方向、拱顶、停留和释放意图。

### 4.5 有界半马尔可夫 Viterbi

动态规划不再对 400 个采样点逐点解码，而对有限的音乐段/地标进行规划。候选状态包含：

```text
段索引、音高、时值、前一音程、和弦角色、段落状态
```

代价包含轮廓保真、地标保真、和弦吸附、跳进、重复音、音域漂移、时值风格、高潮位置和终止式。音阶外音、强拍非和弦音、高潮位置违规、末音非主音等作为硬约束，代价设为无穷。

硬件实现采用有限候选、定点 min-plus 运算和 BRAM 回溯指针：

- 音高候选约 25 个；
- 时值候选约 8 个；
- 和弦角色约 4 个；
- 每段只保留有限个候选；
- DSP 进行代价累加，BRAM 保存上一层代价和回溯信息；
- 编译完成后只回溯生成 Lead。Bass、Pad、Arp、Drums 和 Texture/FX 使用各自已录制的 Touch/Tap 或控制事件表；Synthwave 模板只提供全局音阶、`i–VI–III–VII` 和声、四拍节奏、Loop 结构和 FX 语境，不替用户生成这些轨道的事件。

这仍是全局规划，不是把低质量传感器采样直接量化成音符；区别在于规划器运行在 FPGA 的确定性批处理引擎中。

### 4.6 事件表和音频数据面

- 编译器只写 shadow bank；active bank 在播放期间只读。
- 逻辑事件表固定为六轨；现有 FPGA 四轨 event store 只作为旧硬件边界，不能限制 PC 参考设计的轨道自由度。六轨容量和压缩方式按 Synthwave 的 Bass/Drums 脉冲密度重新预算。
- 只有 `commit_request` 与 Loop 边界同时满足时才交换 bank。
- loop_scheduler、voice manager、DDS、mixer 和 I²S 保持硬件实时路径，不受编译器和 UART 阻塞影响。
- 编译失败、轨迹溢出、事件容量不足或硬约束无解时，丢弃 shadow，保留 active Loop，并报告可读错误码。

## 5. FPGA 优势如何被实际利用

| FPGA 特性 | 在本设计中的具体用途 |
| --- | --- |
| 并行 DSP | 三维 FIR、导数、卷积核、代价累加同时计算 |
| 片上 BSRAM | 保存整句轨迹、特征帧、Viterbi 代价和回溯指针 |
| 确定性时序 | 固定的采集、编译、量化和 Loop 边界，不依赖 PC 调度抖动 |
| 硬件时钟 | 采集时间戳与节拍网格分离，音符严格落在 16 分网格 |
| 流水线 | 采集期间预计算特征，停止后只需完成地标、模板和 DP |
| 低功耗独立运行 | 设备脱离 PC 仍能从手绘曲线生成和播放 Loop |
| 双缓冲 | 新句编译时不破坏当前正在播放的 Loop |

## 6. PC 的保留范围

PC 不再是产品运行时的必需编译器，但保留以下用途：

- 读取 FPGA trace，显示原始曲线、地标、模板和事件表；
  - 运行 Python golden analyzer，与 FPGA 固定点结果逐项比较；
- 写入音阶、模板、权重、门限和 FX 参数；
- 导出/导入事件表和测试轨迹；
- 在 FPGA 资源不足或算法迭代阶段提供离线对照。

PC 参考算法和 FPGA 算法必须共享中间表示：

```text
normalized_trajectory
feature_frames
landmarks
synthwave_phrase_template
event_table
```

## 7. 三种架构选择

### 方案 A：PC 编译，FPGA 播放（当前基线）

实现风险最低、算法修改最快，但 FPGA 只承担数据面和音频面，设备脱离 PC 后不能自行把曲线编译成乐句。

### 方案 B：FPGA 特征提取 + FPGA 受限 DP 编译（推荐）

保留 PC golden reference，同时将轨迹 RAM、定点预处理、卷积地标、Synthwave 模板和有界 DP 放进 FPGA。它最能发挥 GW5A 的 DSP、BSRAM、流水线和确定性时序，也符合 CAPTURE & LOOP 的完整语义。

### 方案 C：FPGA 采集/音频 + 软核运行编译器

算法表达力最高、移植 PC 代码较容易，但大量工作回到顺序 CPU，延迟和确定性较差，软核还会占用逻辑和片上 RAM。它可作为资源不足时的过渡，不作为首选产品架构。

当前建议冻结 **方案 B**。PC 版本先作为黄金模型，FPGA 先实现与 PC 共享中间表示的固定点子集；不把浮点、通用卷积网络或不受界限的搜索放入硬件。

## 8. 仍需在实现前确认的边界

- 单句最大采集帧数：建议先按 512 帧预算，需结合实际 GW5A 综合结果确认。
- 地标上限和 DP 候选规模：建议 8–16 个地标、25 个音高候选、8 个时值候选。
- 编译期间已有 Loop 的行为：建议继续播放 active bank，编译完成后在边界提交。
- 首句编译期间的输出：建议静音或播放固定 Synthwave 底床，不触发半成品事件。
- 复杂自交处理是否需要完整三维几何：首版采用有限窗口和门限，完整几何只保留 PC golden reference。
- FPGA 与 PC 的固定点误差验收：要求旋律方向、停留、高潮、终止和和声约束与 golden reference 一致，而不要求逐采样浮点数值相等。

## 9. 当前结论

当前 PC 原型是验证算法的工具，不是最终系统分工。最终 FPGA 应承担“从完整三维轨迹到受约束 Synthwave 事件表”的编译任务，同时继续承担严格节拍和实时音频数据面。这样既保留 PC 迭代的灵活性，又让成品 FPGA 真正负责并行计算、片上存储、确定性编译和独立运行。

## 10. 六轨道与录制语义修订

轨道采用“当前选定轨道逐轨录制”。一次录音只写一个轨道，录音结束后该轨道成为独立的 Loop 层；下一次录音选择另一个轨道，使用同一个全局 Loop 时钟继续录入。轨道之间不共享事件，不把 Lead 的旋律或任何模板结果复制到其他轨道。

六条逻辑轨道为：

```text
Lead       三维轨迹编译的主旋律
Bass       Touch/Tap 独立录制的低音
Pad        Touch/Tap 独立录制的和弦/长音
Arp        Touch/Tap 独立录制的和弦触发与琶音模式
Drums      Touch/Tap 独立录制的鼓机 Hit
Texture/FX Touch/Tap 或控制事件录制的 Drone、噪声、纹理和效果自动化
```

Pad 和 Arp 从四轨中的复合角色拆成两条轨道。Texture/FX 目前只冻结为逻辑接口，不参与本轮 Lead 算法设计。

### Lead

Lead 录音阶段采集完整三维轨迹。停止后才执行预处理、卷积地标、Synthwave 句法选择和有界半马尔可夫 Viterbi。Lead 的输出必须保留曲线的方向、拱顶、停留、释放和高潮位置，并满足小调五声、音域、四拍动机和主音终止约束。

### Bass、Pad 与 Arp

Bass、Pad 和 Arp 录音阶段不运行曲线旋律编译器。每次有效 Touch/Tap 事件产生一个独立的轨道触发事件；触发时的 XYZ 只用于该轨道自己的音高、力度、音色或和弦 voicing 参数。这样可以让用户通过逐次触摸决定事件数量、节奏、留白和重复，而不是由 Lead 或模板补齐。

建议的首版语义为：Bass 用触摸时的 `Y` 选择受音阶约束的低音，`Z` 产生力度；Pad 用触摸时的 `Y` 选择和弦 voicing，`Z` 控制力度和滤波；Arp 用触摸事件触发用户选择的 voicing 与 Arp 模式。它们都保留真实触发的 tick、duration 和参数。

### Drums

Drums 使用 Touch/Tap 的电极信息作为鼓机输入。默认采用 5 个电极的粗映射，分别映射到底鼓、军鼓、闭镲、开放镲和额外打击音；如果实际操作证明需要更细的空间表达，再增加起始位置的 3×3 映射。

- `touch_flags` 表示持续触摸状态，只用于按下/释放边沿和去重；不能每帧重复生成鼓点。
- `tap_flags` 的单击位产生立即 NOTE_ON；双击位产生第二个触发或预定义 roll/flam 事件。
- 速度由接近速度或 Z/深度变化估计，首版保留为可替换映射。
- 最小触发间隔建议为 30–50 ms，防止同一触摸抖动重复触发。

## 11. PC 验证计划修订

本阶段不预先制造人工合成测试集，也不把合成轨迹当作真实验收依据；但必须支持“真实 MGC3130 录制一次、保存 raw capture、离线反复回放调参”。真实会话仍是最终交互验收依据，CaptureSession 回放是 Lead 编译器和跨轨量化的可复现迭代基础。

PC 参考程序按以下顺序实现：

1. **SDK 输入适配层**：保留现有 GestIC SDK 32 位 Win32 接收器，输出位置、`touch_flags`、`tap_flags`、时间戳和帧号；确认 Touch Detection、TouchInfo 和 tap 字段在设备上的实际启用状态。
2. **事件归一化层**：把 SDK 每帧转换为 `position_frame`、`touch_press`、`touch_release`、`single_tap`、`double_tap`，对持续 Touch 做边沿检测，对 tap 位做一次性去重，并保留触发时 XYZ。
3. **逐轨录音控制器**：由当前选定轨道决定输入解释方式；Lead 进入曲线采集状态，其他轨道进入 Touch/Tap 事件录制状态。所有轨道使用统一 BPM、128 tick Loop 时钟、量化和累积漂移补偿。
4. **Lead 编译器**：只对 Lead 运行三维鲁棒预处理、局部卷积、音乐地标、Synthwave 模板和有界半马尔可夫 Viterbi。
5. **Bass/Pad/Arp 录音器**：分别记录用户实际触发的 Touch/Tap 事件，按轨道规则把触发时 XYZ 映射为音高、和弦、力度、duration 和表达参数；不从 Lead 推导事件。
6. **Drums 录音器**：把电极和单击/双击映射成鼓机事件，执行防抖、边沿去重和最小触发间隔；每次触发保留原始电极、tap 类型和量化结果。
7. **独立轨道合并器**：只按 tick 合并六个已录制轨道，保留每个事件的 `source`、`trigger`、`electrode` 和量化误差，禁止自动填充缺失轨道。
8. **PC 音频试听器**：使用六种不同的合成器角色和 Synthwave + Ambient FX 渲染 WAV，检查旋律、低音脉冲、鼓点响应、和声循环、空间尾音和轨道独立性。
9. **真实操作验收**：完成上述模块后，再进行连续真实操作：先录 Lead，再分别录 Bass、Pad、Arp、Drums 和 Texture/FX，最后播放合并 Loop；根据实际手感调整触摸门限、Tap 去重、轨道映射和量化策略。

中间表示改为：

```text
PositionFrame
TouchEvent
LeadTrajectory
LeadPhraseTemplate
RecordedTrackEvent
EventTable
```

其中 `RecordedTrackEvent.source` 必须区分 `trajectory` 和 `touch/tap`，并保留 `track`、`tick`、`duration`、`note`、`velocity`、`amp_mod`、`timbre_mod`、`touch_flags`、`tap_flags`、`electrode` 和 `quantization_error`。

## 12. PLAY 阶段的手势表现层

`PLAY` 阶段不把手势解释为新乐句或新轨道事件。它只在当前 active Loop 之上叠加一个临时的 `performance_mod_layer`，实时改变已有声部的包络、音色和调制参数。active event bank、shadow bank 和六轨事件数量都保持不变。

```text
active Loop events
    + performance_mod_layer
    -> voice parameters
    -> envelope / oscillator / filter / FX
```

PLAY 时的输入路由固定为：

```text
XYZ 连续位置     → 连续调制
Touch/Tap        → 瞬时或锁存宏
Gesture/Flick    → 包络或结构化表现宏
AirWheel         → 慢速调制深度/速率（若启用）
```

推荐的可配置目标包括：

- 包络：整体 swell、瞬时 gate、duck、attack/release 时间、每轨音量；
- 音色：滤波 cutoff、resonance、wavetable position、振荡器混合、失真量；
- 空间：reverb send、delay send、delay feedback、声像和宽度；
- 调制：vibrato depth、tremolo depth、LFO rate、全局 pitch bend；
- 结构表现：下一拍/下一小节触发的 stutter、freeze、反向包络或短暂 mute。

手势宏分为两种：

```text
momentary：手势有效期间生效，超时或释放后回到基线
latched：一次 Tap/DoubleTap/Flick 切换状态，再次触发或 STOP 恢复
```

连续 XYZ 和 AirWheel 默认使用带限幅和 slew 的 momentary 调制；Flick、Circle、Tap 和 DoubleTap 默认触发有限时长的 envelope/timbre 宏。宏的开始方式可选择立即生效、下一拍生效或下一小节生效，以避免节奏性效果破坏 Loop 边界。

调制目标必须有轨道掩码，允许用户选择影响 Lead、Bass、Pad、Arp、Drums、Texture/FX 中的一轨、数轨或全局。Drums 默认屏蔽 pitch bend，Lead 默认允许滤波和空间调制。

参数合成顺序为：

```text
Loop 保存的基础事件参数
  → 轨道级性能调制
  → 全局性能调制
  → 安全限幅、slew 和声部保护
```

性能调制不写入 Loop RAM，不改变事件表，也不产生 `NOTE_ON`。只有明确进入 `RECORD_MODULATION` 或 Texture/FX 录制流程时，控制曲线才可以被保存为独立控制点。

当输入失联、Touch 释放或执行 STOP 时，性能调制层按轨道策略回到中性值；已有音符执行正常 release，不突然破坏 active Loop。PLAY 与 RECORD/OVERDUB 的输入解释必须互斥：PLAY 中的手势只进入表现层，RECORD/OVERDUB 中才允许写入轨道事件。

## 13. SDK 校准、中心参考与每次动作起点

已核对本机 Microchip GestIC SDK 1.2.0 的 API 和位置解析：

```c
gestic_set_auto_calibration(...)
gestic_force_calibration(...)
gestic_get_calibration(...)
```

这些接口用于 MGC3130 的 DSP/电极基线和工作状态校准。SDK 在 `PositionValid` 时把设备报告中的 XYZ 复制出来，没有提供“把当前 XYZ 设置为应用坐标原点”的接口，也没有提供“每次手势开始时自动把当前位置归零”的通用接口。

`gestic_touch_center` 和 `gestic_tap_center` 只表示中心电极的 Touch/Tap 事件，不能解释成 XYZ 坐标中心校准。固件内部的 Presence、Hand Inside、基线和手势状态可能参与有效性判断，但位置输出仍属于传感器坐标系。

因此后续设计采用三层校准语义：

```text
SDK/硬件校准       消除电极基线漂移和环境变化
应用坐标校准       轴向、缩放、neutral 区和音乐坐标映射
动作相对起点       在 Lead 录制或 PLAY 表现开始时锁存 x0/y0/z0
```

应用层的动作起点状态机约定为：进入 Lead 录制或 PLAY 后，等待手离开传感区或在 neutral 区稳定若干帧；用有效报告估计 `x0/y0/z0`，然后输出 `x-x0`、`y-y0`、`z-z0`。差值还要经过 dead zone、低通和 slew 限制。参考点保持到显式重新校准、退出模式或 STOP，手已经运动时不更新。

`gestic_force_calibration()` 不能作为每次动作的“归零”操作。它是设备基线校准，通常需要稳定的传感条件；在演奏中反复调用可能导致位置暂时无效、坐标跳变或丢失轨迹。PC 版本和后续 FPGA 版本都应把硬件校准与应用层重心化分开。

## 14. 以 Synthwave 为前提的六轨改进

六轨并不意味着六轨都要持续填满。当前风格目标是稳定四拍、明确旋律、脉冲低音与 Ambient 长尾，因此 Synthwave 模板提供小调、`i–VI–III–VII`、四拍节奏、音域和密度边界；Bass、Pad、Arp、Drums、Texture/FX 仍只接受用户真实录制的 Touch/Tap 或控制事件。

| 轨道 | 硬件/PC 共同的首版规则 |
| --- | --- |
| Lead | 三维轨迹编译为动机型旋律，四分/八分音符为主，保留方向、拱顶、停留、高潮和主音终止 |
| Bass | Touch/Tap 触发主音、八度和五度的八分/四分脉冲低音，服从当前和弦根音 |
| Pad | 一小节或两小节长和弦，长 Attack/Release，转位在小节边界提交并采用最小声部移动 |
| Arp | Touch/Tap 选择和弦和模式，默认 1/8 分解，可切换 1/16 或稀疏长音模式 |
| Drums | Touch/Tap 录制四拍骨架：Kick、2/4 拍 Snare/Clap、1/8 或稀疏 1/16 Hat；双击才形成 flam/roll |
| Texture/FX | 噪声、磁带纹理、上升/下降效果和滤波控制使用长交叉淡化、长混响和延迟 |

统一约束：事件仍由实际 Touch/Tap 产生；时间使用统一 Loop 网格，Lead/Bass/Drums 默认 1/16 或 1/8，Pad/Texture 可放宽到 1/4 或 1 小节；速度和力度保持稳定脉冲并用渐变连接；Bass、Pad、Lead、Arp/Texture 采用分层音域；缺少触发的轨道保持留白，系统不自动补事件。

PLAY 阶段只需要两类曲线：Loop 音符的 ADSR，以及由 Tap/Flick/有效速度变化触发的手势表现包络。连续 XYZ 只改变已有参数目标，不产生新的 `NOTE_ON`；表现包络可以调节已有声部的音量、滤波、混响、延迟或整体能量，并按 Synthwave 的节奏需要设置为立即、下一拍或下一小节生效。
