# MGC3130 Z 轴去耦合、无跳变重基准与实时时间模型

版本：2026-10-22  
状态：PC Capture & Loop 设计汇总；CLUTCH/REBASE 和实时 Transport 部分是后续实现约束。  
关联文档：[PC 上位机 XYZ 去耦合与抗抖设计](pc-host-only-xyz-filtering-design-2026-10-21.md)、[Lead 曲线意图提纯设计](pc-lead-intent-purification-design-2026-10-19.md)、[坐标与校准规范](mgc3130-coordinate-calibration-spec.md)。

## 1. 目的与不变量

MGC3130 的 Z 轴既可能表达用户的深度意图，也可能通过传感器耦合造成 XY 漂移。PC 端必须把这两个含义分开：Z 可以用于去除已校准的 XY 耦合、判断 XY 观测的可信度以及控制音色表现，但不能未经证据直接改写 Lead 音高。

本设计服务于两个阶段：

```text
当前：录制完整乐句 → 停止 → 离线编译 → 128 tick Loop
后续：固定 Transport 时钟 → 实时处理 → 有限延迟提交事件
```

两阶段都必须满足：

1. 固定 `HostCalibrationProfile` 和固定 `PitchSpace` 不因单次曲线的 min/max 改变。
2. 纯 Z 动作不能凭空改变 `b(t)` 的音高序列。
3. 原始 XYZ、时间戳、sequence 和质量字段永远保留；任何派生处理不能覆盖原始记录。
4. 无效帧、饱和帧和高 Z 不可靠区段不能被静默补写成有效旋律。
5. 处理坐标时不能改变音乐时间戳；冻结区退出时不能产生空间跳变。
6. 同一采集、profile 和配置重复处理时，结果必须确定且可复现。

## 2. 数据层和变量约定

每帧至少保留以下层次：

```text
raw_capture       原始 XYZ、sequence、设备 timestamp、质量字段
q_raw             Host profile 归一化后的坐标
q_decoupled       静态 Z→XY 耦合补偿后的坐标
q_filtered        中值、低通和常规抗抖后的坐标
q_output          CLUTCH/REBASE 后真正送入旋律解释的坐标
transport_tick    音乐时间位置；离线或实时计算，但不由空间路径决定
landmarks         MOVE、HOLD、TURN、APEX、VALLEY、REST、RELEASE 等结构证据
EventTable        固定 PitchSpace 量化后的事件
```

对于 XY 去耦合，记：

```text
r(t) = q_decoupled 的 XY 观测
p(t) = q_output 的 XY 位置
```

`r(t)` 是输入测量，`p(t)` 是音乐编译器看到的输出。两者必须同时记录，不能把输出结果伪装成原始采集结果。

## 3. 静态 Z→XY 去耦合

现有 `HostCalibrationProfile` 使用纯 Z 采集拟合分箱中位数：

```text
g_x(z) = median(x | z)
g_y(z) = median(y | z)
```

以固定参考深度 `z_ref` 为零点：

```text
coupling_x(z) = g_x(z) - g_x(z_ref)
coupling_y(z) = g_y(z) - g_y(z_ref)
```

对有效且未饱和的帧计算：

```text
x_decoupled = x_raw - alpha * coupling_x(z_raw)
y_decoupled = y_raw - alpha * coupling_y(z_raw)
z_decoupled = z_raw
```

其中 `alpha` 由 profile 置信度、Z 分箱覆盖、残差、饱和状态和 sequence gap 共同决定。`alpha` 变化只改变补偿强度，不能重建音域或改变 PitchSpace。

静态模型表达的是“某个 Z 高度通常会带来多少 XY 偏移”，不能解释所有动态运动。若纯 Z 回放仍有明显残差，应继续采集动态数据，不能无限增加低通或强行把所有 XY 都归因于 Z。

## 4. 为什么不使用高 Z 硬冻结和恢复绝对坐标

