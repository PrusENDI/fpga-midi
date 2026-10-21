# MGC3130 Melodic Synthwave 交互合成器系统设计

版本：2026-10-19（设计冻结概要）  
状态：PC 参考实现先行，FPGA 后移植；CAPTURE & LOOP 已冻结，LIVE 音符演奏不在本阶段范围内。

本文是当前系统唯一的产品与算法主规范。旧的讨论稿、PC 计划和 RTL 接口文档保留为历史背景或接口细节；出现冲突时以本文为准。坐标、校准和动作参考点统一见 [MGC3130 坐标与校准规范](mgc3130-coordinate-calibration-spec.md)。

当前 PC 实验暂时不能依赖 GestIC SDK/Aurea 完成硬件侧电极权重、E-field 线性化或 sensing-area 校准。此时采用固定的 `HostCalibrationProfile` 做主机侧坐标补偿、去耦合和抗抖；它是可回放的软件补偿层，不宣称替代 SDK 硬件校准。Lead 只有在这层处理完成后才进入 IntentIR 和音符生成，具体流程见 [PC 上位机 XYZ 去耦合与抗抖设计](pc-host-only-xyz-filtering-design-2026-10-21.md)。

当前 PC 实验的第一阶段以 [Lead 曲线意图提纯设计](pc-lead-intent-purification-design-2026-10-19.md) 为优先范围。该阶段先证明曲线能够形成有记忆点、可循环、可解释的旋律，再扩展完整六轨和作品级功能。

## 1. 一页结论

这是一个用 MGC3130 三维空间手势制作八小节 **Melodic Synthwave + Ambient 空间表现** Loop 的交互乐器。

- Lead 记录完整三维轨迹，停止后离线编译为有动机的旋律。
- Bass、Pad、Arp、Drums、Texture/FX 逐轨独立录制，只由真实 Touch/Tap 或控制事件写入，不由 Lead 或模板自动补音。
- 所有轨道共用 Loop 时钟、和声上下文和事件表；录制第 N 轨时默认播放已完成轨道作为参照。
- PLAY 手势只叠加临时包络、音色、空间和调制，不写入事件表、不产生新乐句。
- 真实设备录制可保存为 raw capture，之后离线反复编译、试听和比较参数；这解决可复现迭代问题，但不预先制造人工“正确答案”测试集。
- PC 是算法黄金模型和 UI 验证平台；FPGA 后续实现有界、定点、批处理编译与实时音频数据面。

## 2. 适合的音乐工种与使用场景

最适合的核心工种是：

> **互动电子音乐创作者（interactive electronic music composer/performer）**

典型使用者包括：

- 用空间手势构建 Synthwave Loop 的电子音乐创作者；
- 生成式音乐、交互乐器和音乐技术设计师；
- 现场视听艺术家、沉浸式装置创作者；
- 游戏、影视和装置艺术的氛围音乐原型设计者。

它强调“表达动机、方向和空间感，再由算法完成可听的旋律”，不定位为传统钢琴键盘替代品，也不追求精确鼓机编程器的逐格编辑体验。

## 3. 风格冻结

| 项目 | 首版固定值 |
| --- | --- |
| 拍号/结构 | 4/4，8 小节，128 个 16 分 tick |
| 速度 | 默认 100 BPM，可调 90–120 BPM |
| 和声 | `i–VI–III–VII`，A 小调示例 `Am–F–C–G`，每和弦 1 小节 |
| 旋律 | 小调五声为骨架，1.5–2 个八度，高潮位于全曲 60%–75%，末音回主音 |
| 音色 | 复古合成器、脉冲低音、四拍鼓机、稀疏 Pad/Arp |
| 空间 | 大混响、500 ms 以上长延迟、慢速滤波 LFO、保留长尾和留白 |
| Loop | 每轨最多 3–4 层；新层超限淘汰最老层，旧层递减音量并轻微 detune/声像偏移 |

### 3.1 音阶与和声的关系

小调五声 `A–C–D–E–G` 是 Lead 的默认音高骨架，而不是绝对硬约束。强拍优先当前和弦音；当前和弦根音和三音可以作为和声特许音。以 A 小调为例，F 和弦允许 F，G 和弦允许 B 或 D，弱拍仍优先五声和经过音。音域、违规和弦、主音终止等结构条件仍是硬约束。

### 3.2 混音纪律

