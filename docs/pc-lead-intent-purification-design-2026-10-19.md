# PC 实验第一阶段：Lead 曲线意图提纯设计

版本：2026-10-19  
状态：PC 实验设计记录，优先于完整六轨产品化。  
关联主规范：[MGC3130 Melodic Synthwave 交互合成器系统设计](mgc3130-melodic-synthwave-system-design-2026-10-19.md)

## 1. 这一阶段只验证什么

当前 PC 实验的第一步不是做完整工作站，也不是先验证 FPGA 资源，而是验证一个核心命题：

> 操作者画出的三维曲线，能否被提纯成一条有记忆点、和谐、可循环、并且仍然保留操作者意图的 Melodic Synthwave 主旋律。

Bass、Pad、Arp、Drums 和 Texture/FX 在这一阶段只作为可选的监听参考或简单 Touch/Tap 伴奏。它们不能反向改写 Lead 的旋律，也不应分散对 Lead 音乐身份的判断。

首阶段的成功标准不是“每个采样点都被解释”，而是：上行、下行、拱顶、谷底、停留、转折、释放和高潮能被听见；前两小节形成可记忆动机；后半段是动机变奏；和声变化可辨认；结尾能自然回到循环起点。

## 2. 创作原则

曲线到旋律采用两阶段解释：

```text
三维曲线
  → 采集意图（时间、轮廓、地标、停留、表达）
  → 意图中间表示 IntentIR
  → 核心动机
  → 句法变奏
  → 和声与音阶整理
  → Synthwave 演奏法
  → Intent / Song 两个候选旋律
```

后续的 Viterbi 或其他优化器只能在 `IntentIR` 上润色，不能绕过地标和动机重新随机写一条“正确但不像用户画的”旋律。

首版提供一个高层控制：

```text
Intent  ←────────────→  Song
保留更多原始方向与张力       强化和声、节奏和风格整理
```

默认在中间位置。底层代价权重保存到参数快照，但不全部暴露给用户。

## 3. 输入与时间模型

### 3.1 录制方式

首版使用有引导的固定八小节录制：

```text
1 小节 count-in
→ 8 小节正式录制
→ 自动停止并编译为 128 tick
```

默认 100 BPM 时正式录制为 19.2 秒。录制开始时提供 click、当前和弦根音提示、当前小节/拍/tick 和进度显示。已完成轨道或简化 ghost arrangement 可以监听，但 guide bus 永不写入 EventTable 或导出音频。

提前 Stop 时，未录制部分保持休止；手短暂离开不立即结束句子，只有持续失联或显式 Stop 才结束当前段。自由长度 Loop 留到后续，不作为首版验收路径。

### 3.2 唯一轴语义

经应用坐标校准后，Lead 使用两套**显式可切换**的轴语义。默认是容易学习的固定工作空间模式，实验模式是对任意朝向更稳定的手势对齐模式。编译器不能在两种模式之间悄悄切换。

**Workspace 模式（默认）**：

| 量 | 音乐含义 | 首版处理 |
| --- | --- | --- |
| `τ` | 句子时间进度 | 由时间戳归一化到 0–1；它是唯一的节拍顺序，不把空间 X 重新排序为音乐时间 |
| `v` | 固定旋律空间的音高坐标 | 使用校准 profile 的绝对物理边界映射到固定音级表，再量化为音符 |
| `w` | 空间和声颜色与表达 | 低频部分参与同一注册区的和弦层选择，高频部分控制 accent、gate、滑音和释放 |
| `x/h` | 乐句空间轴 | 只控制段落、密度、gate、回撤和释放标记，不改变音高注册区 |

**Gesture-Aligned 模式（实验）**：把本次录制视为一条有起点、有终点、按时间经过的三维开放路径。使用首尾稳健窗口求得 `q0`、`q1`，并计算：

```text
e = normalize(q1 - q0)
p = normalize(g - dot(g,e)e)
d = cross(e,p)
a_rel = dot(q-q0,e)
b_abs = dot(q-q_ref,p)
c_abs = dot(q-q_ref,d)
```

其中 `g` 是校准得到的应用“上方”方向，`q_ref` 是固定工作区参考点，`a_rel` 是开放路径的前进/回撤，`b_abs` 是固定旋律轮廓，`c_abs` 是和声颜色。实际节奏始终由时间戳决定，`a_rel` 不用于重新排序采样点，也不作为音高零点。若端点位移过小、`e` 与 `g` 近共线或方向退化，则回退到 Workspace 模式并记录诊断原因。大转弯路径可使用 Bishop/parallel-transport frame 更新局部姿态，避免 Frenet frame 在低曲率区翻转。

空间几何仍用于识别转折、拱顶、回绕和停留，但不允许同一份数据在不同轨道或模式中悄悄换一套轴定义。XY 相交但 Z 明显分离时不判作自交毛刺；只抑制短小回绕，大范围回绕保留为装饰或结构标记。

### 3.3 节奏与停留

真实时间决定停留和动作速度，弧长只用于判断轮廓和结构。最终 tick 为：

```text
tick = round(elapsed_seconds × BPM / 60 × 4)
```