直接把高 Z 区域的 XY 输出冻结，然后在离开时恢复当前绝对坐标，会产生：

```text
冻结期间：p(t) = p_hold
恢复瞬间：p(t) = r(t_exit)
```

如果用户在冻结期间移动了，`r(t_exit) - p_hold` 就会成为一个瞬时大位移。旋律解释器可能把它识别成 `TURN`、`APEX` 或大音程跳进，制造没有输入依据的音符。

按每帧 `dt` 对 XY 限速也不是理想的第一方案。限速不会一定修改时间戳，但会改变空间轨迹随时间的形状：峰值可能被抹平，转折可能延迟，速度和曲率也会改变。随后 128 tick 重采样会忠实地采样这条新轨迹，4 tick 锚点去重还可能合并或丢弃原本分开的地标。因此限速只能作为经过回放验证的安全边界，不能作为高 Z 漂移的默认修复方式。

## 5. 推荐的 CLUTCH/REBASE 状态机

### 5.1 状态语义

```text
TRACK   正常跟踪 q_decoupled/q_filtered
CLUTCH  XY 观测暂时不可信，保持最近的 q_output
REBASE  退出 CLUTCH 后以当前采集点建立新的相对坐标原点
```

CLUTCH 只冻结 XY 输出。Z 仍可作为独立的深度表现通道，用于滤波、力度、混响、延迟或其他调制，但不能通过 Z 直接量化音高。

### 5.2 进入冻结区

使用 Z 高度、耦合残差、XY 创新量和质量字段共同判断，不使用单帧阈值。进入条件应有连续帧确认，例如：

```text
z > z_enter
或 XY 观测残差超过 profile 安全尺度
并持续 N 个有效帧
```

进入时保存：

```text
p_hold       最近一个可信的 q_output XY
clutch_start 原始 timestamp
rebase_id    本次冻结区编号
```

进入前后的输出必须连续；进入区段的原始帧仍完整写入 capture。

### 5.3 冻结区行为

```text
p(t) = p_hold
```

冻结区内不把未经验证的 XY 位移送入 Lead 音高轨迹，也不把这段位移追赶到后续输出。该段时间仍然存在于采集时间线上，因此离线或实时音乐时间不会被压缩。

诊断中应记录：

```text
xy_mode = CLUTCH
suppressed_frame_count
suppressed_duration_ms
suppressed_raw_distance
coupling_alpha
coupling_reason
```

### 5.4 无跳变退出和重基准

退出必须使用滞回和稳定帧确认：

```text
进入：z > z_enter
退出：z < z_exit，且 z_exit < z_enter
```

稳定后取当前几帧的稳健中值作为新的输入基准：

```text
r_anchor = median(r(t_exit ... t_exit + window))
p_anchor = p_hold
```

之后使用相对坐标：

```text
p(t) = p_anchor + [r(t) - r_anchor]
```

在重基准的第一帧：

```text
p(t_exit) = p_anchor
```

因此输出位置没有跳变。冻结期间的未知位移被明确丢弃；系统不假装能够从不可靠数据中恢复真实运动。下一次用户移动从新的采集位置开始计入旋律。

退出时可以先保持一个很短的 `REBASE` 状态，等候一小段稳定观测，再切回 `TRACK`。`REBASE` 帧不应单独产生 `TURN/APEX`，并且可以在 landmark 检测中标记为过渡帧。

> **实现约束（2026-10-22 决定）**：显示坐标与编译器输入必须同源，因此 **REBASE 不得作用于送进编译器的 `q_output`**。只要 `b_abs` 取自重基准后的相对坐标，每经历一次冻结—重基准就会产生一次不可逆的音高平移（65535 counts 对应 17 个半音，移动 5000 counts ≈ 1.3 个半音），持续累积，并与坐标规范 §6「同一 raw XYZ + profile 得到相同音级序列」直接冲突。落地形态改为 **证据抑制**：坐标保持绝对，冻结段标记为不可靠、不产出 landmark，退出帧禁止单独成音。详见 §5.6。