- Bass 置中，基本不进长混响/长延迟；空间 send 高通约 200–400 Hz。
- Kick 基本干声；Snare/Clap 承担 gated/plate 空间。
- Lead 延迟做高切、低切，并用 pre-delay 保留原音清晰度。
- Pad 和 Texture/FX 对 Lead 做轻微 sidechain duck，默认高通并让出主旋律中频。
- 每个 Loop 起点对 delay feedback/reverb send 做轻微 duck；反馈有上限，第 8 小节末保留可配置空气释放窗口。

## 4. 交互模式与状态

产品只有两个主要运行状态：

```text
CAPTURE/RECORD：当前选定轨道接收输入并写入 shadow session
PLAY：active Loop 只读，手势进入 performance_mod_layer
```

录制采用“当前选定轨道逐轨录制”。一次录音只写一条轨道，完成后成为该轨道的 shadow 层；编译或合并成功后才在安全 Loop 边界提交 active bank。录音中输入解释按当前轨道互斥，避免打鼓时误写 Lead。

录制第 N 轨时，已完成轨道默认可听，并可单独 mute/solo。界面必须显示小节、拍、tick、当前和弦、节拍器/visual beat 和录音轨状态。Drums 提示 2/4 拍，Bass 提示每小节根音落点；提示只帮助演奏，不写入事件表。

## 5. 六轨语义

| 轨道 | 输入来源 | 音乐职责 |
| --- | --- | --- |
| Lead | 完整三维轨迹 | 唯一由轨迹编译的主旋律 |
| Bass | Touch/Tap | 脉冲低音和根音运动 |
| Pad | Touch/Tap | 长和弦、转位和空间铺底 |
| Arp | Touch/Tap | 用户触发的分解和弦片段 |
| Drums | Touch/Tap/电极 | Kick、Snare/Clap、Hat 和打击层 |
| Texture/FX | Touch/Tap/控制事件 | Drone、噪声、纹理、滤波和空间事件 |

缺少用户触发的轨道保持留白。风格配置只能决定量化、音域、音色和表达边界，不能为缺失轨道自动生成事件。

## 6. 坐标、力度和输入解释

三层校准、neutral、`x0/y0/z0`、dead zone、PositionValid 和断线策略见[坐标与校准规范](mgc3130-coordinate-calibration-spec.md)。

默认力度来源是接近速度：`approach_velocity = lowpass(abs(dz/dt))`。Bass、Pad、Drums 优先使用它；速度不可用时才回退到校准后的 Z。绝对 Z 更适合慢速滤波、drive、gate、octave 或空间控制，不作为唯一力度来源。原始值、映射值和 confidence 都写入诊断。

## 7. 共享和声量化模块

所有旋律和触摸轨道调用同一个和声查询接口，不允许每轨隐式复制规则：

```text
ChordContext = lookup_chord(tick, style)
quantize_to_scale(note, scale)
quantize_to_chord(note, chord, role)
map_y_to_bass(y, chord)
map_y_to_pad_voicing(y, chord, previous_voicing)
map_y_to_arp_pattern(y, chord)
```

A 小调默认 `chord_index = (tick // 16) % 4`：0–15 Am，16–31 F，32–47 C，48–63 G，64–79 Am，80–95 F，96–111 C，112–127 G。Bass 的 Y 分区选择根音/五度/八度；Pad 的 Y 选择 voicing/inversion，并以最小声部移动为优先；Arp 的 Y 选择模式、方向和密度。最近邻只能是底层工具，最终结果必须服从音阶、和弦角色、音域和最小声部移动。

## 8. Lead 编译器

### 8.1 两级模式

**Baseline（首版默认）**：弧长重采样 → 轨迹分段 → 上行/下行/停留目标 → 每段 1–3 个核心音。强拍落和弦音，弱拍允许五声经过音，1/8 为主体、少量 1/16 装饰。每个音都能追溯到轨迹段和和声约束。

**Advanced**：在相同中间表示上运行有界半马尔可夫 Viterbi，加入轮廓、地标、和弦、跳进、重复、音域漂移、时值、密度、高潮和终止代价。Baseline 与 Advanced 共享 EventTable、参数快照和诊断格式，可对同一 raw capture 直接比较。

### 8.2 预处理与地标

1. 弧长重采样约 400 点；
2. 小环自交剔除，弧长小于 3% 的回绕视为毛刺候选；
3. `u` 使用真实时间归一化并天然单调；如果启用空间主轴，只对可选的空间进度投影做等渗约束，不改变时间轴；
4. Savitzky–Golay 平滑、归一化并取反得到轮廓 `c(i)`；
5. Douglas–Peucker 折线顶点提取 onset/结构地标，比曲率双阈值更稳；
6. onset 弧长选择节奏模板和密度，量化到 16 分网格，慢速段可放宽到 8 分；保留累积残差补偿。

