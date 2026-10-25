# Lead 实现状态基线（as-built）

版本：2026-10-25
状态：实现事实基线。本文记录 Lead 链路**当前代码实际行为**，用于和设计文档对照。若本文件早期章节与第 8 节或当前代码冲突，以当前代码为准。
角色划分：[系统设计](mgc3130-melodic-synthwave-system-design-2026-10-19.md) 定义产品意图，[Lead 意图提纯设计](pc-lead-intent-purification-design-2026-10-19.md) 与 [XYZ 去耦合设计](pc-host-only-xyz-filtering-design-2026-10-21.md) 定义目标算法，**本文定义今天的真实行为**。三者冲突时，先以本文确认"现在是什么"，再决定改代码还是改设计。

## 1. 维护规则

只要改动触及 Lead 的数据流、阈值、事件字段或渲染，必须在同一提交内：

1. 更新本文对应章节和变更记录；
2. 更新受影响的设计文档章节（若改变了设计意图，不只是实现细节）；
3. 跑通第 9 节的验证命令；
4. 单独一次 git 提交，提交信息写明"改了什么 + 为什么 + 影响哪些文档"。

不满足以上条件的 Lead 改动视为未完成。本文不描述"应该怎样"，只描述"现在怎样"。

## 2. 入口

| 入口 | 命令/位置 | 说明 |
| --- | --- | --- |
| GUI | [pc_receiver/synthwave_ui.py](../pc_receiver/synthwave_ui.py) | `RECORD → STOP → COMPILE LOOP → PLAY PREVIEW / Export Event JSON / Render WAV` |
| CLI | `python tools/synthwave_loop.py capture.jsonl` | 输出 events JSON、WAV，并打印诊断 |
| 回放（带 host profile） | [tools/replay_host_filter.py](../tools/replay_host_filter.py) | 唯一真正使用 `HostCalibrationProfile` 的入口 |

GUI 与 CLI 主程序**都不传** `host_profile`，因此两者走的是同一套轻量预处理分支（见 4.2）。

## 3. 数据契约

Lead 输入是 `type: "position"` 的 JSONL 记录：

```text
timestamp_ms / timestamp     毫秒；CLI 导入缺省时用记录序号填充
sequence                     帧号；存在且每行都有时决定顺序
x, y, z                      0–65535 原始传感器值
position_valid               true / false / null；null 表示"未上报质量"
touch_flags, tap_flags       仅其他五轨使用
```

有效性解析统一走 [host_xyz_filter.valid_flag()](../tools/host_xyz_filter.py)：

- `null`、字段缺失 → **视为有效**（live receiver 尚未上报硬件质量位）；
- 显式 `false` / `0` / `"false"` → 无效；
- 未知字符串 → 回退默认值（Lead 路径默认有效）。

排序统一走 [host_xyz_filter.capture_order()](../tools/host_xyz_filter.py)：每行都有 `sequence` 时按序号排，否则按时间戳排。这条规则在 `load_jsonl_records`、`filter_capture`、`preprocess_samples` 三处都生效，因为设备帧计数器会回绕，时间戳排序会把句首几帧甩到末尾。

## 4. 管线

```text
JSONL / live receiver
  → capture_order
  → project_sample（应用坐标，归一化 0–1）
  → 5 帧中值 + 一阶 IIR
  → 左沿起笔门控
  → 重采样到 128 tick（插值 + move/hold/rest 状态机）
  → 地标提取（7 类锚点）
  → 锚点选择（≥4 tick 间隔）与滞回量化
  → Lead EventTable
  → compile_loop 合并六轨
  → render_loop 渲染 WAV
```

### 4.1 采集与缓冲

- live receiver 以子进程 stdout 逐行输出 JSONL，`pump()` 线程入队，`_poll_inbox` 每 40 ms 取空。
- Lead 录制时，UI 默认 cursor 路径先经过 `StreamingLeadFilter` 和 `AbsoluteCursor`；第一帧有效接合后进入 `lead_preview_capture`。旧的 `LeadStartGate` 左沿门控仍用于 absolute/HostProfile 编译路径，不是当前 UI 默认 cursor 路径。
- 停止后 `current_capture` **原样**存入 `lead_samples`，门控在编译阶段由批量实现重跑，两处语义必须保持一致。