### 5.5 为什么该方案不改变音乐时间

CLUTCH/REBASE 只改变 `p(t)` 的空间值，不修改：

```text
原始 timestamp
logical_time_ms
transport_tick
loop duration
```

退出时没有追赶位移，所以不会在同一时间点产生大 `db`。只要后续真实移动满足转折阈值，才允许生成新的 landmark。

### 5.6 显示与编译同源（WYSIWYG）

操作者只能通过 UI 曲线判断这一笔会被编译成什么，因此**画布上画出的曲线必须就是送进编译器的坐标**。任何只作用于其中一侧的隐藏变换都会破坏这个闭环：用户按噪声作画，编译器按平滑后的形状出音。

这条约束排除三种做法：

1. 显示用 `q_output`、编译用另一个坐标；
2. 显示层做 REBASE 而编译器读绝对坐标（或反之）；
3. 显示端用原始 `x/y`、编译器用滤波后的 `q_app`。

**当前代码曾违反第 3 条**（2026-10-22 修复）：画布直接读原始 `row["x"]`，而编译器用的是 `project_sample` → 5 点中值 + 一阶 IIR 之后的坐标，两者相差一整个滤波环节。修复方式是新增 `StreamingLeadFilter`，逐帧复现批量滤波的结果并输出 `i-2` 的值（约 10 ms 显示延迟），使画布曲线与 `preprocess_samples` 的输出逐帧一致；等价性由单元测试固定。

由此得到的处理顺序是单一的：

```text
raw_capture → project_sample → 滤波（中值 + IIR） → 画布 / 编译器共同输入
             → 起笔门控（原始 X 判定） → 标记 unreliable 的区段 → landmark → EventTable
```

冻结/不可靠只改变**证据**（是否产出 landmark、是否允许成音），不改变坐标、不改变时间戳。原始帧始终完整落盘，诊断里保留 `q_decoupled` 与不可靠区段计数。

### 5.7 命名澄清

`q_output` 在本设计里指"送进编译器的坐标"。在 WYSIWYG 约束下，它必须与画布坐标相同；不可靠区段用独立的置信标记表达，而不是用另一套坐标值表达。

## 6. 离线 Capture & Loop 时间模型

### 6.1 采集进度必须由时间定义

停止录制后，使用 sequence 优先恢复帧顺序，再使用单调逻辑时间计算进度：

```text
u_i = (t_i - t_start) / (t_end - t_start)
tick_i = u_i * (loop_ticks - 1)
```

当前 128 tick 的 `resample_to_ticks()` 已采用“按 timestamp 在完整采集区间内插值”的策略。对于 Lead，`t_start` 应是左侧起笔门控确认的第一帧；起笔前缓存只用于诊断，不占用正式乐句时间。

> **已实现（2026-10-22）**：`_phrase_window()` 以首个 `accepted` 帧为起点，门控先于时间归一化执行。此前 `t_start` 取整段采集第一帧，若录制后等待再起笔，prestart 会按比例吃掉 tick；实测各段 pre-roll 为 0.8–3.2 s。回归测试固定了“起笔帧 `a_rel = 0` 且首个有效 tick ≤ 2”。

这意味着：

- 冻结区仍然占用音乐时间并形成保持段；
- 无效区段不能被无声删除，否则会压缩后续节奏；
- 过滤器可以改变坐标，但不能把时间点重新排序或重写成空间弧长；
- 弧长可以用于判断速度、转折和曲率，不能取代音乐时间轴。

按帧编号采样 `i/(N-1)` 会忽略丢帧和不规则间隔；按弧长采样会把空间距离误当成节奏，二者都不是当前 Loop 的默认时间模型。

### 6.2 128 tick 与 4 tick 锚点间隔

128 tick 是固定 Loop 内的音乐离散网格。4 tick 是锚点事件去重规则，不是传感器采样率：两个候选 landmark 的 tick 距离小于 4 时，应在编译阶段合并、替换或抑制。