轨迹表达轮廓、停留、转折、释放和高潮位置；固定网格表达节奏。采样误差不直接变成音符。

### 8.3 Phrase 与约束

| 小节 | 状态 | 作用 |
| --- | --- | --- |
| 1 | opening | 动机首次出现，低/中音域 |
| 2 | opening | 动机重复，轻微变尾 |
| 3 | development | 上行或密度增加 |
| 4 | half_cadence | 停在五度或 VII 级色彩 |
| 5 | development | 动机变奏，扩大音域 |
| 6 | development | 向高潮推进 |
| 7 | apex | 60%–75% 高点，较高音域或长音 |
| 8 | cadence/release | 2/7 级级进进入主音并释放 |

首轮是 1–4 小节，次轮是 5–8 小节。硬约束违规代价为无穷，不能靠软权重“调回来”。首版权重起点：轮廓 1.0；和弦强拍 2.0、弱拍 0.5；漂移 0.15；重复 0.5；高潮 1.0。

### 8.4 事件上限与 confidence

- 每个 16 分 tick 最多 1 个 Lead `NOTE_ON`；grace/note-repeat 不能与主音共享 tick。
- 每小节最多 8 个 Lead onset，全曲最多 16 个 Lead note events。
- 超限保留结构边界、高潮、终止和高 confidence 事件，最后删除低 confidence 装饰/重复音。
- `confidence ∈ [0,1]` 由位置有效性、地标稳定性和和声冲突程度计算，用于 UI/诊断、装饰音概率、pitch bend 和 FPGA 资源裁剪；不直接当音量，也不能随意删除低 confidence 的主旋律。

## 9. 其他五轨规则

### Bass

一次 Touch/Tap 产生一次 Bass 事件。Y 量化到当前和弦的根音/五度/八度，默认中等量化和稳定力度；`approach_velocity` 可做轻微 velocity 表达，Z 绝对值主要调滤波、drive、gate 或 octave。

### Pad

一次触发产生一个和弦 compound event，可一次 Undo。Y 选择共享和弦表中的 voicing/inversion，采用最小声部移动。和弦变更只在小节边界生效；小节中间触发先排队到下一边界，避免和声抖动。

### Arp

一次触发启动一个有明确长度的 Arp 片段，默认 1 小节；按住可延长，松开后在下一个节拍停止。Y 选择和弦、方向和密度，事件仍源自用户触发，不是自动补写。

### Drums

默认五电极映射 Kick、Snare、Closed Hat、Open Hat、额外打击音；需要更细表达时再启用起始位置 3×3 映射。单击立即触发；两次触发间隔 `<80 ms` 判为 flam，第二击约延迟 30 ms、力度为第一击约 0.75；`>=80 ms` 是两个独立 hit。最小防抖间隔 30–50 ms。事件保存 `tap_kind`、双击间隔和 flam 延迟。

### Texture/FX

只记录纹理、Drone、噪声和空间/滤波控制事件，不补写旋律。默认高通、动态 EQ 或 sidechain duck，让位给 Lead 和鼓的中频瞬态。

## 10. 每轨量化与节奏

每个工程保存以下参数：

```text
grid_per_track
quantize_strength_per_track   # 0..1
swing_amount_per_track
timing_humanize_ms
```

默认策略：Drums 1/16 强量化但保留极小 groove；Bass 1/8 或 1/16 中量化，允许轻微拖拍/抢拍；Pad 1/4 或 1 小节并在边界换和弦；Arp 1/16 中量化；Texture/FX 1/4 或 1 小节；Lead 由编译器输出 1/8 主体和少量 1/16。累积残差只补长期漂移，不抹掉 per-track 人性化偏移。量化误差必须进入事件表和诊断。

## 11. 录制回放与可复现迭代

真实设备录制保存为 `CaptureSession`，至少包括：

```text
metadata
sensor
style_config
reports[]: timestamp_ms, frame, x, y, z,
           position_valid, touch_flags, tap_flags, gesture
```

回放 CLI/工具必须能用同一份 raw capture 重跑 Baseline/Advanced、和弦量化、量化参数和渲染参数，并保存参数快照、EventTable、诊断 JSON 和 WAV。它不是人工合成测试集；后续真实录制可以自然形成回归库，但当前不预先制造“正确答案”。录制回放工具的实现优先级高于 Lead 编译器调参。

## 12. 跨轨录制、撤销和 Loop 语义