停留、释放和最短动作时长先换算为 beat/tick，再参与音符时值和休止判断；不使用与 BPM 无关的固定“长音毫秒阈值”。onset 量化强度可调，默认保留少量相对时长和人性化偏移。

## 4. 意图中间表示 IntentIR

`IntentIR` 是算法与创作者之间的可解释边界。每个地标至少包含：

```text
kind: start | ascend | descend | apex | valley | hold |
      turn | release | rest | accent
time_start, time_end, tick_start, tick_end
segment_index
direction
v_level, w_level
confidence
source_frame_range
```

地标提取顺序为：有效帧过滤 → 短窗口去抖 → 弧长/时间重采样 → 小回绕抑制 → 平滑 → 方向和停留检测 → Douglas–Peucker 结构点。每个最终音符必须能回指一个或多个 IntentIR 地标；没有来源的装饰音只能在 Song 候选中少量出现，并且必须标记为生成音。

## 5. 动机提取与八小节句法

### 5.1 核心动机

从第 1–2 小节的高置信地标中提取 2–4 个核心音，保存：

```text
音程方向与大小
节奏骨架
停顿位置
起音/释放轮廓
来源地标
```

动机不是简单复制音高，而是保留“方向 + 节奏 + 停顿”的身份。若前两小节过于平坦，系统生成最少的级进动机，并在诊断中标记 `weak_motif`，不能假装提取成功。

### 5.2 固定句法

| 小节 | 旋律任务 |
| --- | --- |
| 1–2 | 首次提出并确认动机，保留低/中音域和原始轮廓 |
| 3–4 | 动机发展，向 G 和弦的半终止推进 |
| 5–6 | 动机移调、尾部变形或节奏稀释，但保持可识别回忆 |
| 7 | 高潮变体，允许扩大音域或延长高点 |
| 8 | 回收、释放并为下一轮准备 |

动机回忆是 Advanced 的软约束，但在 Intent 候选中优先级高于装饰性和声优化。验收时要能听出第 5–6 小节与前两小节有关系，而不是八小节随机生成八组音。

## 6. 连续轮廓到具体音高

`v` 或开放路径中的 `b_abs` 不直接变成 MIDI note，而是先映射到一个在录制开始前已经锁定的固定 `PitchSpace`。默认禁止用本次曲线的 `min/max` 或 `5%/95%` 分位数重新缩放音域；否则同一物理高度会因每次手势幅度不同而得到不同八度。

默认流程为：

```text
固定校准空间 q_app
  → 固定 pitch_axis 与 q_ref
  → 固定物理边界 b_min / b_max
  → 连续音级目标
  → 固定音阶音级表 P
  → 带滞回的音级量化
  → 音阶/和弦/拍位/动机筛选
  → 最终音符
```

首版默认配置：A4=440 Hz、12-TET、A 小调五声，中心音 E4，固定范围 G3–C5（17 个半音）。录制前可显式选择另一组中心音或跨度，但录制和编译过程中不能改变。超出范围时饱和到边界并记录 `out_of_range`，不能做 modulo octave 或静默换注册区。

强拍优先当前和弦音；弱拍优先小调五声和级进经过音；挂留、经过和短暂张力可存在，但必须有级进解决。音高计算使用半音数/音阶级数，不能用线性频率映射。

按本次曲线的 5%/95% 范围压缩只保留为显式 `Adaptive PitchSpace` 实验模式。它必须在 UI 中明确标出，并生成新的 `pitch_space_id`；不能作为默认模式，也不能与固定旋律空间的验收结果混用。

## 7. 和声、终止与 Loop 边界

首版固定 A 小调 `Am–F–C–G`，每和弦一小节、循环两次：

| 小节 | Tick | 和弦 |
| --- | --- | --- |
| 1 | 0–15 | Am |
| 2 | 16–31 | F |
| 3 | 32–47 | C |
| 4 | 48–63 | G |
| 5 | 64–79 | Am |
| 6 | 80–95 | F |
| 7 | 96–111 | C |
| 8 | 112–127 | G |

编译器统一使用 `chord_index = (tick // 16) % 4`。第 4 小节是半终止。第 8 小节不能简单地在 G 和弦上硬截断主音 A；首版采用 loop-boundary anticipation：最后 1/8 的 A 作为悬挂/预示音，延续到第 1 小节 Am 后释放。该跨边界关系在 EventTable 中显式记录为 `tie/carry`，不能由播放器隐式猜测。

## 8. 演奏法与事件输出

Lead 候选事件至少包含：

```text
tick, duration, gate_ratio, velocity, accent,
legato, tie, glide, release_tail,
confidence, source_landmarks, generated_reason
```

首版使用少量、可解释的演奏法：长音保持、短音 gate、相邻级进 legato、有限 portamento、高潮 accent 和释放尾音。低置信度只降低装饰、重复和滑音概率，不删除主旋律。跨 Loop 的音符必须显式选择 carry、split 或 fade；首版 Lead 只允许 cadence 的 carry。

## 9. 两个编译候选和可听验收

同一 CaptureSession 至少生成两个候选：

