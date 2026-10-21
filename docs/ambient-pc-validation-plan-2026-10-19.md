# Melodic Synthwave PC 验证计划：主旋律轨迹与独立触摸轨道

> **主规范引用**：本文是 PC 实现计划；产品语义、回放格式、跨轨监听、和声量化、量化参数、异常恢复和验收标准以 [系统主规范](mgc3130-melodic-synthwave-system-design-2026-10-19.md) 为准。坐标与校准统一见 [坐标与校准规范](mgc3130-coordinate-calibration-spec.md)。

## 目标

在 PC 上验证 CAPTURE & LOOP 的真实交互设计：Lead 由完整三维手绘轨迹编译成 Melodic Synthwave 主旋律；Bass、Pad、Arp、Drums、Texture/FX 由 MGC3130 Touch/Tap 事件逐轨独立录制；六轨最后按统一 Loop 时钟合并播放。声音保留 Ambient 的长混响、长延迟和渐变包络。

## 已冻结的 Synthwave 配置

PC 验收默认使用以下风格参数，不再以纯 Ambient 的静态 vamp 作为主目标：

```text
4/4，8 小节，128 个 16 分 tick，默认 100 BPM（90–120 BPM）
直拍为主，swing 默认 50%（最多 54–56%）
小调 + 小调五声 Lead
i–VI–III–VII；A 小调示例：Am–F–C–G，每和弦一小节
Lead 高潮目标 60%–75%，末音主音
大混响 + 500 ms 以上长延迟 + 慢速滤波 LFO
```

验收重点从“是否足够稀疏”改为：旋律是否清晰、低音和鼓是否形成稳定脉冲、和声是否循环自然，同时保留空间感和留白。

本阶段不实现 LIVE 发音，也不预先制造人工合成测试集。真实 MGC3130 录制完成后必须落盘为 CaptureSession，允许对同一份 raw capture 离线回放、调参和渲染；全部模块完成后再用连续真实操作进行最终设计验收。

## 固定交互模型

```text
选择轨道
  → 录制该轨
  → 结束并保存该轨 shadow 事件
  → 选择下一轨
  → 重复录制
  → 合并六轨
  → Synthwave Loop 播放
```

一次录制只允许一个当前轨道解释输入。当前轨道决定同一帧 XYZ、Touch 和 Tap 的含义，避免打鼓时把位置变化误写入 Lead。

播放阶段是独立的表现层：当前 active Loop 只读，手势和 XYZ 不新增乐句、不写入任何轨道事件，只对已有六轨声部施加临时的包络、音色、空间和调制变化。只有显式进入录音或调制录制模式，输入才可以改变可保存的数据。

## SDK 输入契约

Microchip GestIC SDK 1.2.0 已提供：

- `gestic.result.pos`：XYZ 位置；
- `gestic.result.touch.flags`：五个电极的持续 Touch 状态；
- `gestic.result.touch.tap_flags`：单击和双击事件位；
- `gestic.result.gesture`：独立手势字段。

接收器继续通过 `gestic_set_output_enable_mask()` 请求 position、gesture、touch。PC 归一化层必须区分：

```text
touch.flags       → 持续状态，生成 press/release 边沿
tap_flags         → 一次性触发，生成 single_tap/double_tap
gesture           → 暂不作为轨道音符输入
XYZ               → Lead 曲线，或当前 Touch 事件的音高/力度参数
```

SDK 的 `touch.flags` 不能直接按帧当作鼓点；必须做边沿检测和最小间隔去重。`tap_flags` 也要按帧号或时间戳去重，因为一个事件可能在相邻报告中保持可见。

## SDK 校准与应用层相对坐标

已核对本机 Microchip GestIC SDK 1.2.0。SDK 提供的是传感器/DSP 工作基线校准，不是“把当前位置设为音乐坐标原点”的应用校准：

- `gestic_set_auto_calibration()` 开关自动校准；
- `gestic_force_calibration()` 请求设备立即执行一次校准；
- `gestic_get_calibration()` 读取校准原因和状态；
- 位置报告在 `PositionValid` 时直接复制传感器输出的 `x/y/z`。

SDK 没有发现设置任意 XYZ 原点、把当前手的位置设成中心，或让每次手势识别自动从该中心重新开始的通用 API。头文件中的 `gestic_touch_center` / `gestic_tap_center` 表示中心电极的 Touch/Tap，不是 XYZ 坐标重心化。GestIC 内部的基线、Presence、Hand Inside 和手势状态仍可能影响报告有效性，但不会把应用层坐标改成“以本次动作起点为零”。

因此系统需要明确区分三层：

```text
SDK/硬件校准       消除电极基线漂移和工作环境变化
应用坐标校准       建立传感器坐标到项目音乐坐标的轴向、缩放和中性区
演奏动作相对起点   在一次 Lead 录制或 PLAY 表现动作开始时锁存参考点
```

首版 PC 实现约定如下：