- 已完成轨道作为监听参考，可 mute/solo；当前轨道输入只写当前 shadow session。
- `UNDO_LAST_EVENT` 至少支持 Drums、Bass，并扩展到 Pad compound event 和其他 Touch/Tap 轨道；只撤销当前录音 session 的最后一个用户事件。
- `clear track`、`mute`、`solo`、层数上限和最老层淘汰都不修改其他轨道。
- 录制传感器到发声的固定延迟要在 tick 量化前扣除，避免多层系统性偏晚。
- active bank 播放期间只读；shadow 编译/录制完成后只能在 Loop 边界提交。

## 13. PLAY 表现层

PLAY 不产生新的 `NOTE_ON`，只叠加 `performance_mod_layer`：

```text
active event bank + track/global modulation -> voice parameters -> audio
```

XYZ 连续变化映射包络、cutoff、resonance、wavetable、空间发送、LFO、声像和有限 pitch bend；Touch/Tap/Gesture/Flick 触发 momentary 或 latched 宏。结构宏 `stutter/freeze/reverse` 只作用已有事件。

宏调度规则：连续 XYZ 参数最后值覆盖并 slew；momentary 同目标 FIFO 叠加但限幅；latched 后触发覆盖前状态；结构宏同一时刻只允许一个，优先级 `STOP > CLEAR > freeze > reverse > stutter`。下一拍/下一小节宏按目标时间排序，同 tick 同目标按上述优先级处理，过期宏丢弃并记录诊断。所有调制不写回 EventTable。

Loop 机械感的轻微变奏只在第 2 次及以后循环启用：Lead 装饰音概率很低，velocity ±2–4，cutoff/LFO 相位轻微偏移；主旋律骨架、和声和鼓核心节奏不变，且可关闭。

## 14. EventTable 数据契约

每个事件至少包含：

```text
track, source, trigger, tick, duration,
note_or_drum_id, velocity, confidence,
amp_mod, timbre_mod, pitch_mod,
touch_flags, tap_flags, electrode,
quantization_error, approach_velocity,
diagnostic_refs
```

`source` 必须区分 `trajectory`、`touch`、`tap`、`gesture` 和 `performance_layer`。事件表保存音乐事件，不保存音频；raw capture 单独保存传感器报告。

## 15. 异常恢复

- `PositionValid` 连续失效超过 100 ms：停止追加并标记 degraded。
- 设备断线：当前轨道 `FAILED`，不提交 shadow；active Loop 保留；恢复需显式 Resume。
- 录音失败：保留 raw capture 供诊断，由用户选择 discard/retry。
- Lead 编译失败、硬约束无解、容量溢出：丢弃 shadow，保留 active bank，并显示可读错误。
- Touch 轨道中断只结束当前事件，不补齐丢失区间。

## 16. PC 验证程序与 UI

PC 版本按以下顺序实现：SDK 接收与事件归一化 → CaptureSession 落盘/回放 → 共享 harmony 模块 → Lead Baseline → Lead Advanced → 五轨 Touch/Tap 录音器 → 跨轨监听/节拍反馈/Undo → 六轨渲染和 WAV 导出。UI 必须显示当前轨、录制状态、和弦、小节/拍/tick、事件数、confidence、PositionValid、回放文件和编译诊断。

验收不是只看逐采样误差，而是检查：轨迹方向、停留、高潮和终止是否保留；和声循环是否自然；鼓、Bass、Pad、Arp 是否只响应真实触发；长尾是否不遮蔽 Lead；同一 capture 在相同参数下是否可复现；PLAY 是否永不增加乐句。

## 17. FPGA 迁移边界

PC golden reference 先行。FPGA 后续采用有界定点子集：轨迹 RAM、FIR/差分/卷积地标、有限 Synthwave 模板、有限候选半马尔可夫 DP、BRAM 回溯和双 bank 提交。浮点、无界搜索、通用神经网络和完整三维几何只保留在 PC 参考模型。实时音频、Loop 时钟、调度、voice manager、DDS、mixer 和 I²S 继续由 FPGA 硬件承担。

## 18. 风险与后续扩展

- 传感器三维精度不足仍可能导致意图歧义，因此 Baseline 可解释性优先于 Advanced 的理论最优。
- 8 小节长尾和重复可能造成机械感或能量堆积，首版用可关闭的轻微性能变奏和 Loop 起点 duck 缓解。
- 单事件删除、更多鼓层、更多风格模板、完整三维自交几何、硬件内置编译器资源优化留到后续迭代。