- **Intent**：更保留原始方向、停顿、张力和不规则性；
- **Song**：更强调和声落点、节奏清晰和 Synthwave 句法。

Baseline 与 Advanced 也可以在同一候选框架内 A/B。编译完成后用户可以试听、接受、重新编译或重画；算法不得静默覆盖上一版结果。

UI/诊断至少能显示：raw XYZ、滤波曲线、IntentIR、动机、每个音的来源地标、和声调整原因、confidence 和最终 EventTable。

## 10. 第一阶段验收量表

使用同一份真实 MGC3130 CaptureSession 进行 A/B 试听，评分 1–5：

1. 上行/下行方向是否保留；
2. 拱顶、谷底和停留位置是否可听；
3. 前两小节动机是否可记忆；
4. 第 5–6 小节是否形成动机回忆或变形；
5. 和弦变化是否可辨认；
6. 高潮是否位于目标区间；
7. 第 8 小节到第 1 小节是否自然循环；
8. 同一输入重复编译是否稳定；
9. 是否不需要逐音编辑就能作为 Synthwave 主旋律使用。

硬性失败包括：轨迹方向反转、主要停留消失、无来源随机音符、和声索引错误、Loop 边界爆音或每次编译结果明显不同。

## 11. 目前仍需补齐的设计点

### P0：实现前必须冻结

- MGC3130 安装方向、左右手和工作区的应用坐标 profile；
- Workspace / Gesture-Aligned 两种开放路径模式及其切换语义；
- Fixed PitchSpace 契约：固定物理边界、音级表、注册区、量化滞回和越界规则；
- 起点/终点 neutral、hand-away、短暂失联和录制取消的状态语义；
- IntentIR 地标的阈值、上限和无效轨迹 fallback；
- 同一输入、参数、compiler version 和 seed 的确定性；
- EventTable 的 carry/tie、gate、glide 和 release 边界；
- Intent/Song 的少量高层旋钮及默认值，避免直接暴露十几个代价权重。

具体约定如下：

- CaptureSession 必须记录 `capture_hash`、`compiler_version`、`style_config_hash`、`random_seed`、`calibration_profile_hash`、`pitch_profile_id` 和 `pitch_profile_hash`；首版默认 seed 固定，禁止同一回放在无提示的情况下随机改变旋律或音域。
- 有效轨迹过短、有效帧比例不足或无法形成可靠动机时，返回 `INSUFFICIENT_CAPTURE` 或带 `weak_motif` 的简化结果；不能静默补写一条与输入无关的漂亮旋律。
- 轨迹基本平直时只允许输出少量级进、长音或休止；无可行 Advanced 解时先降低装饰和软约束，仍无解则返回可解释错误并保留 Baseline 候选。
- 事件超限时按“生成装饰 → 低 confidence 重复 → 低 confidence 经过音”的顺序裁剪，不能删除起句、高潮、终止和高 confidence 主音。
- Intent 候选的最低验收指标为：主要上/下行方向保留率、拱顶 tick 误差、静止段长音/休止重合率、前两小节 motif 相似度、同一输入重复编译的事件差异。指标和阈值写入诊断，不只凭听感判断。
- 高层首版只暴露 `Intent↔Song`、密度/留白、音域中心/跨度、量化强度、motif recall、表达强度六个控制；所有底层参数仍随候选保存。

### P1：PC 作品化后补齐

- 按小节 punch-in、trim、nudge 和最小 comp；
- 工程 manifest、参数快照和 candidate history；
- MIDI、六轨 stems、tempo/marker 导出；
- Scene A/B、鼓 fill 和完整六轨的作品级编排；
- BPM-sync delay、reverb、chorus 和 LFO 相位策略；
- guide bus 的独立开关和学习/示范模式。

### P2：不阻塞第一阶段

- MIDI Clock/OSC/DAW 同步；
- 自由长度 Loop、多手和多人输入；
- 复杂场景性能层、完整音色库和 FPGA 内置编译；
- 神经网络或无界搜索等更重的生成模型。

第一阶段不先解决完整工作站能力。只有当 Lead 的曲线意图能够稳定地变成可使用旋律，六轨、Scene、外部同步和 FPGA 编译才有继续投入的价值。

## 12. 简化主算法：锚点轮廓编译器

### 12.1 为什么首版不以 HSMM/Viterbi 为主流程

此前的概率模型、半马尔可夫模型和 Viterbi 全局优化可以作为后续 `Polished` 模式的研究方向，但不适合作为首版唯一编译路径。原因不是它们不能生成和谐音乐，而是它们会把许多不可见的代价权重带入结果：用户很难知道自己应该怎样画，编译器也可能把一条含义不明确的曲线“优化”为一条听起来漂亮、但不像原始意图的旋律。

首版采用可解释的锚点轮廓编译器。它只回答五个问题：曲线什么时候移动、什么时候停留、什么时候转向、什么时候释放，以及这些动作在固定音域内应当向上还是向下。每个最终音符都必须能回指一个锚点；没有来源的音符不自动补写。

### 12.2 主流程