空间过滤改变的是 landmark 候选，128 tick 只负责把它们放到音乐时间上；两者不能互相改变时间戳。CLUTCH/REBASE 通过保持输出连续，避免在退出帧产生额外的假 landmark。

## 7. 后续实时模式时间模型

实时模式不能使用“当前时间/最终采集总时长”，因为录制尚未结束。必须使用固定的 Transport 时钟：

```text
tick_float = elapsed_seconds * BPM / 60 * ticks_per_beat
current_tick = floor(tick_float) % loop_ticks
```

如果 Lead 由左侧起笔门控启动，门控确认时间是 `transport_origin`。如果未来采用全局节拍器，则可以把确认事件量化到下一个拍或小节，而不是重置全局时钟；这应作为显式模式选择。

实时系统不应每帧重新编译整个 128 tick。推荐使用按 tick 的累积器：

1. 将新帧归入当前 transport tick；
2. 对该 tick 的坐标取稳健代表值；
3. 计算当前候选 landmark 和状态；
4. 保留少量待确认 tick；
5. 超过确认窗口后提交 EventTable/MIDI 事件。

未来数据还没到时，单帧局部峰值可能随后被推翻。因此 `TURN/APEX` 需要短暂 pending buffer，或者允许事件修改。实时实现优先使用小延迟确认；4 tick 最小间隔在提交前的 pending 队列内执行，避免已经发出的两个事件无法再合并。

> **延迟预算（2026-10-22）**：100 BPM 下 1 个 16 分 tick 是 150 ms，4 tick 就是 600 ms。用 4 tick 确认再提交，意味着演奏延迟至少 600 ms，实时不可用。实时模式只能二选一：提交延迟压到 1 tick（约 150 ms）并允许在下一个 tick 边界修正上一 tick 的事件；或者明确把实时定位为"低精度预览"，最终版本仍由停止后的离线重编译产出。不能同时承诺 4 tick 确认和低延迟。

实时模式仍应同时保存原始 JSONL。实时事件用于低延迟演奏，停止后可以用完整采集重新编译，生成更准确的最终 EventTable。

## 8. 采集与验证方案

在实现动态策略前，应使用固定安装姿态采集以下数据，并保留原始时间戳：

1. **纯 Z**：固定 XY，分低、中、高 Z 多次上下移动。
2. **高 Z 静止**：在高 Z 区域保持不动，测量漂移和残差。
3. **不同 Z 的同一 XY 线**：在低、中、高 Z 重复相同水平和旋律轴移动。
4. **进入/退出冻结区**：缓慢经过 `z_enter/z_exit`，检查输出是否连续。
5. **冻结期间移动**：明确记录“冻结区位移被丢弃”的可接受程度。
6. **真实转折**：在可靠区域制造上行、下行和快速反向，确认不会被 CLUTCH 规则吞掉。

每次回放至少比较：

```text
raw XY 与 Z
静态去耦合前后残差
coupling_alpha 与 coupling_reason
q_output 的最大单帧跳变
CLUTCH/REBASE 区段数量和持续时间
b_abs 的方差与方向
landmark tick、kind、来源帧
EventTable 音级、时值和置信度
```

重点验收：

- 纯 Z 不产生新的 Lead 音级变化；
- 高 Z 进入和退出没有 `q_output` 跳变；
- 退出帧不会单独产生 `TURN/APEX`；
- 有意的可靠区段反向移动仍能产生合法 landmark；
- 同一 capture 重放的 `q_output`、landmarks 和 EventTable 完全一致；
- 过滤和重基准不改变原始时间线；
- 实时模式的 tick 只由 Transport 时钟决定，不由路径长度或当前曲线 min/max 决定。

## 9. 相对光标与 Z 调速（2026-10-22 修订，取代 CLUTCH/REBASE）

