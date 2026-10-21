# PC 上位机 XYZ 去耦合与抗抖设计

版本：2026-10-21  
状态：PC 实验阶段设计冻结，适用于 Capture & Loop；不依赖 GestIC SDK 的硬件校准接口。  
关联文档：[坐标与校准规范](mgc3130-coordinate-calibration-spec.md)、[Lead 曲线意图提纯设计](pc-lead-intent-purification-design-2026-10-19.md)。

## 1. 当前约束与目标

当前无法通过 SDK/Aurea 对 MGC3130 做电极权重、E-field 线性化、XY sensing area 和 Z 范围校准。因此 PC 版本必须把“传感器输出”和“音乐坐标”分成两层：

```text
MGC3130 XYZ 报告
  → 主机质量检查
  → 主机固定 profile 去耦合
  → 三轴联合抗抖
  → 动作意图分类
  → 固定旋律空间
  → Lead 事件表
```

目标不是把数据伪装成高精度位置，而是让重复动作得到稳定的音乐结果：

- 纯 Z 上下移动不应造成新的旋律音高；
- 真实 X/Y 或旋律轴移动仍应被保留；
- 手部短时抖动不应制造重复音符、颤音式音阶跳动或虚假转折；
- 固定物理高度在不同录制中应对应同一音级和注册区；
- 所有被滤掉、降权或判为不可靠的区段都能在 UI 和诊断 JSON 中看到。

这套方案只服务于 PC 实验和离线 Capture & Loop。它不声称修复 MGC3130 的物理电场模型，也不替代未来的 Aurea 参数化校准。

## 2. 必须保留的原始信息

每一帧先保存原始报告，之后再生成派生字段。CaptureSession 至少保存：

```text
sequence
timestamp_raw
logical_time_ms
x_raw, y_raw, z_raw
report_valid
xyz_valid / position_valid
report_error
clipping
environmental_noise
sensor_saturated
sequence_gap
```

当前 FPGA 校准 CSV 已有 `report_valid`、`xyz_valid`、`report_error` 和 `gap_before`。SDK 直接接收器还需要补充输出 `PositionValid`、`Clipping`、`EnvironmentalNoise` 和 `calibration_reason`；SDK 内部在 PositionValid 无效时可能保持上一帧位置，不能仅凭 XYZ 数值判断该帧有效。

原始数据永不被滤波结果覆盖。`raw`、`filtered`、`decoupled`、`resampled` 和 `landmarks` 作为不同层保存，便于回放和比较。

## 3. 固定 HostCalibrationProfile

### 3.1 不允许按单次曲线建立音域

一次 Lead 录制不能使用自身的 min/max、5%/95% 分位数或起点重新确定音域。否则同一动作幅度稍有变化就会换八度，用户无法学习“怎样画出某个音”。

每个传感器板、安装方向和电极布局使用一个固定的 `HostCalibrationProfile`，并写入：

```text
profile_id / profile_hash
sensor_orientation
raw_reference_xyz
workspace_min / workspace_max
pitch_axis
b_min / b_max
neutral_mad_xyz
saturation_low / saturation_high
depth_coupling_model
filter_parameters
```

Profile 只能在显式的 Calibration Capture 工具中更新，不能在普通 Lead 录制时自动学习。录制时最多允许锁存一次 neutral 参考点，用于 PLAY 表现层和漂移诊断；它不能改变 Lead 的固定 PitchSpace。

### 3.2 纯 Z 数据拟合可解释耦合模型

从“固定 XY、只改变 Z”的多次主机采集数据中估计：

```text
g_x(z) = median(x | z)
g_y(z) = median(y | z)
```

实际实现使用 5～9 个 Z 分箱，每个分箱取中位数，再用单调分段线性插值。数据量足够时可以使用 Huber/LOWESS，但输出 profile 时必须保存每个 bin 的样本数和残差尺度，不能只保存黑箱模型。

以固定参考深度 `z_ref` 为零点：

```text
coupling_x(z) = g_x(z) - g_x(z_ref)
coupling_y(z) = g_y(z) - g_y(z_ref)
```

对有效且未饱和的报告计算：

```text
x_decoupled = x_raw - coupling_x(z_raw)
y_decoupled = y_raw - coupling_y(z_raw)
z_decoupled = z_raw
```

这是假设“Z 引起的横向漂移在局部可加”的第一版模型，简单、可检查、适合 PC 验证。它不把固定 Y 设为永远正确的深度补偿轴；X、Y 的模型都从当前安装姿态的真实校准数据得到。

### 3.3 何时降低去耦合强度

纯 Z 模型不能解释所有手势。当出现以下情况时，去耦合系数按 `coupling_confidence` 衰减，而不是强行修正：