```text
MGC3130 XYZ
  → 中值滤波、低通、异常帧剔除
  → 按真实时间重采样到 128 tick
  → MOVE / HOLD / REST 状态机
  → TURN / APEX / VALLEY / RELEASE 锚点
  → 锚点映射为连续半音目标
  → A 小调五声与当前和弦整理
  → NOTE / REST / articulation 事件表
```

预处理使用固定 HostCalibrationProfile：先做有效性、饱和和长 gap 遮罩，再用纯 Z 采集拟合的 `g_x(z)`、`g_y(z)` 去除可重复的 Z→XY 漂移，然后对三轴做 15–30 ms 中值、35–60 ms 一阶低通和 slew 限制。异常阈值由录制前的 neutral 噪声 MAD 估计；时间轴只由逻辑时间戳决定，不能用空间 X 重新排序。曲线重采样到固定 128 tick 后，所有阈值都使用 tick 或 beat 表达。纯 Z 运动和短时手抖只能降低 confidence 或改变表达参数，不能制造新的音符。

状态机规则保持简单且带滞回：速度高于噪声阈值进入 `MOVE`；速度持续低于阈值进入 `HOLD`；手进入休止区或有效帧持续不足进入 `REST`；方向改变超过方向滞回且持续至少一个最小动作窗口生成 `TURN`；离开工作区或显式结束动作生成 `RELEASE`。抖动只改变置信度，不生成新的音符。

每个锚点保存：

```text
(anchor_tick, v_level, w_level, kind, confidence, source_frame_range)
```

### 12.3 锚点到音符的确定性规则

- `MOVE` 在一个最小音符窗口内只产生一次 `NOTE_ON`；继续移动只改变后续锚点的目标音高。
- `HOLD` 延长当前音符并提高 gate，不重复触发；若保持时间不足最小长音阈值，则并入相邻音符。
- `TURN` 产生新音符或改变级进方向；转向角度不足以超过方向滞回时只保留为平滑曲线。
- `APEX` 和 `VALLEY` 保留为高点/低点标记，是否成为音符取决于其持续时间和相邻音高距离。
- `REST` 输出显式静音区间，区分主动留白、手离开和无效帧；无效帧不能被默认为休止。
- `RELEASE` 结束当前 gate，必要时产生 release tail，但不凭空添加终止音。
- 相邻锚点距离很短时合并为一个音；距离中等时保留级进或跳进；只有距离较大且时间充足时才允许插入一个经过音。
- 每个 16 分 tick 最多一个 `NOTE_ON`。最小音符、最小休止和最大装饰密度由固定风格参数控制。
- 当前和弦音优先落在强拍；弱拍允许小调五声中的级进经过音。音高始终使用半音数映射，不使用线性频率映射。

### 12.4 两种可解释编译模式

**Direct** 是默认的意图验证模式：锚点直接转换为音符，只做音阶、和弦和音域边界整理，不自动补写动机、高潮或终止。它用于判断“用户这样画，系统是否真的这样理解”。

**Polished** 在 Direct 结果上做有限整理：允许局部和弦修正、少量经过音、轻微节奏吸附和同一动机的移调/尾部变形，但不能改变主要方向、停留位置、转向顺序和动机骨架。若整理会改变这些结构，则保留 Direct 结果并报告原因。

### 12.5 给用户看的绘制语言

首版 UI 必须把下面这套语言直接显示给用户，并在录制时实时预览：

| 用户动作 | 可预期的音乐结果 |
| --- | --- |
| 手向上平滑移动 | 旋律上行 |
| 手向下平滑移动 | 旋律下行 |
| 快速转向 | 新音符或旋律转折 |
| 在一个高度保持 | 长音 |
| 进入休止区或主动离开 | 休止/释放 |
| 形成拱顶 | 高音或高潮候选 |
| 靠近传感器 | accent、滤波更亮、较长 gate |
| 远离传感器 | 更柔和、较短 gate、释放更明显 |
| 平滑连续移动 | legato 倾向 |
| 轻微抖动 | 不增加音符，只降低置信度 |

因此用户学习的是“画动作”，不是记忆隐藏参数：几何形状决定音高方向和动机，真实时间决定起音、时值和停顿，速度决定 accent/装饰倾向，深度决定表达强度。

### 12.6 必须可视化的反馈

编译过程中同时显示 raw XYZ、滤波后的 `u/v/w` 或开放路径 `a_rel/b_abs/c_abs`、状态机状态、锚点、预计音符和最终音符。每个音符点击后能看到其来源锚点、是否经过和弦整理、是否为生成音，以及 confidence。用户应能在录制后立即看到“这条线会被解释成哪些音”，再决定重画还是接受，而不是只在最终播放时猜测算法发生了什么。

这套锚点规则是第一阶段的验收基线。若 Direct 已经稳定表达用户意图，再用 Polished 增加 Synthwave 句法；复杂优化器不得在基线尚未通过前替代它。

## 13. 三维开放路径音乐化

### 13.1 问题修正

Lead 不能只把 `X` 当时间、`Y` 当音高、`Z` 当效果器参数。那种做法只使用了三维数据的三个独立投影，没有利用轨迹的方向、曲率、空间转折和深度关系。