用户明确了 Z 的真实诉求：**不是去耦合，而是表达**——抬手越高，绘制越慢，越能做细节；同时 Z 应当直接进入力度，让"力度和情绪"可听。这个诉求把整套方案从"绝对映射 + 补丁"改成了"相对积分 + 高度档位"。

### 9.1 模型

```text
d = q_decoupled(t) − q_decoupled(t−1)
gain(z) = g_max − (g_max − g_min) · clamp((z − z_low)/(z_high − z_low), 0, 1)
if engaged and |d| > deadzone:
    cursor += gain(z) · axis_scale · (d − deadzone·sign(d))
pitch 由 clamp(cursor.y, 0, 1) 经固定 PitchSpace 量化
```

参数由实测确定（96759 个有效帧的 z 分布：p25 = 3784、p50 = 6352、p75 = 10476、p90 = 24414）：

```text
z_low    =  4000      # 低于此高度 = 最快档
z_high   = 24000      # 高于此高度 = 最慢档
g_max    =  1.00
g_min    =  0.25      # 高处同样的手部移动只走 1/4
z_engage = 30000      # 低于此高度重新接合
z_release= 36000      # 高于此高度视为抬起
deadzone = 0.0004     # 归一化坐标，约 26 counts，高于实测抖动 10–13
axis_scale = (1.0, 1.543)   # 见下
```

### 9.1.1 轴向等比（数位板模型）

用户要求接近数位板：同一物理距离在 X、Y 上应当产生同样的光标位移。对一段沿传感器方形边缘绕行的采集（`lead_20261022-195051`，2449 帧）统计逐帧步长：

```text
Σ|dx| = 207761    Σ|dy| = 134631    ratio = 0.648
```

即同一物理距离下 Y 轴只产生 X 轴的 64.8% 的 counts，直接绘制会把方形压成扁矩形。因此在 `axis_scale` 里把 Y 乘 `1/0.648 ≈ 1.543`，使两轴单位物理距离的贡献相等。

该系数来自单次绕边采集，属于**暂定标定值**；若后续发现仍不等比，应重测而不是继续目测微调。

### 9.1.2 抬高阈值

原 `z_engage = 16000 / z_release = 20000` 明显偏低：全部采集中有 **24.1% 的帧 z > 20000**，意味着正常演奏就被判成"抬起"。改为 30000 / 36000 后，只有 14.4% / 10.6% 的帧越过阈值，绕边采集的接合率从被大量误断提升到 **93%**。抬高是刻意的动作，日常高度不再触发断开。

### 9.2 为什么这取代了 CLUTCH/REBASE

相对积分下不存在"绝对坐标跳变"：抬起时丢弃增量，落下时从当前光标继续，天然连续。因此 §5 的进入条件、`p_hold`、`r_anchor`、`p_anchor` 全部不再需要；`z_enter/z_exit` 也不再是去耦合阈值，只剩下"这次是否算作操作"的判定（触电极或 z 阈值）。

副作用是**放弃一条冻结不变量**："同一物理高度 → 同一音名"改为"同一光标高度 → 同一音名"。这对演奏者更可控（看得见光标），但属于契约变更，必须同步修改坐标规范 §6 与 Lead 文档 §13.7 的不变量清单。

### 9.3 Z 直接进入力度

原来力度只由速度决定（`68 + 35·speed`），缓慢绘制时几乎恒定，所以 Z 听不出来。现在：

```text
z_norm    = clamp((z − 4000) / 20000, 0, 1)     # 0 = 贴近，1 = 抬起
proximity = 1 − z_norm
velocity  = clamp(40 + 55·proximity + 22·clamp(speed·12), 32, 122)
```

低且快 = 117，高且慢 = 40，跨度足够覆盖从"贴近重音"到"远处气声"。事件表新增 `z_norm`、`proximity` 两个字段，便于回放诊断。实测 19:32 那段：velocity 62–108，随高度变化可见。

### 9.4 当前实现状态