### 4.2 预处理 `preprocess_samples`

不传 `host_profile` 时（GUI/CLI 主路径）：

1. `project_sample`：`q_app = (raw − offset) · R · S`，默认 `S = 1/65535`、`offset = 0`、`R = I`，所以 `q_app`、`b_abs`、`c_abs` 都是 0–1。`b_abs` 投影到 `pitch_axis`（默认 +Y），`c_abs` 投影到 `color_axis`（默认 +Z）。
   无手在场时设备报 `x=65535, y=0, z=65535`，该签名被识别为无效帧（`_looks_absent`），不再作为坐标参与绘制或成音。
2. 三轴滤波：5 点滑动中值，仅当 `|value − median| > max(0.035, 6·MAD)` 时用中值替换（只压孤立尖峰）；随后一阶 IIR，固定 `α = 0.35`（按帧数，不按时间）。
3. `a_rel = (t − t_start) / (t_end − t_start)`。
4. 批量 `_apply_lead_start_gate` 复核：未通过门控的帧保留在数据里但 `position_valid = False`。

**时间窗口从门控确认帧开始**：门控在时间归一化之前执行，`a_rel` 与 128 tick 重采样都只覆盖首个 `accepted` 帧到末帧，prestart 帧不占用乐句时间。此前 `t_start` 取整段采集的第一帧，录制后等待几秒再起笔会吃掉最多约 33 个 tick。

UI 的预览曲线通过 `StreamingLeadFilter` 复用同一组滤波参数（中值窗口与 IIR 系数），逐帧复现批量结果后再绘制，因此**画布显示的就是这里产出的坐标**（WYSIWYG）。原始帧仍完整保存在 capture 文件中，不属于显示层。

传 `host_profile` 时另有一条链路：`filter_capture` → Z 条件 XY 去耦合 → 时间窗中值 / 时间常数低通 / slew → `b_abs` 用 profile 的 `b_min/b_max` 归一化。两条链路产出同一组字段，但**缩放来源不同**，同一份 raw 数据在两条链路上的音高结果不保证相同。

### 4.3 起笔语义（按编译路径区分）

absolute/HostProfile 路径仍把 Lead 视为"从左向右"的开放路径，规则为：

```text
left_edge_max      = 4096 / 65535 ≈ 0.06250   （原始 X ≤ 4096 视为左边缘）
min_rightward_delta = 256 / 65535 ≈ 0.00391   （离开边缘的最小右移）
```

状态机：`awaiting_left_edge → edge_candidate →（右移 ≥ 256）→ rightward_confirmation_pending →（下一帧 X 继续增大）→ accepted`。边缘区内的候选点不断被更新，最终只有**最后一个**边缘点被回溯确认为句首。未确认的帧全部 `prestart` 且无效。

门控判断使用**原始传感器 X**，不是 `q_app` 投影 X——目的是避免中值/低通把边缘接触抹进工作区。这隐含"原始 X 方向即应用左方向"的假设，若校准 `R` 含 X 镜像，语义会反转。

当前 GUI/`compile_loop` 默认使用 `pitch_source="cursor"`。该路径不调用上述左沿门控，而是从首个有效接合帧开始；抬手后光标保持，重新接合帧标记为 `cursor_rebased`/过渡帧，不单独成音。恢复左沿限制需要显式切换回 absolute/HostProfile 路径或另行修改 cursor 门控。

### 4.4 重采样 `resample_to_ticks`

有两种时间映射，由 `time_map` 选择：

| 模式 | 规则 | 节奏由什么决定 | 用途 |
| --- | --- | --- | --- |
| `stretch`（库默认） | 整段采集线性映射到 128 tick | **录制时长**（相对节奏） | 旧行为、A/B |
| `loop`（UI 使用） | `tick = (t − t0) / 150 ms`，超过 128 回绕，后一圈覆盖前一圈 | **绝对时间**（你弹多快就是多快） | 循环录制 |