每次录制应被定义为一条带有起点和终点、按时间经过的三维有向开放路径：

```text
q(t) = [x(t), y(t), z(t)]
```

它不是闭合图形，也不要求满足 `y=f(x)`。空间自交不等于数据错误：同一个空间位置在不同时间到达，可以代表不同的旋律事件。首版不使用闭合曲线 Fourier descriptor；时间戳始终保留路径顺序。

### 13.2 两种路径坐标模式

**Workspace 模式是默认模式。**它使用校准后的固定应用坐标，适合学习和重复演奏：垂直的固定音高轴控制主旋律，水平的乐句轴控制段落密度、gate 和回撤，深度方向控制同一注册区内的和声颜色。句子的实际节拍位置只由时间戳决定。该模式不会因每次曲线的起点、终点或整体旋转而偷偷改变音高语义。

**Gesture-Aligned 模式是实验模式。**它让同一形状在工作区不同朝向下仍保持相同音乐含义。首尾各取一段稳健窗口，得到 `q0` 和 `q1`，以首尾方向建立开放路径坐标：

```text
e = normalize(q1 - q0)
p = normalize(g - dot(g,e)e)
d = cross(e,p)

a_rel = dot(q-q0,e)
b_abs = dot(q-q_ref,p)
c_abs = dot(q-q_ref,d)
```

`g` 是校准得到的应用上方向；`q_ref` 是固定工作区参考点；`a_rel` 是沿路径的前进/回撤，`b_abs` 是固定旋律空间中的绝对音高坐标，`c_abs` 是和声颜色坐标。实际节奏仍由时间戳决定，`a_rel` 不重新排序采样点。若首尾位移过小、`e` 与 `g` 接近共线或 PCA 退化，则回退到 Workspace profile，并写入诊断信息。需要跟踪大转弯路径时使用 Bishop/parallel-transport frame，避免 Frenet frame 在低曲率区域翻转。

路径模式的符号必须由安装方向和左右手 profile 固定。不能让同一条曲线因为 `cross(e,p)` 的符号任意翻转而突然变成相反的和声色彩。

### 13.3 几何特征与音乐地标

对过滤后的开放路径做弧长参数化，并使用 Savitzky–Golay 或等价的稳健局部拟合计算导数。只使用成熟的几何特征，不用黑箱模型猜测意图：

```text
速度       |dq/dt|
弧长       s(t)
切向       T(t)
曲率       κ(t)
深度速度   dc/dt
音高方向   sign(db/dt)
```

地标规则为：

| 几何特征 | IntentIR 地标或音乐含义 |
| --- | --- |
| `db_abs/dt` 持续为正 | 上行片段 |
| `db_abs/dt` 持续为负 | 下行片段 |
| `db_abs/dt` 符号改变 | `TURN`，新音符候选 |
| `b_abs` 局部极大/极小 | `APEX` / `VALLEY` |
| 路径速度低且稳定 | `HOLD`，延长当前音 |
| 曲率局部峰值 | 结构转折或起音边界 |
| `c_abs` 跨越深度带并保持 | 和声色彩层切换 |
| `da_rel < 0` 持续发生 | 回撤，可表达释放或动机回忆 |
| 进入休止区或有效帧中断 | `REST`，不得静默补音 |

曲率提取前先去除 1–2 mm 或 2σ 以内的重复点；曲率平滑窗口默认 80–120 ms。`TURN` 默认要求方向变化超过约 25° 且持续至少 60 ms；`HOLD` 默认要求速度低于噪声阈值并持续约 120 ms。轻微抖动只降低 confidence，不产生新音符。

### 13.4 三个空间量到音乐参数

`b_abs` 产生主旋律目标，但不是逐帧直接输出音高。它先映射到固定音域内的连续音级目标，再从当前小调五声和当前和弦候选集中选音。`c_abs` 只在同一固定注册区内选择和声色彩，不得改变八度。

`c_abs` 的低频部分分成三个带滞回的和声颜色层：

```text
c_abs < -阈值：暗色层，根音、五度或低邻音
中间区域：主轮廓层，当前旋律音
c_abs > +阈值：亮色层，三度、七度、九度或 sus 延伸
```

深度层切换需要跨越 10–15% 工作区的滞回带并保持足够时间，避免 MGC3130 噪声造成和声颤动。`c_abs` 的快速变化使用 `dc_abs/dt` 控制 accent、glide、滤波亮度和 release 强度，而不是额外制造大量音符。

`a_rel` 用于识别空间前进、回撤和路径速度。沿路径的速度可以改变 gate 和装饰密度；明显回撤可以标记为释放、返回或动机回忆，但不能把时间顺序改写成空间排序。

### 13.5 空间路径到音符的简单语法

每个结构锚点只从有限候选集合中选音：当前调式音阶、当前和弦音、附近级进音和固定音域。选择规则按以下顺序执行：