1. 进入 Lead 录制或 PLAY 时，先要求手离开传感区或稳定在 neutral 区域；
2. 对连续若干个 `PositionValid` 报告做中值/均值估计，锁存 `x0/y0/z0`；
3. 后续输入使用 `x_mod=x-x0`、`y_mod=y-y0`、`z_mod=z-z0`，再经过 dead zone、低通和 slew 限制；
4. 参考点保持到显式重新校准、退出当前模式或执行 STOP；手运动期间不更新参考点。

不要每个报告都重新计算中心，否则调制会被抵消；也不要把 `gestic_force_calibration()` 当作每次动作的起点复位，因为它是设备基线校准，运行中调用可能造成位置暂时无效或坐标跳变。

## Lead 轨道流程

1. 录制期间只缓存有效 XYZ 和时间戳，不触发最终 Loop 音符。
2. 停止后按三维弧长建立乐句进度 `u`，提取轮廓 `v` 和表现力 `w`。
3. 使用鲁棒距离、有限窗口平滑、导数和短核卷积抑制抖动与小回绕。
4. 识别上行、下行、拱顶、谷底、平台、停留、重音和释放地标。
5. 根据地标选择 Synthwave 句法模板。
6. 使用有限状态半马尔可夫 Viterbi 选择音高、时值和段落状态。
7. 输出 Lead 独有的事件表，满足小调五声、`i–VI–III–VII` 和声循环、高潮窗口和主音终止约束。

## Bass、Pad 与 Arp 轨道流程

这些轨道不从 Lead 或 Synthwave 模板复制事件。录音时每次用户实际产生的 Touch/Tap 触发，才允许写入一个事件。

首版建议：

- Bass：Touch/Tap 的 `Y` 映射到低音区的音阶音，`Z` 映射 velocity，按下/释放或预设门限决定 duration。
- Pad：Touch/Tap 的 `Y` 选择和弦 voicing，`Z` 映射力度/滤波；用户每次触摸决定一个和弦事件。
- Arp：Touch/Tap 触发用户选择的 voicing 和 Arp 模式；Arp 只展开用户实际触发的事件，不从 Lead 或模板生成新的触发。
- 二者都使用同一个全局 Loop tick，但只保留实际发生的事件和留白。

这里的“和谐”来自音阶、和弦角色和音域约束，而不是自动补齐用户没有触发的音符。

## Drums 轨道流程

默认使用 5 个电极粗映射，后续再根据真实操作决定是否启用 3×3 位置细映射。

```text
South / West / North / East / Center
  → 五种鼓机音色
```

单击立即生成一个 NOTE_ON；双击生成第二个触发或 roll/flam 事件。触摸状态只负责 press/release 边沿与去重。速度使用触摸接近速度或 Z 变化估计；最小触发间隔设置为 30–50 ms，并作为可调参数。

## 统一时序

- Loop 默认 8 小节、4/4、128 个 16 分 tick。
- 轨道录制使用统一 BPM 时钟，不使用报告到达时间直接作为音乐节拍。
- 触发时间吸附到网格，并使用累积残差补偿长期漂移。
- 轨道录制可以分别进行，但每个轨道的事件都落在同一个 Loop 时间轴。
- 新轨道先写独立 shadow 数据，完成后再与其他轨道合并；未录制轨道保持为空。

## PLAY 表现层

PC 验证器需要单独实现 `performance_mod_layer`，不把它混入 `EventTable`：

```text
active EventTable + performance_mod_layer → 六轨合成器参数
```

默认映射：

- X：Timbre/Morph，默认映射滤波 cutoff、波表/振荡器混合、声像和空间宽度；
- Y：Pitch/Voicing，默认映射 Lead 的受限弯音，并可在安全节拍改变 Pad 转位或 Arp 音域；
- Z：Expression/Energy，默认映射力度、包络深度、混响/延迟发送和整体能量；
- 单击/双击：瞬时包络、stutter、freeze 或轨道 mute 宏；
- Flick/Circle：滤波扫描、空间效果或全局调制宏；
- AirWheel：慢速调制深度或速率。

X/Y 在进入表现层后转换为以应用参考点为中心的双极值，Z 转换为远近对应的单极值。不同轨道使用不同的调制增益和目标掩码；会改变和声或音域的 Y 参数只在下一拍或下一小节生效，连续滤波、包络和空间参数可以立即响应。

每个宏都带有 `momentary` 或 `latched` 语义，并支持立即、下一拍或下一小节生效。调制目标带六轨掩码，可只作用于 Lead，也可作用于选定轨道或全局。PLAY 阶段不产生 NOTE_ON，不改变事件数量，不追加新乐句；退出 PLAY、STOP 或输入超时后，临时调制回到中性值或按设定 release。

如果需要保存调制，必须进入单独的 `RECORD_MODULATION` 流程，把稀疏控制点写入 Texture/FX 轨道或对应轨道的 modulation lane，不能隐式修改原始音符事件。

## Synthwave 化的独立轨道规则

六条轨道仍然逐轨由用户录制。Synthwave 模板提供小调、`i–VI–III–VII` 和声、四拍节奏、音域和密度边界，不替用户补写 Touch/Tap 事件。所有轨道遵循“稳定脉冲 + 清晰旋律 + 空间长尾”的默认取向：

