# Melodic Synthwave Lead 设计讨论稿

> **主规范引用**：当前 Lead 的音阶、Baseline/Advanced 两级编译、phrase 小节映射、confidence 和事件上限以 [系统主规范](mgc3130-melodic-synthwave-system-design-2026-10-19.md) 为准；本文保留 Lead 算法讨论细节。坐标与校准统一见 [坐标与校准规范](mgc3130-coordinate-calibration-spec.md)。

> **PC 第一阶段**：曲线到旋律的实验优先遵循 [Lead 曲线意图提纯设计](pc-lead-intent-purification-design-2026-10-19.md)，先验证动机、地标、时间模型、和声闭合和可解释回放，再扩展完整六轨能力。

状态：风格已冻结，算法仍为讨论稿。本文只讨论六轨道系统中的 Lead 主旋律轨道。Bass、Pad、Arp、Drums 和 Texture/FX 的录制语义已经单独记录，本阶段不让它们反向限制 Lead 的表达设计。Loop 播放时的手势表现层只调制 Lead 或其他已有声部，不新增 Lead 乐句。

## 0. Synthwave Lead 目标

Lead 的首版目标是有明确动机的旋律型 Synthwave，而不是纯 Ambient 的自由漂浮线条：4/4、默认 100 BPM、`i–VI–III–VII` 八小节循环、小调五声为主、1.5–2 个八度、高潮在 60%–75%，末音回到主音。Ambient 只保留为音色和表现约束：长尾、渐变、适度留白和不刺耳的音符连接。

## 1. Lead 的职责

Lead 是唯一把完整三维手绘轨迹编译成旋律的轨道。它需要同时完成两件事：

1. 让听者能听出操作者画出的方向、拱顶、停留、释放和重复动作；
2. 把传感器误差和不规则动作整理成可循环、可和声约束的 Synthwave 乐句。

Lead 不应把每一个采样点直接变成一个音符，也不应让 Synthwave 模板完全替代操作者的曲线。

## 2. 曲线的音乐分工

将三维轨迹转换为局部音乐坐标：

```text
u：乐句进度和结构位置
v：旋律轮廓与方向
w：表现力、力度和音色控制
```

建议的默认分工：

| 曲线信息 | Lead 音乐结果 |
| --- | --- |
| `u` 的推进 | 句内段落顺序和事件相对位置 |
| `v` 的高低 | 音高轮廓、级进方向和音域位置 |
| `dv/du` | 上行、下行、重音和装饰倾向 |
| `d²v/du²` | 拱顶、谷底和转折 |
| 速度大小 | 起音强调、装饰和短时值倾向 |
| 停留时间 | 长音、延音或休止 |
| `w` 与深度速度 | velocity、滤波、混响、延迟和 LFO 深度 |
| 三维回绕 | 动机重复、变奏或声像移动 |

这意味着 Lead 至少需要两条输出通道：

```text
离散旋律事件：note、tick、duration、articulation
连续表达控制：pitch bend、velocity、cutoff、send、LFO、pan
```

## 3. 需要避免的过度约束

Synthwave 规则应提供风格方向，而不是抹掉曲线意图。以下规则采用“固定首版目标 + 可调强度”：

- 小调五声：默认强吸附，但允许弱拍 2/6 级经过音；
- 节奏密度：四分音符、八分音符和附点八分音符为主，保留少量二分音符长音；
- 动机重复：首轮和次轮保留相同骨架，后半段允许八度、时值或结尾变奏；
- 和声循环：优先服从 `i–VI–III–VII` 的当前和弦角色；
- 和弦音：强拍高权重，弱拍只做软惩罚；
- 高潮位置：默认目标 60%–75%，但清晰的曲线拱顶优先保留；
- 末音主音：默认终止式，另保留开放式结尾选项；
- 音域：默认 1.5–2 个八度，超出时优先压缩而不是截断；
- 跳进：默认惩罚，曲线出现明显大幅转折时允许跳进；
- 重复音：默认减少，曲线停留或重复动机时允许保留。

Lead 的主要控制参数建议为：

```text
contour_fidelity
landmark_fidelity
harmony_snap
rhythm_quantize
density
rest_ratio
cadence_strength
register_center
tension
articulation_amount
```

## 4. Lead 流水线

```text
原始 XYZ + 时间戳
  → 有效性和三维离群检测
  → 三维弧长与时间双参数化
  → 局部音乐坐标 u/v/w
  → 平滑、导数、停留和曲率特征
  → 卷积地标
  → 乐句分段
  → Synthwave 句法候选
  → 有界半马尔可夫 Viterbi
  → 旋律事件和表达控制点
```

三维弧长用于判断轨迹结构，真实时间用于判断停留和动作速度。两者不能合并为单一进度，否则慢速停留和快速经过会被误判成相同结构。