100 BPM 下 `loop` 模式的 1 tick = 150 ms，与录制多长无关。未到达的 tick 保持无效（rest），不会被拉伸填充；诊断的 `coverage` 在该模式下表示"128 tick 中有多少被覆盖"，UI 状态行会显示 `loop covered N%`。

`loop` 模式的分段在覆盖区段上分别进行，因此短录制的未覆盖部分是休止，不会用前一段的值延续成假长音。

**Loop 长度可以跟随录制**：`compile_loop(..., auto_length=True, max_bars=32)` 时，`length_from_take()` 把 `loop_bars` 改成「录制时长 ÷ 每小节时长，向上取整」，上限 `max_bars`。100 BPM 下 43 s → 18 小节（43.2 s）。渲染、伴奏、事件表都读 `config.loop_bars`，所以长度自然一致。

**分层录制**：`compile_loop(..., lead_layers=[layer0, layer1, ...])` 把每一层单独编译后合并进 `lead` 轨，事件带 `layer` 字段。同一 tick、同一音高、同一时值的事件会被去重（避免同相位叠加）；诊断给出 `layers` 与 `layer_notes`。

其余细节：

- 目标 128 个 16 分 tick，按时间线性插值 `b_abs / c_abs / q_x / q_y / q_z / cursor_x / cursor_y`。
- 两端都有效才插值；只有一端有效取该端；两端都无效填 `None`。
- `position_valid` 要求左右两侧都有效，因此 prestart 与无效段会扩展成 rest 而不是被补线。
- 逐 tick 状态机：

```text
db = b[i+1] − b[i−1]；dc = c[i+1] − c[i−1]；speed = hypot(db, dc)
无效          → rest
speed < 0.002 → hold
其它          → move
curvature     = db[i+1] − db[i−1]
```

### 4.5 地标 `extract_landmarks`

| 地标 | 判定 | 备注 |
| --- | --- | --- |
| `move` | 首帧有效 | 句子起点 |
| `rest` | 连续 rest 段首帧 | 显式留白/无效 |
| `hold` | 连续 hold ≥ 2 tick，取段中点 | 门槛很低 |
| `apex` / `valley` | 局部极值且 `b` 差 > 0.012 | 0.012 × 17 半音 ≈ 0.2 半音 |
| `turn` | `db` 前后变号且两侧 > 0.0015；或 hold→下行 | 无方向滞回、无最小持续时间 |
| `release` | 末帧有效且非 rest | 结束 gate |

同一 tick 同一类型只保留一个。

### 4.6 锚点到音符 `compile_lead`

1. **选锚点**：只取 `move/hold/turn/apex/valley/release`。与上一个选中锚点距离 `< 4 tick` 时，若当前是 `turn/apex/valley` 就替换上一个，否则丢弃。这就是当前"每 16 分最多一个 NOTE_ON、最小间隔 4 tick"的全部实现。
2. **音高**：

```text
raw  = 55 + clamp(b_abs, 0, 1) × (72 − 55)          # G3–C5
note = 若 |raw − prev| ≤ 0.10 且 prev 在音阶内则保持，否则取最近音级
```

音级表 `[55 G3, 57 A3, 60 C4, 62 D4, 64 E4, 67 G4, 69 A4, 72 C5]`（A 小调五声，音级类 `{0,2,4,7,9}`）。

3. **时值**：`duration = 下一个选中锚点 tick − 当前 tick`，最小 2；最后一个到 128。
4. **力度**：`velocity = 68 + 35 × clamp(speed × 12)` → 48–118，纯速度驱动。
5. **演奏法**：`hold/move` 或 `duration ≥ 8` → legato（`gate_ratio 0.92`），否则 pluck（`0.72`）。glide 85 ms，首音 0，`tie` 恒为 `false`。
6. **色彩层**：`floor(clamp(c_abs) × 2.999)` → 0/1/2，**只记录不参与选音**。
7. **rest 事件**：每个 rest 锚点补一个到下一锚点的显式 rest。
8. **状态**：有效帧 < 2 → `insufficient_capture`；选中锚点 ≤ 1 → `weak_motif`；否则 `ok`。