1. 强拍优先当前和弦音；
2. 弱拍允许小调五声经过音；
3. `b_abs` 决定上行/下行方向和目标音高；
4. `c_abs` 决定和声颜色层；
5. 与前音距离过大时优先级进，单次跳进默认不超过约 7 个半音；
6. 只有时间充足时才允许插入一个经过音；
7. 每个 16 分网格最多一个 `NOTE_ON`；
8. 所有音符必须回指一个或多个空间地标。

`HOLD` 延长当前音，`TURN` 触发新音符，`APEX/VALLEY` 只有在停留足够或相邻音高差足够时才独立成音，`REST` 生成显式静音区间，`RELEASE` 结束当前 gate。该语法优先于全局优化器，保证用户能预测“怎样画会得到什么”。

### 13.6 用户绘制语言与反馈

UI 必须将空间语义直接显示出来：

| 用户动作 | 预期音乐结果 |
| --- | --- |
| 沿主旋律轴平滑向上 | 旋律上行 |
| 沿主旋律轴平滑向下 | 旋律下行 |
| 快速改变方向 | 新音符或转折 |
| 在某高度保持 | 长音 |
| 形成拱顶或谷底 | 高点/低点候选 |
| 穿过深度颜色带 | 和声层变化 |
| 深度快速靠近 | accent、亮度或滑音增强 |
| 沿路径回撤 | 释放或动机回忆 |
| 进入休止区 | 明确留白 |

录制和编译界面同时显示 raw XYZ、过滤后的三维路径、`a_rel/b_abs/c_abs` 轨迹（Workspace 模式显示对应的固定轴坐标）、曲率/转折点、深度层、预计音符和最终音符。点击音符可以查看来源地标、和弦整理原因和 confidence。用户应能在播放前看到“这条空间路径将如何被解释”。

### 13.7 固定旋律空间 PitchSpace 契约（P0）

开放路径只负责提供时间序列、方向、结构和空间表达；最终音高必须落在录制前已锁定的固定 `PitchSpace`。禁止使用本次捕获的 `min/max`、5%/95% 分位数、`q0/q1` 平移或 `modulo octave` 重新定义音域。第 6 节中的 5%/95% 只能用于诊断本次轨迹覆盖了多少工作区，不能参与正式音高映射。

#### 固定配置

录制的 count-in 开始前显示并锁定：

```text
pitch_profile_id
root = A
scale = minor_pentatonic
center_midi = 64       # E4
range = [55, 72]       # G3–C5
pitch_axis
pitch_sign
depth_axis
register_id
pitch_gain_mm_per_degree
quantizer_hysteresis
register_lock = true
```

用户可以在录制前显式调整调性、中心音、跨度或移调；每次改变都产生新的 `pitch_profile_id` 和配置哈希。录制过程中不允许改变这些值。

固定传感器空间为：

```text
q_app = S · R · (XYZ - offset)
```

`R` 是安装方向与左右手镜像，`S` 是三轴物理尺度，`offset` 是固定零点，`q_ref` 是固定工作区参考点。`WAIT_NEUTRAL` 只能检测小幅基线漂移；小于阈值的偏移可记录并补偿，大于阈值必须提示重新校准，不能静默重建音高网格。

固定旋律空间不是把三个空间轴都当成独立音高轴，而是一个可学习的乘积空间：

```text
Pitch   = 固定物理音高轴 b_abs → 固定音级/注册区
Phrase  = τ + 水平轴 h/a_rel → 起音密度、段落、gate、回撤
Color   = 深度轴 c_abs       → 同一注册区内的和声层与演奏法
```

`τ` 是唯一的时间顺序；水平轴即使发生回撤，也只能产生结构标记或密度变化，不能把空间距离当作节拍，也不能改变 PitchSpace。这样三维轨迹的三个方向都有可听作用，同时不会牺牲音域稳定性。

#### 固定音级网格

在 profile 建立时生成音级表 `P`，例如在 `[G3,C5]` 内的 A 小调五声音：

```text
P = [G3, A3, C4, D4, E4, G4, A4, C5]
```

Workspace 模式使用固定音高轴 `p`：

```text
b_abs = dot(q_app - q_ref, p)
b_norm = clamp((b_abs - b_min) / (b_max - b_min), 0, 1)
i_float = b_norm * (len(P) - 1)
```

Gesture-Aligned 模式只允许旋转 `p` 的方向，仍然使用固定 `q_ref`、`b_min` 和 `b_max`；不能使用本次手势的起点、终点或幅度重新设置音高零点和尺度。若需要让同一形状在不同位置获得相同音高轮廓，必须切换到显式 `Registered Gesture` 实验模式：用户在录制前选择 `StartNote/Anchor`，系统使用固定 mm→音级灵敏度，仅做显式平移，不按本次曲线幅度自适应。

#### 量化、注册区和边界

最终音符使用带滞回的最近音级量化。当前音级保持到目标越过相邻边界加 `h` 后才换音，`h` 默认为 0.15–0.25 个音级或等价的 20–40 cents。`HOLD` 期间不因噪声重新量化；只有 `TURN`、新锚点或持续越过边界才触发 `NOTE_ON`。方向相同时优先沿 `b_abs` 的方向取整，避免手在边界两侧颤动。