## 5. 地标不是音符

卷积检测到的上行、下行、拱顶、谷底、平台、释放和重复只应成为约束或候选段边界：

```text
上行地标   → 要求旋律段总体上行
拱顶地标   → 候选高潮或高点长音
平台地标   → 长音、重复音或休止
释放地标   → 句尾收束、下降或延迟尾音
重复地标   → 动机重复或小幅变奏
```

最终音高、时值和起音仍由全局规划器决定。这样可以避免曲率噪声直接制造密集音符。

## 6. 旋律规划状态

建议使用有限状态的半马尔可夫规划器。每个状态表示一个音乐段，而不是一个原始采样点：

```text
segment_index
note
duration
previous_interval
chord_role
phrase_state
articulation
```

`phrase_state` 至少包含：

```text
opening
development
apex
release
cadence
```

代价项包括轮廓、地标、和声、跳进、重复、音域、时值、密度、高潮和终止。硬约束只保留真正不能违反的条件，例如事件容量、非法音高和 Loop 边界；风格规则优先使用有限惩罚。

## 7. Lead 事件模型

单个 Lead 音符不应只保存 MIDI 音符和 duration。PC 参考事件至少包含：

```text
tick
duration
note
velocity
articulation
pitch_bend_start
pitch_bend_end
cutoff_start
cutoff_end
reverb_send
delay_send
confidence
source_landmarks
```

其中 `source_landmarks` 用于调试和回放，不一定进入最终 FPGA 音频事件总线。连续参数可压缩为稀疏控制点，不能为每个 50 MHz 时钟周期保存一个值。

## 8. 已冻结的 Synthwave Lead 决策

1. 节奏以曲线地标间距为意图来源，Synthwave 模板提供四分、八分和附点八分时值候选。
2. 高潮目标固定在全曲 60%–75%，清晰的操作者拱顶可以覆盖软目标。
3. 默认主音终止；首版不开放完全悬置结尾，避免 Synthwave 循环失去落点。
4. 允许滑音和连续音高作为表达层，但旋律事件仍使用离散小调五声音阶音。
5. 停留优先生成长音；只有停留置信度低且前后速度都低时才生成休止。
6. 轮廓保真与和声稳定由 `contour_fidelity` 和 `harmony_snap` 分开调节，强拍和弦约束优先。
7. 曲线起点和终点吸附到 Loop 结构边界，并保留可配置的前后短留白。
8. 允许有限的 grace/note-repeat，但每个 16 分 tick 的 Lead 事件数受限，避免变成高速 EDM 线条。

## 9. PC 验证输出

Lead 参考程序需要同时输出：

```text
lead_trace.json          归一化轨迹和 u/v/w
lead_features.json       速度、曲率、停留和卷积响应
lead_landmarks.json      地标及置信度
lead_template.json       句法和段落候选
lead_events.json         最终旋律与表达控制点
lead_render.wav          Lead 单轨试听
```

六轨合成试听放在 Lead 单轨稳定之后，避免其他轨道的音色和节奏掩盖 Lead 算法问题。

## 10. PLAY 中的 Lead 表现

Lead 事件表在 PLAY 中保持只读。手势可以作用于 Lead 的临时表现层：

```text
基础 note / duration
  + 包络宏
  + cutoff / resonance
  + pitch bend / vibrato
  + reverb / delay send
  + pan / width
```

这些变化不重新运行旋律规划器，也不新增音符。瞬时手势在当前声部或下一安全节拍施加 envelope/timbre 宏；锁存手势保持到再次触发或 STOP。连续 XYZ 只作为带限幅的表达控制，避免手抖直接造成音符重排。

### 10.1 SDK 坐标校准与动作相对起点

GestIC SDK 的自动校准和强制校准用于设备的 DSP/电极基线，不提供将任意当前位置设为 XYZ 原点的应用 API。`gestic_touch_center` / `gestic_tap_center` 是中心电极事件，不是坐标重心化；SDK 也没有通用的“每次手势从中心点开始”选项。

Lead 录制和 PLAY 表现层因此分别使用应用层参考点：进入模式后等待 neutral 稳定若干帧，锁存 `x0/y0/z0`，之后使用差值 `x-x0`、`y-y0`、`z-z0` 作为局部音乐坐标，并施加 dead zone、平滑和 slew 限制。参考点只在显式重新校准、退出模式或 STOP 时更新。不能在每个报告上移动中心，也不应在手运动时调用 `gestic_force_calibration()`。

## 11. 当前建议

先冻结 Lead 的中间表示和可调参数，再实现算法。第一版 PC 验证不追求一次得到唯一“正确旋律”，而是要求同一条曲线在参数变化时产生可解释的旋律变体：方向不变，拱顶位置基本不变，停留仍然形成空间，和声保持稳定，旋律密度和开放程度可以被用户控制。