### 4.7 其他五轨与合并 `compile_loop`

`_record_track` 用 `touch_flags/tap_flags` 的上升沿触发，每轨最多 16 事件：Bass 三分区根音/五度/八度，Pad 整和弦加转位，Arp 和弦上下行每步 +4 tick，Drums 五电极映射 36/38/42/46/49，Texture 产出 `control_point`。Lead 事件直接取自 `compile_lead`，**无 16 音上限**。

### 4.8 渲染 `render_loop`

22050 Hz 单声道加法合成 + 全局 `tanh` 限幅。Lead 有 ADSR（35/180/520 ms，sustain 0.72）、85 ms glide、4.2 Hz / 11 cents vibrato、0.08 Hz cutoff LFO；波形为手写三音混合；延迟 620 ms 两抽头（feedback 0.30），37 ms 短混响。**没有滤波器、chorus 或 sidechain**，`cutoff_hz` 参数未使用。

### 4.9 结构参数化

音阶、和声、拍号与 Loop 长度从"写死的常量"提升为 `PitchSpace` 与 `SynthwaveStyle` 的字段，由调用方显式传入：`PitchSpace(scale_pitch_classes=..., min_midi=..., max_midi=..., center_midi=...)`，`SynthwaveStyle(harmony=..., bpm=..., loop_bars=..., ticks_per_bar=...)`。和弦从 `style.harmony` 的名称解析，不再硬编码 `Am–F–C–G` 的根音表。

这样换音阶、换和声、换长度只改配置，不改算法；输出格式仍是 EventTable / WAV。

**音符生成方式也是参数**：`note_source="anchors"`（默认，转折/极值锚点）或 `"variational"`（Potts 分段）。变分模式的密度由 `lam` 控制，UI 的 DENSITY 滑块按 `λ = 0.5·60^density` 映射；两种模式共享同一 `EventTable` 契约，可对同一采集直接对比。变分模式的前向填充使抬手表现为长音持续，因此不产生 rest。

### 4.10 意图特征层 `intent_features`

曲线是矢量值函数；音符需要的每个量都是它的一个标量泛函。这一层显式化，**只产生特征、不产生事件**，两种音符生成方式都读同一份数据。

每个 tick 一行：

```text
tick, pitch(半音), pitch_norm(0-1), bow(cursor_x), height(q_z),
speed, direction(-1/0/1), valid, engaged
```

结果写入 `result["intent"]`，诊断里附 `intent_summary`（音高范围、平均速度、接合率、方向反转次数）。故意**不含曲率/挠率**：实测 200 Hz 下曲率中位数 11.9、MAD 11.1（p10 0、p90 143.8），噪声主导，需先做尺度空间平滑。

## 5. 参数速查

| 量 | 当前值 | 位置 |
| --- | --- | --- |
| 音域 | MIDI 55–72（G3–C5） | `PitchSpace` |
| 音级表 | 55/57/60/62/64/67/69/72 | `PitchSpace.scale_pitches` |
| 量化滞回 | 0.10 半音 | `PitchSpace.hysteresis` |
| 重采样 | 128 tick，线性插值 | `resample_to_ticks` |
| 中值窗口 | 5 帧，阈值 `max(0.035, 6·MAD)` | `preprocess_samples` |
| 低通 | `α = 0.35` / 帧 | `preprocess_samples` |
| hold 速度阈值 | 0.002 | `resample_to_ticks` |
| 极值幅度阈值 | 0.012 | `extract_landmarks` |
| turn 方向阈值 | 两侧 `|db| > 0.0015` | `extract_landmarks` |
| 最小锚点间隔 | 4 tick | `compile_lead` |
| 力度映射 | 48–118，速度驱动 | `compile_lead` |
| 起笔门控 | absolute/HostProfile：左沿 ≤ 0.0625、右移 ≥ 0.00391；UI cursor：首个有效接合帧 | `LeadStartGate` / `AbsoluteCursor` |
| 渲染 | 22050 Hz，ADSR 35/180/520 | `render_loop` |

## 6. 事件与诊断字段