默认 `register_lock=true`：单次跳进不超过约 7 个半音，越界采用 `saturate/clamp` 并生成 `out_of_range` 诊断，绝不自动换八度。只有显式 `RegisterShift` 按钮或预先定义的长按手势，才允许在小节边界移动 ±12 半音；首版不自动注册区漂移。

`c_abs` 的暗/主/亮颜色层只能在同一注册区、同一固定音级网格的邻域内选根音/五度、主轮廓音、三度/七度/九度/sus 等候选。无合适色彩候选时保留原音，只改变演奏法或 FX；深度变化不能导致八度跃迁。

#### 事件诊断和可视化

每个 Lead 事件至少记录：

```text
b_abs
b_norm
raw_target_midi
target_scale_index
quantized_midi
quantization_delta
register_id
color_layer
out_of_range
pitch_profile_hash
correction_reason
```

UI 必须显示固定音高网格、音名/级数标签、G3–C5 边界、当前 raw target、量化结果、深度色带和 saturation 状态。用户应能直接看到“这个物理高度对应 E4”，而不是看到一个随本次曲线自动变化的相对音高。

#### 固定空间验收不变量

以下“同一物理位置对应同一音名”的不变量适用于默认的 `Workspace/Absolute Workspace` 模式，以及使用固定 Anchor 的 `Registered Gesture` 模式。`Gesture-Aligned` 的实验保证是“固定音域内保持相同形状语义”，不承诺同一物理点在不同路径朝向下仍对应同一音名；模式差异必须在 UI 和 session manifest 中明确显示。

1. 同一 `raw XYZ + calibration profile + pitch profile` 输出完全相同的音级序列；
2. 同一物理高度跨多次录制得到同一音名和注册区；
3. 曲线的起点或整体位置变化不会静默重建音域；
4. 曲线幅度变化不会自动换八度；
5. `Z/c_abs` 变化不能导致注册区跃迁；
6. `b_abs` 单调上升时，音高不能反向下降，除非记录了明确的和弦修正原因；
7. 所有音符都在 profile 固定范围内；
8. 越界只饱和或报告，不 wrap；
9. 同一 capture 重复编译，事件表和音域完全一致。

固定旋律空间的校准验收使用应用 profile 的至少五个已知姿态：工作区中心、音高轴上边界、音高轴下边界、水平轴边界和深度轴边界。分别录制垂直静止线、水平线和深度线，确认：垂直线只改变固定音级，水平线只改变段落/密度语义，深度线只改变同一注册区的色彩或演奏法。重复触碰同一空间点时，量化结果误差不得超过一个音级；同一曲线仅改变速度时，音级序列和音域必须保持不变。

这套开放路径管线是三维 Lead 的 PC 验收基线：

```text
XYZ
→ 中值/Hampel + 低通
→ 端点方向或 PCA 对齐
→ 弧长参数化
→ Workspace 或 Bishop 开放路径坐标
→ 曲率/转向/停留/深度地标
→ MOVE/HOLD/TURN/REST 状态机
→ 当前和弦与小调五声候选集
→ 带滞回的音符量化
→ NOTE / REST / 和声色彩 / 演奏法事件
```

不存在一个公认的“3D 开放曲线自动生成旋律”单一算法；成熟性来自这组可验证、可解释的几何和音乐算法组合。深度究竟对应根/五度、三度、延伸音还是其他色彩，必须由 Synthwave/Ambient 风格配置冻结，不能交给黑箱模型自行决定。

## 14. Lead 音色与演奏法：Neon Ambient Lead

### 14.1 风格定位

Lead 采用 **Neon Ambient Lead**：旋律轮廓清晰、带有 Synthwave 的模拟合成器边缘，同时保留 Ambient 的延迟、混响和留白。它不是厚重的和弦 Pad，也不是持续铺满频谱的效果音；每个主要音符都必须能被听见，空间尾音只能延长情绪，不能掩盖起音和节奏。

该音色只负责把已经生成的 Lead EventTable 变成声音。曲线空间负责音高和旋律方向，IntentIR 负责起音、停留、转折和连奏，`LeadPatchProfile` 负责音色和空间表现。音色层不能重新生成音符。

### 14.2 固定信号链与初始参数

```text
带限 Saw ─┐
          ├→ Mixer → LP24 Filter → Mono/Legato Amp → Chorus
Pulse/三角 ┘                                      → Delay → Reverb
```

PC 首版默认参数：

```text
Oscillator 1: band-limited saw，level 0.70
Oscillator 2: pulse 或 triangle，level 0.30
Pulse width: 45–55%
Detune: ±5–9 cents
Optional sub: 10–20%，只补主体，不制造低频和声

Voice: mono / legato
Portamento: 40–100 ms
Pitch bend: ±2 semitones

Filter: 24 dB/oct low-pass
Cutoff: 1.8–3.5 kHz
Resonance: 0.10–0.25
Filter envelope amount: 中等

Amp ADSR:
  Attack 5–25 ms
  Decay 120–250 ms
  Sustain 0.75–0.90
  Release 300–900 ms

Vibrato: 4–6 Hz，10–25 cents
Vibrato delay: 起音后 200–500 ms
```