| 轨道 | Synthwave 首版语义 |
| --- | --- |
| Lead | 保留手绘曲线的方向、拱顶、停留和终止；四分/八分音符为主，后半段形成动机变奏，高潮在 60%–75% |
| Bass | Touch/Tap 触发主音、八度和五度的脉冲低音；默认八分音符或四分音符，允许跨小节延音，服从当前和弦根音 |
| Pad | 每次触摸触发一小节或两小节和弦；Attack/Release 较长，和弦变化在小节边界生效，采用最小声部移动 |
| Arp | Touch/Tap 选择和弦和模式；默认 1/8 分解，允许切换 1/16 或稀疏半音符模式，不自动增加用户未触发的段落 |
| Drums | Touch/Tap 录制四拍骨架：Kick 可按四分音符，Snare/Clap 默认 2、4 拍，Hat 用 1/8 或稀疏 1/16；双击才形成 flam/roll |
| Texture/FX | 录制噪声、磁带纹理、上升/下降效果和滤波控制；用长交叉淡化、长混响和延迟连接段落，不承担旋律补全 |

轨道级约束如下：

- 触发仍来自用户的真实 Touch/Tap，不能因为 Synthwave 模板而自动增加事件；
- 触发时间吸附到统一 Loop 网格；Lead/Bass/Drums 默认 1/16 或 1/8，Pad/Texture 可放宽到 1/4 或 1 小节；
- 同轨相邻同音或同和弦事件优先合并并延长，不制造短促重复；
- 轨道音域固定分层：Bass 最低，Pad 位于中低区，Lead 居中，Arp 和 Texture 可进入高区，避免频段拥挤；
- 速度和力度保持稳定脉冲，Lead/Pad/Texture 使用渐变和长尾，Drums 保留明确起音；
- `i–VI–III–VII` 是和声底座，允许用户触发的事件选择音阶内音或当前和弦内音，但不强制每个轨道都填满每个小节。

### Synthwave 的 ADSR 与手势包络

Synthwave 播放只保留两类曲线：

```text
音符 ADSR：由 Loop 中已有的 NOTE_ON/NOTE_OFF 触发每个音符的进入、保持和释放
手势表现包络：由一次有效手势触发，只调节已有声音的音量、滤波、空间或能量
```

连续 XYZ 只改变当前目标值，不反复触发 ADSR；XYZ 的变化速度、Tap 或 Flick 经过阈值和滞回后才触发一次表现包络。表现包络不产生 `NOTE_ON`，并可立即、下一拍或下一小节生效。这样能保留 Synthwave 的稳定脉冲、旋律清晰度和 Ambient 长尾，而不会把 PLAY 变成另一套快速演奏系统。

## 事件数据结构

```json
{
  "track": "drums",
  "source": "touch_tap",
  "trigger": "single_tap",
  "electrode": "center",
  "tick": 32,
  "duration": 1,
  "note": 36,
  "velocity": 108,
  "amp_mod": 0,
  "timbre_mod": 0,
  "touch_flags": 16,
  "tap_flags": 512,
  "quantization_error": -0.006
}
```

Lead 事件的 `source` 为 `trajectory`; Bass、Pad、Arp、Drums、Texture/FX 的 `source` 为 `touch_tap` 或 `control`. 事件表合并器不能通过模板自动增加事件。

## 实现顺序

1. 扩展 PC 接收器输出和 JSONL/CSV schema，明确 Touch/Tap 字段和时间戳。
2. 实现 Touch/Tap 事件归一化：状态边沿、tap 去重、双击识别、最小间隔。
3. 实现当前选定轨道的逐轨录制控制器和统一 Loop 时钟。
4. 将现有 Synthwave 算法收敛为 Lead-only 编译器。
5. 实现 Bass、Pad、Arp 的独立触摸事件映射。
6. 实现 Drums 的电极和单击/双击映射。
7. 为 Texture/FX 预留控制点和 Drone 事件接口。
8. 合并六个独立轨道并接入 PC 音频试听。
9. 实现 PLAY 的非破坏性 `performance_mod_layer`，验证包络、音色和调制映射不改变事件表。
10. 完成全部模块后，再进行真实 MGC3130 逐轨操作验收和参数调整。
11. PC 行为稳定后，才评估固定点版本和 FPGA RTL 资源。

## 验收重点

- Lead 的上行、拱顶、停留和终止能听出操作者意图。
- Bass、Pad、Arp、Drums、Texture/FX 只出现用户实际触发的事件或明确录制的控制点。
- Drums 单击即时、双击不丢第二击，且不会因持续 Touch 重复触发。
- 各轨可以分别录制、清除、静音和重录。
- 未录制的轨道保持空白，不被模板填充。
- 六轨合并后仍使用同一 Loop 时钟，节奏稳定且留白保留。
- Lead 满足 Synthwave 和声与节奏约束，但不会改变其他轨道的事件数量。
- PLAY 手势只改变表现参数，不新增乐句、不写入 active/shadow event bank。
- STOP、退出 PLAY 和输入超时都能安全释放或复位性能调制。