Lead `note_on` 事件：`tick, duration, note, velocity, source="trajectory", source_landmarks, raw_target_midi, target_scale_index, quantization_delta, register_id(=0), color_layer, out_of_range, b_abs, b_norm, confidence, pitch_profile_hash, correction_reason, articulation, gate_ratio, legato, tie, glide_ms, accent, release_tail, generated_reason`。

诊断：`status, coverage, lead_start_gate{left_edge_max, min_rightward_delta, accepted, accepted_count}, landmark_counts, no_source_count, capture_hash, pitch_profile_hash, calibration_profile_hash, mode, host_profile_hash, host_filter`。

`capture_hash` 按时间戳排序后计算，因此与输入行序无关；时间戳回绕时它反映的是排序后的集合，不是采集顺序。

## 7. 与设计文档的偏差

| 设计文档要求 | 当前实现 | 影响 | 处置 |
| --- | --- | --- | --- |
| HostCalibrationProfile 先去耦合再编译 | profile/replay 路径支持；GUI/CLI 默认不传 profile | 普通 UI cursor 路径仍可能保留传感器耦合 | 保留显式 profile 回放；是否默认加载仍待定 |
| 五类运动意图（DEPTH_ONLY/PITCH_INTENT/TREMOR/HOLD/INVALID） | 只有 move/hold/rest | 无法区分深度移动与音高意图，无 TREMOR 抑制 | 待实现 |
| `pitch_dead_zone` = 3×MAD 且 ≥0.10 音级 | 未实现，只有 0.10 半音滞回 | 慢速小幅漂移可能连续换音 | 待实现 |
| 每小节 ≤8 onset、全曲 ≤16 Lead 音符 | Lead 无上限，仅 4 tick 间隔 | 长句音符数远超设计 | 待实现（会改变音乐结果） |
| 强拍落和弦音、弱拍五声经过音 | 完全不查和弦 | 强拍可能落在非和弦音 | 待实现（会改变音乐结果） |
| 动机提取、八小节句法、Intent/Song、Baseline/Advanced | 未实现 | 仅单一 Direct 路径 | 后续阶段 |
| 跨 Loop `tie/carry` | `tie` 恒 false | 第 8→1 小节无显式承接 | 待实现 |
| LeadPatch 全链路（LP24、chorus、带限振荡器） | 简化加法合成，无滤波器 | 音色偏暗、偏单薄 | 待实现 |
| 量化滞回 0.15–0.25（Lead 文档）/ 0.30–0.40（系统设计） | 0.10 | 两份文档本身也不一致 | 需先统一文档值 |
| 门控按应用坐标左边缘 | absolute/HostProfile 按原始传感器 X；UI cursor 不执行左沿门控 | absolute 路径在 X 镜像时语义可能反转；cursor 路径不强制左起笔 | 需决定是否把左沿限制统一接入 cursor |

## 8. 已知限制

- 跟踪中的缺陷与未决设计问题单独记录在 [Lead 开放问题记录（2026-10-22）](lead-open-issues-2026-10-22.md)，包括掉帧归因、传感器中心偏移、Z→XY 漂移与状态估计可行性。
- **音高默认来自光标（绝对/数位板映射）**。`compile_loop`（UI 路径）以 `pitch_source="cursor"` 调用：传感器矩形边缘到边缘映射到光标 0–1，Y 区间收窄到 X 的 0.648 以保持等比；`cursor += alpha(z)·(target−cursor)`，α 从 1.0（低）降到 0.12（高），只影响跟随速率不影响最终位置。`compile_lead` 的库默认仍是 `absolute`（绝对 `q_app`），便于 A/B。
- **抬起阈值**：`z > 36000` 断开、`z < 30000` 重新接合；接合帧标记 `rebased` 并判为无效，避免追赶位移被读成转折。
- **画布为 XY 俯视图 + Z 色标**：深度分 10 阶、连续同阶段合并绘制，实测 1983 点时 58–307 图元、4.7–5.7 ms。详见 [PC 界面规格 §3](pc-ui-spec-2026-10-22.md)。
- GUI 的 `BPM` 与 `Swing %` 控件**未接线**，编译始终使用 `STYLE` 默认值（100 BPM / 0.50）。界面上显示的数值不代表实际编译参数。
- CLI 主程序把所有输入记录同时喂给五个非 Lead 轨，等于用同一份数据反复触发 Touch/Tap，只适合快速冒烟。
- 被门控拒绝的录音报 `weak_motif` + 单个 rest，没有区分"未从左侧起笔"与"画得太平"，与设计文档 §11 要求的可解释失败不符。
- 测试套件里有两套导入约定：`tools/test_ambient_analyzer.py`、`tools/test_capture_mgc3130.py`、`pc_receiver/test_capture_loop.py` 使用裸模块导入，必须从所在目录运行；从仓库根用 `discover -t .` 会报 `ModuleNotFoundError`。`pc_receiver/test_live_bridge.py` 导入的 `live_bridge` 模块已随 LIVE 分支废弃而不存在，属遗留孤儿测试。两者都是既有状态，与本链路无关。