| 部分 | 状态 |
| --- | --- |
| `RelativeCursor`（积分 + 死区 + `gain(z)` + 接合标志） | ✅ 已实现并有单测 |
| Z 阈值接合（`z_engage = 16000`、`z_release = 20000`，带滞回） | ✅ 已实现 |
| Z → velocity 表达映射 | ✅ 已接入 `compile_lead` |
| 光标接入编译器音高 | ✅ `compile_loop` 默认 `pitch_source="cursor"` |
| 光标接入 UI 绘制 | ✅ 画布改为三维等距视图，画光标轨迹 |
| 左侧起笔门控 | 光标模式下由"首次接合"取代 |

光标接入后，产品路径（UI 的 `compile_loop`）默认使用相对光标；`compile_lead`/`preprocess_samples` 的库默认仍是 `absolute`，便于对同一段采集做 A/B 与保留原有回归测试。

**三维视图**：画布改为等距投影，`X/Y/Z` 三轴使用同一个像素尺度（单位步长在三个方向上等长，实测 143.33 px），因此方形区域画成方形；音级向导线沿 Y 轴投影，与光标轨迹严格对齐。画面数据来自 `cursor_x`/`cursor_y`/`z_norm`，与编译器输入同源。

### 9.5 本轮方向性改动汇总（2026-10-22）

按时间顺序，本轮确定并落地的方向：

| # | 决定 | 提交 |
| --- | --- | --- |
| 1 | **显示即编译输入（WYSIWYG）**：画布画的必须是编译器吃的坐标，不允许两套坐标 | `da74dde` |
| 2 | **乐句时钟从起笔帧开始**：prestart 不占用 128 tick | `0ca96a6` |
| 3 | **无手帧判无效**：`x=65535, y=0` 的签名不再被当作位置 | `cb04b42` |
| 4 | **相对光标取代绝对映射**：积分增量，不再把 raw 范围硬映射到三维空间 | `f58be45` |
| 5 | **Z 控制光标速度**：`gain(z)` 1.0 → 0.25，高度 = 精度档位 | `f58be45` |
| 6 | **Z 直接进入力度**：`velocity` 由高度与速度共同决定 | `f58be45` |
| 7 | **Z 阈值接合**：`z > 20000` 视为抬起、`z < 16000` 重新接合 | 本次 |

第 4–7 条共同构成一个结论：**CLUTCH/REBASE 不再需要**。相对积分天然没有跳变，抬起阈值只决定"这段增量是否计入"，不需要保存 `p_hold`、也不需要重基准。本文件 §5 保留为历史分析，实现时应以 §9 为准。

同时修订了一条冻结不变量：原「同一物理高度 → 同一音名」改为「**同一光标高度 → 同一音名**」。相对模型下物理高度不再直接决定音高，这是刻意的表达设计；坐标规范 §6 与 Lead 文档 §13.7 的不变量清单需要同步更新。在更新完成前，以本文件 §9 为准。

**仍未接线**：光标还没有进入 `compile_lead` 的音高路径和 UI 绘制，当前音高仍来自绝对 `q_app`，所以第 4、5 条的效果暂时只体现在力度上。这是下一步唯一的阻塞项。

## 10. 实现边界

第一阶段只需要完成并验证：

```text
固定 HostCalibrationProfile
→ 静态 Z→XY 分箱补偿
→ 质量与残差诊断
→ CLUTCH/REBASE 状态机
→ 固定时间戳的离线 128 tick 重采样
→ 固定 PitchSpace 和 landmark 编译
```

实时模式属于后续扩展，需要增加：

```text
TransportClock
TickAccumulator
PendingLandmarkBuffer
事件提交/修改策略
实时 MIDI 或音频调度
```

不应为了提前支持实时模式而把当前离线编译改成按帧编号、按弧长或按未知最终时长动态拉伸。正确的抽象是：原始采集时间、离线归一化时间和实时 Transport 时间是三种明确的时间坐标；空间处理只能改变坐标值和置信度，不能偷偷替换时间坐标。