- z 接近 `saturation_low` 或 `saturation_high`；
- 当前 Z 分箱样本不足；
- profile 残差超过该分箱的鲁棒尺度；
- 设备发生长 sequence gap 或 `PositionValid=false`；
- 轨迹显示持续的横向运动，不能被解释为纯 Z 漂移。

```text
xy_corrected = xy_raw - alpha * coupling_xy(z)
alpha = quality × bin_confidence × (1 - saturation_weight)
```

`alpha` 的变化只影响坐标补偿强度，不重新定义音域。每帧记录 `coupling_alpha` 和 `coupling_reason`。

### 3.4 没有 SDK 硬件校准时的 PC 操作顺序

PC 版本把“校准”限定为建立和选择 `HostCalibrationProfile`，不调用不存在的应用原点 API，也不在普通录制中偷偷学习参数。首版操作顺序固定为：

1. **Neutral capture**：手离开或保持稳定，采集有效帧，保存 `raw_reference_xyz`、每轴 MAD 和有效率。
2. **Depth-only capture**：尽量固定 XY，只改变 Z；每个 Z 区间至少保留多个有效窗口，用于拟合 `g_x(z)`、`g_y(z)`。
3. **Workspace capture**：在工作区中心、上下边界和左右边界采集稳定点，确定 `workspace_min/max`、`pitch_axis`、`b_min/b_max` 和饱和值。
4. **Profile review**：UI 同时显示原始轨迹、补偿轨迹、每个 Z 分箱样本数、残差和 `coupling_confidence`；用户显式保存 profile 后才可用于 Lead。
5. **Replay check**：用同一份 depth-only 和 workspace capture 回放，确认纯 Z 时 `pitch_coordinate` 基本不动、固定姿态量化结果稳定，再锁定 profile hash。

如果暂时没有 depth-only 数据，`coupling_model` 必须设为 `identity`、`coupling_confidence=0`，UI 显示“未建立 Z→XY 补偿”，而不是从一次普通乐句反推模型。此时仍可使用三轴抗抖和固定 PitchSpace，但纯 Z 引起的横向漂移只能被降权，不能声称已经去除。普通 Lead 录制期间禁止自动更新 profile；新采集只能生成待审核版本。

## 4. 三轴联合抗抖

### 4.1 处理顺序

不要先把 Z 单独滤掉再把 X/Y 送进旋律。推荐顺序是：

```text
质量检查
  → 饱和/异常帧遮罩
  → Z 条件 XY 去耦合
  → 三轴短窗口中值
  → 一阶低通与速度限制
  → 运动类别判定
```

这样既能保留 Z 的表达功能，也不会让 Z 噪声直接驱动音高。

### 4.2 首版参数

参数使用时间而不是固定帧数；当报告率约为 200 Hz 时，建议值对应约 5 帧：

```text
median_window: 15–30 ms
lowpass_time_constant: 35–60 ms
minimum_intent_duration: 80–120 ms
pitch_dead_zone: neutral 噪声 MAD 的 3 倍，且不小于 0.10 个固定音级间隔
note_hysteresis: 0.30–0.40 个音级间隔
maximum_coordinate_slew: profile 中记录的安全速度上限
```

这些是 PC 初始值，不是传感器规格。后续调参必须通过同一 raw capture 回放比较，不能靠每次重新手绘判断。

中值滤波负责去除孤立尖峰；低通负责削弱连续的小幅抖动；slew 限制负责防止单帧跳变制造大音程。三者都不能跨越无效区间插值。

## 5. 从手部动作中提取旋律意图

### 5.1 使用去耦合后的速度分量

在固定应用坐标中计算：

```text
v_pitch = d(pitch_coordinate)/dt
v_lateral = d(horizontal_residual)/dt
v_depth = dz/dt
```

运动类别只用于决定“是否允许改变音高”，不直接生成音符。

| 类别 | 判定 | Lead 行为 |
| --- | --- | --- |
| `DEPTH_ONLY` | `|v_depth|` 明显，去耦合横向速度低且未持续 | 保持当前音高；Z 只调制音色/力度/空间 |
| `PITCH_INTENT` | 旋律轴速度超过 dead zone，持续至少 80–120 ms | 更新连续轮廓，允许下一锚点改变音级 |
| `DIAGONAL_INTENT` | 深度与旋律轴同时持续运动 | 保留旋律轴分量，深度只影响表达层 |
| `TREMOR` | 方向快速交替、总位移小于约四分之一音级间隔 | 不生成新音符，只降低 confidence |
| `HOLD` | 三轴速度都低于阈值并持续 | 延长当前音或保持显式留白 |
| `INVALID/LOST` | PositionValid 无效、饱和或长 gap | 断开轨迹；按策略生成 rest/release，不补点 |

`DEPTH_ONLY` 不是简单地“Z 不参与音乐”，而是把 Z 从音高通道移到表达通道。这样用户仍可以用上下深度控制滤波明暗、accent、delay/reverb send 或 glide 强度。