振荡器必须使用带限波形，避免高音区混叠。Lead 的振荡器相位和重触发规则默认确定性固定，使同一 CaptureSession 的重复播放保持一致。

### 14.3 IntentIR 到演奏法

| IntentIR/事件 | Lead 演奏法 |
| --- | --- |
| `MOVE` 连续移动 | 相邻音符优先 legato，不重复触发包络 |
| `TURN` | 触发新音符；方向变化越快，起音 accent 越明显 |
| `HOLD` | 延长当前音；持续足够久后才进入轻微 vibrato |
| `APEX` | 高点 accent，cutoff 和空间发送略增加 |
| `VALLEY` | 保持音高清晰，cutoff 略暗，不自动降八度 |
| `REST` | 关闭 gate，保留短 release tail 和效果器尾音 |
| `RELEASE` | 结束当前音符，不补写终止音 |
| `tie/carry` | 不重新触发振荡器，保持连续相位和滤波包络 |

演奏法约束如下：

- 连续 `MOVE` 且方向没有明显转折时使用 legato；
- 相邻音级或小跳进允许 40–80 ms glide；
- 较大跳进的 glide 最长 100 ms，避免旋律变成持续滑音效果；
- 跨越 `REST` 禁止 glide，必须重新起音；
- `HOLD` 内的传感器抖动不能重复触发音符；
- `TURN` 只改变起音和连接方式，不额外增加没有来源的音符；
- `RELEASE` 只结束 gate，不强制写入主音或高潮。

### 14.4 三维空间到 Lead 表现参数

```text
b_abs                  → 已量化的固定音高
τ + h/a_rel            → 句内位置、gate、连奏和密度倾向
c_abs 的慢速分量     → cutoff、PWM、chorus、delay/reverb send
c_abs 的快速分量     → accent、滤波瞬态、glide 强度
approach velocity      → velocity、filter envelope amount
```

`c_abs` 不改变八度，也不直接绕过固定音级表。默认音符来自 `PitchSkeleton`（固定小调五声音级表）；`Direct` 只允许主轮廓音、根音和五度附近的颜色替代。`Polished` 才允许在弱拍或长音中使用当前和弦许可的三度、七度、九度或 sus，并要求邻近级进解决。每次替代都记录 `color_exception` 和 `correction_reason`；没有合适候选时保持原音，只改变音色参数。

所有连续调制都经过 slew 限制。深度快速变化只能带来短暂 accent、滤波开合或发送量变化，不能制造额外 `NOTE_ON`。

### 14.5 八小节段落中的音色表现

段落变化只修改音色和演奏参数，不改写 EventTable：

| 段落 | Lead 表现 |
| --- | --- |
| 第 1–2 小节 | cutoff 较暗、空间发送较少，突出动机首次出现 |
| 第 3–4 小节 | cutoff 缓慢打开，延迟尾音增加，允许少量 legato |
| 第 5–6 小节 | chorus、glide 和空间发送适度增加，保持动机可辨认 |
| 第 7 小节 | 最高亮度、accent 和空间发送；只有轨迹确实有高点时才使用 |
| 第 8 小节 | cutoff 回收，release tail 拉长，为下一轮准备 |

如果轨迹没有高点或释放证据，第 7、8 小节只做轻微动态推进和回收，不能强行制造高潮或终止音。

### 14.6 空间效果与混音边界

```text
Chorus: 中等深度，宽度适中
Delay: BPM 同步四分或附点八分/四分，初始反馈 25–45%
Reverb: 2.5–5 s，中等预延迟 20–40 ms
Delay/Reverb low-cut: 开启，避免低频尾音堆积
Lead dry signal: 中央或窄立体声
Chorus/Delay/Reverb: 扩展到两侧
```

Lead 的干声必须保留中频起音；长尾不能覆盖下一次 `NOTE_ON`。`release_tail` 受最大尾长限制，跨 Loop 只允许明确标记的 `carry`，普通音符在边界 split 或 fade。Lead 不使用长低频混响。

### 14.7 LeadPatchProfile 与可复现性

每个 Lead 预设保存为 `LeadPatchProfile`，至少包含：

```text
patch_id
patch_version
oscillator_waveforms
oscillator_levels
detune_cents
phase_mode
retrigger_mode
poly_mode / voice_count
filter_type / cutoff / resonance / envelope_amount
amp_adsr
filter_adsr
lfo_rate / lfo_depth / vibrato_delay
glide_range / glide_time
chorus
delay_time / feedback / filter
reverb_time / pre_delay / send
velocity_curve
interaction_targets
patch_profile_hash
```

CaptureSession 同时记录 `pitch_profile_hash`、`calibration_profile_hash`、`lead_patch_profile_hash` 和 `render_hash`。随机失谐、相位、声像或微小调制若启用，必须使用保存的 seed；同一输入、同一配置和同一 seed 必须产生相同的 Lead 演奏结果。

Lead 的职责最终固定为：

```text
固定空间 → 音符与旋律方向
IntentIR  → 起音、停留、转折、连奏和释放
LeadPatch → Synthwave 音色、动态和空间尾音
```
