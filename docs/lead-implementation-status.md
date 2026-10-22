# Lead 实现状态基线（as-built）

版本：2026-10-22  
状态：实现事实基线。本文记录 Lead 链路**当前代码实际行为**，用于和设计文档对照。  
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
- Lead 录制时每帧先过流式 `LeadStartGate.push()`；只有被接受的行进入 `lead_preview_capture` 并绘制到画布。门未开时状态栏显示 `WAITING — Lead must start at the left edge and move right`。
- 停止后 `current_capture` **原样**存入 `lead_samples`，门控在编译阶段由批量实现重跑，两处语义必须保持一致。

### 4.2 预处理 `preprocess_samples`

不传 `host_profile` 时（GUI/CLI 主路径）：

1. `project_sample`：`q_app = (raw − offset) · R · S`，默认 `S = 1/65535`、`offset = 0`、`R = I`，所以 `q_app`、`b_abs`、`c_abs` 都是 0–1。`b_abs` 投影到 `pitch_axis`（默认 +Y），`c_abs` 投影到 `color_axis`（默认 +Z）。
2. 三轴滤波：5 点滑动中值，仅当 `|value − median| > max(0.035, 6·MAD)` 时用中值替换（只压孤立尖峰）；随后一阶 IIR，固定 `α = 0.35`（按帧数，不按时间）。
3. `a_rel = (t − t_start) / (t_end − t_start)`。
4. 批量 `_apply_lead_start_gate` 复核：未通过门控的帧保留在数据里但 `position_valid = False`。

传 `host_profile` 时另有一条链路：`filter_capture` → Z 条件 XY 去耦合 → 时间窗中值 / 时间常数低通 / slew → `b_abs` 用 profile 的 `b_min/b_max` 归一化。两条链路产出同一组字段，但**缩放来源不同**，同一份 raw 数据在两条链路上的音高结果不保证相同。

### 4.3 左沿起笔门控

Lead 是"从左向右"的开放路径。规则：

```text
left_edge_max      = 4096 / 65535 ≈ 0.06250   （原始 X ≤ 4096 视为左边缘）
min_rightward_delta = 256 / 65535 ≈ 0.00391   （离开边缘的最小右移）
```

状态机：`awaiting_left_edge → edge_candidate →（右移 ≥ 256）→ rightward_confirmation_pending →（下一帧 X 继续增大）→ accepted`。边缘区内的候选点不断被更新，最终只有**最后一个**边缘点被回溯确认为句首。未确认的帧全部 `prestart` 且无效。

门控判断使用**原始传感器 X**，不是 `q_app` 投影 X——目的是避免中值/低通把边缘接触抹进工作区。这隐含"原始 X 方向即应用左方向"的假设，若校准 `R` 含 X 镜像，语义会反转。

### 4.4 重采样 `resample_to_ticks`

- 目标 128 个 16 分 tick，按时间线性插值 `b_abs / c_abs / q_x / q_y / q_z`。
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
| 起笔门控 | 左沿 ≤ 0.0625，右移 ≥ 0.00391 | `LEAD_LEFT_EDGE_MAX` / `LEAD_MIN_RIGHTWARD_DELTA` |
| 渲染 | 22050 Hz，ADSR 35/180/520 | `render_loop` |

## 6. 事件与诊断字段

Lead `note_on` 事件：`tick, duration, note, velocity, source="trajectory", source_landmarks, raw_target_midi, target_scale_index, quantization_delta, register_id(=0), color_layer, out_of_range, b_abs, b_norm, confidence, pitch_profile_hash, correction_reason, articulation, gate_ratio, legato, tie, glide_ms, accent, release_tail, generated_reason`。

诊断：`status, coverage, lead_start_gate{left_edge_max, min_rightward_delta, accepted, accepted_count}, landmark_counts, no_source_count, capture_hash, pitch_profile_hash, calibration_profile_hash, mode, host_profile_hash, host_filter`。

`capture_hash` 按时间戳排序后计算，因此与输入行序无关；时间戳回绕时它反映的是排序后的集合，不是采集顺序。

## 7. 与设计文档的偏差

| 设计文档要求 | 当前实现 | 影响 | 处置 |
| --- | --- | --- | --- |
| HostCalibrationProfile 先去耦合再编译 | GUI/CLI 不传 profile，仅回放工具与测试使用 | 纯 Z 的横向漂移未被补偿 | 待定：是否让 GUI 默认加载 profile |
| 五类运动意图（DEPTH_ONLY/PITCH_INTENT/TREMOR/HOLD/INVALID） | 只有 move/hold/rest | 无法区分深度移动与音高意图，无 TREMOR 抑制 | 待实现 |
| `pitch_dead_zone` = 3×MAD 且 ≥0.10 音级 | 未实现，只有 0.10 半音滞回 | 慢速小幅漂移可能连续换音 | 待实现 |
| 每小节 ≤8 onset、全曲 ≤16 Lead 音符 | Lead 无上限，仅 4 tick 间隔 | 长句音符数远超设计 | 待实现（会改变音乐结果） |
| 强拍落和弦音、弱拍五声经过音 | 完全不查和弦 | 强拍可能落在非和弦音 | 待实现（会改变音乐结果） |
| 动机提取、八小节句法、Intent/Song、Baseline/Advanced | 未实现 | 仅单一 Direct 路径 | 后续阶段 |
| 跨 Loop `tie/carry` | `tie` 恒 false | 第 8→1 小节无显式承接 | 待实现 |
| LeadPatch 全链路（LP24、chorus、带限振荡器） | 简化加法合成，无滤波器 | 音色偏暗、偏单薄 | 待实现 |
| 量化滞回 0.15–0.25（Lead 文档）/ 0.30–0.40（系统设计） | 0.10 | 两份文档本身也不一致 | 需先统一文档值 |
| 门控按应用坐标左边缘 | 按原始传感器 X | 校准含 X 镜像时语义反转 | 待安装方向冻结后确认 |

## 8. 已知限制

- 跟踪中的缺陷与未决设计问题单独记录在 [Lead 开放问题记录（2026-10-22）](lead-open-issues-2026-10-22.md)，包括掉帧归因、传感器中心偏移、Z→XY 漂移与状态估计可行性。
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

当前测试覆盖：左沿门控（流式与批量）、时间戳回绕（有/无 host profile）、null 有效性、显式无效帧、固定音域与地标来源、确定性、渲染输出非空、host filter 诊断透传。

## 10. 变更记录

### 2026-10-22

- **修复**：`position_valid: null` 曾被当作无效，导致 live receiver 下整段 Lead 被丢弃。新增 `host_xyz_filter.valid_flag()` 作为唯一解析入口，替换 `synthwave_loop` 中 6 处裸 `bool()`。
- **修复**：序列号排序此前只覆盖非 host_profile 分支；`filter_capture`、`preprocess_samples` 的 host 分支、`load_jsonl_records` 都按时间戳排序，回绕时帧序错乱。三处统一改用 `capture_order()`。
- **新增**：本文档，作为 Lead 实现事实基线。
- 测试从 20 项增至 24 项。

### 2026-10-21 之前（已在库中）

- 左沿起笔门控（流式 `LeadStartGate` + 批量 `_apply_lead_start_gate`）与对应设计文档 §9。