### 5.2 抖动不能成为音符

抖动通过三个条件被拦截：

1. 位移必须超过 dead zone；
2. 方向或速度必须持续超过 `minimum_intent_duration`；
3. 量化到相邻音级后，必须通过 note hysteresis 才允许换音。

短时抖动可以影响 `confidence`、velocity 的细微变化和连续滤波参数，但不能生成 `NOTE_ON`。离线编译器还可以利用完整轨迹确认前后方向，避免把局部噪声当作 TURN/APEX。

## 6. 固定旋律空间映射

音高只使用去耦合后的固定旋律坐标：

```text
b_abs = pitch_axis · (q_decoupled - q_ref)
b_norm = clamp((b_abs - b_min) / (b_max - b_min), 0, 1)
raw_target = min_midi + b_norm × (max_midi - min_midi)
note = hysteretic_nearest_scale(raw_target, fixed_pitch_space)
```

`b_min`、`b_max`、`pitch_axis` 和 `q_ref` 都来自 profile。它们不能从当前录制重新估计。Z 不得自动改变注册区或换八度；超出安全工作区时饱和并记录 `out_of_range`。

音符生成仍使用 Lead 的锚点规则：MOVE、TURN、APEX、VALLEY、HOLD、REST 和 RELEASE 是结构证据，不是每帧音符。去耦合和抗抖只改变输入轮廓及其 confidence，不凭空补写与曲线无关的旋律。

## 7. 音频生成阶段的职责边界

音频阶段可以平滑连续表现参数，但不能修复已经错误生成的音高事件：

```text
Lead EventTable
  → note/gate/glide
  → 20–50 ms 参数 slew
  → oscillator/filter/FX
```

允许在音频阶段平滑：

- cutoff、resonance、PWM；
- velocity 到 amp 的连续包络；
- delay/reverb send；
- pan、width、LFO 深度；
- 小范围 pitch bend。

不允许在音频阶段通过低通把错误音符“滤成正确音符”。音高稳定必须在 EventTable 生成前完成。`pitch_bend` 只用于有来源的 glide 和表现层，不用于掩盖 Z 抖动。

## 8. 诊断输出与 UI 反馈

上位机必须同时显示：

1. raw XYZ；
2. 去耦合后的 XYZ；
3. XY、XZ、YZ 投影；
4. `pitch_coordinate`、`depth_coordinate`、`coupling_alpha`；
5. `DEPTH_ONLY/PITCH_INTENT/TREMOR/HOLD/INVALID` 状态；
6. PositionValid、饱和、环境噪声、sequence gap；
7. 固定 PitchSpace 音级网格和最终音符；
8. 每个音符对应的源锚点与过滤原因。

无效段必须断线显示；XY 相交但 Z 分离时保留为合法三维路径，不直接当作毛刺。UI 默认显示实际送入旋律编译器的去耦合坐标，同时允许切换 raw 层进行对照。

## 9. 验收顺序

使用同一批真实 CaptureSession 做回放，先验证坐标，再验证音乐：

### A. 坐标层

- 纯 Z 采集的 pitch 坐标标准差小于未补偿版本；
- 非饱和深度区的去耦合残差不出现明显单调趋势；
- 同一安装姿态重复采集得到相近 `coupling_alpha` 和 profile 残差；
- 长 gap、无效帧和饱和区不会被连续连线或插值。

### B. 旋律层

- 纯 Z 动作不产生新的音级序列变化，允许表达参数变化；
- 同一物理高度在不同 Z 高度重复时音名一致；
- 有意上行/下行的方向保留；
- 80–120 ms 以下的短抖动不产生额外 NOTE_ON；
- 同一 raw capture、profile 和编译器版本重复运行得到完全相同的 EventTable；
- 音频阶段参数平滑不会改变 EventTable 的 note 序列。

## 10. 当前建议与限制

PC 阶段先实现 `HostCalibrationProfile + Z 条件 XY 去耦合 + 三轴联合抗抖 + 固定音高滞回`，暂不引入神经网络或无界优化。原因是用户需要知道“怎么画”才能得到什么结果，而不是得到一条无法解释的漂亮旋律。

如果 profile 残差仍然很大，系统应明确报告“当前安装姿态不适合稳定音高映射”，而不是继续增加滤波强度。过度滤波会损失真实转折、延迟起音并让手感变钝；软件可以提高可用性，但不能恢复传感器没有提供的信息。

当前主机侧能保证的是：同一 profile 下结果可复现、纯 Z 的音高误触发显著减少、短时手抖不再制造音符、无效帧和饱和区不会被静默补线。它不能保证从单次普通手势中恢复真实三维位置，也不能完全区分“有意的斜向运动”和“手部联动造成的 XY 漂移”。遇到残差持续偏大、工作区边缘饱和或安装姿态改变时，应停止提高滤波强度，标记 profile 不适用并重新采集 profile。