## 9. 验证

```powershell
cd mgc3130_uart
$env:PYTHONPATH="."
python -m unittest tools.test_synthwave_loop        # 24 项，含门控、回绕、null 有效性
python -m unittest tools.test_host_xyz_filter tools.test_replay_host_filter
cd pc_receiver
python -m unittest test_capture_loop
```

当前测试覆盖：absolute/批量左沿门控、cursor 接合与抬手、时间戳回绕（有/无 host profile）、null 有效性、显式无效帧、固定音域与地标来源、确定性、渲染输出非空、host filter 诊断透传。

## 10. 变更记录

### 2026-10-22

- **修复**：`position_valid: null` 曾被当作无效，导致 live receiver 下整段 Lead 被丢弃。新增 `host_xyz_filter.valid_flag()` 作为唯一解析入口，替换 `synthwave_loop` 中 6 处裸 `bool()`。
- **修复**：序列号排序此前只覆盖非 host_profile 分支；`filter_capture`、`preprocess_samples` 的 host 分支、`load_jsonl_records` 都按时间戳排序，回绕时帧序错乱。三处统一改用 `capture_order()`。
- **新增**：本文档，作为 Lead 实现事实基线。
- 测试从 20 项增至 24 项。

### 2026-10-21 之前（已在库中）

- 左沿起笔门控（流式 `LeadStartGate` + 批量 `_apply_lead_start_gate`）与对应设计文档 §9。

### 4.11 门控来源 gate_source

音符何时发声、发多久由门控决定，与音高分离：

| 模式 | 触发 | 时值 | 静音条件 |
| --- | --- | --- | --- |
| ow（默认直到 2026-10-25） | X 方向往返的极值（死区 0.10） | 到下一段或下一次运弓 | 手停住 |
| 	ouch | 触控电极接触的上升沿 | 接触持续时间，且在音级变化处截断 | 手悬空 |

	ouch 模式要求接收器启用触控检测（gestic_set_touch_detection，2026-10-25 起默认开启）。同一音高连续按压 = 多次触发，这正是同一个音做几个短节拍的实现方式。

每个事件带 gated_by 字段记录来源，便于回放核对。

**触控会污染位置**：实测（capture lead_20261025-121454）接触瞬间质心向**左上**偏移 (-10071, +1433) counts，抬手后回落（20 帧后仍有 -4055）。按 2498 counts/半音计算，这是 **约 4 个半音**的假音高跳变。

因此光标层同时做三件事：**每帧位移上限 0.02**（任何来源的跳变都被摊成短滑行）、**触控帧冻结**、**接触前回滚**（回到 5 帧前的位置，经限速器滑回而不是瞬跳）。

实测（capture lead_20261025-131102，29 次触控）：单帧最大位移从 0.50 降到 **0.0200**，无任何帧超过 0.02；每次触控冻结位置与抬手稳定位置的差为 0.016–0.070（含手真实移动）。

原先的说明：AbsoluteCursor.push(touching=True) 期间不更新光标，抬手第一帧吸附到手的真实位置并置 
ebased（与抬手重接合同一机制），该帧在编译时被判为无效，不会形成转折。事件行增加 cursor_touch 字段。
