# PC Capture & Loop 双 UI 合成器插件规范

版本：2026-10-25  
状态：已确认的第一阶段 UI 规范  
适用分支：`feat/synth-plugin-fpga-baseline`

## 1. 目标

在不修改现有 PC Capture & Loop 主流程的前提下，增加一个独立的 FPGA 合成器配置 UI。第一阶段先在 PC 上把下面的流程串起来：

```text
MGC3130 采集
  ↓
Capture & Loop UI（现有）
  ↓ Compile Loop / Export Event JSON
EventTable JSON
  ↓
Synthesizer Config UI（新增）
  ↓ 事件校验、配置选择、离线渲染
mix.wav + stems + diagnostics + synth-config.json
```

两个 UI 通过文件契约通信，不通过 Python import、共享内存或隐式全局状态通信。这样可以在电脑上验证事件、配置和音频结果，同时保持未来 FPGA adapter 的边界稳定。

## 2. 两个 UI 的职责

### 2.1 Capture & Loop UI

现有 `pc_receiver/synthwave_ui.py` 继续负责：

- MGC3130 接收、校准、去耦合、滤波和光标预览；
- Lead、Bass、Pad、Arp、Drums、Texture 六轨采集；
- 固定 PitchSpace 和 Loop 时间轴；
- 根据采集结果生成 EventTable；
- 导出主流程事件 JSON。

插件阶段不修改该 UI。现有“Export Event JSON…”产生的 JSON 是第二个 UI 的输入候选；若旧文件缺少插件接口字段，插件使用版本化 adapter 补齐默认表达参数。

### 2.2 Synthesizer Config UI

新增 UI 只处理已经确定的音乐事件和合成器配置：

- 导入并校验 EventTable；
- 显示事件摘要、轨道数量、Loop 长度和声部峰值；
- 配置 GW5A-25A baseline 模式；
- 为六条轨道选择 patch 和表达映射；
- 保存、加载和导出 `synth-config/v1`；
- 调用独立离线 renderer 输出 mix、stems 和诊断；
- 显示 renderer 使用的 patch hash、事件拒绝数、声部耗尽数和 clipping 计数。

它不得读取 XYZ、landmarks 或原始 JSONL，不得重新量化音符、改变 tick、补写 NOTE_ON 或根据 Z 生成音高。

## 3. UI 形态

第一阶段使用 Tkinter，与现有 PC 工具保持一致。启动命令：

```powershell
cd C:\weizijian\documents\gowin fpga\mgc3130_uart-synth-plugin
python -m synth_plugin.ui
```

窗口默认 1280×820，最小 1060×680，分为三栏：

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ FPGA SYNTH PLUGIN · EventTable → fixed-point reference renderer          │
├─────────────────────┬──────────────────────────┬────────────────────────┤
│ 输入与输出           │ 事件时间线/声部监视       │ FPGA 模式与 patch 配置   │
│                     │                          │                        │
│ Open Event JSON     │ 128 tick Loop 网格        │ Board: GW5A-25A         │
│ Load Config         │ 六轨事件颜色             │ Clock: 50 MHz           │
│ Save Config         │ active voice count       │ Audio: 48 kHz           │
│ Render Mix           │ note / duration / vel    │ Voices: 4               │
│ Render Stems         │ validation messages       │                         │
│ Export Diagnostics   │                          │ [Lead]                  │
│                     │                          │ waveform / ADSR / gain  │
│ input summary       │                          │ z → timbre / space      │
│ output summary      │                          │                         │
│                     │                          │ [Bass] [Pad] …          │
└─────────────────────┴──────────────────────────┴────────────────────────┘
```

### 3.1 输入与输出栏

控件及语义：

| 控件 | 行为 |
| --- | --- |
| `Open Event JSON…` | 选择 EventTable JSON，运行 adapter 和 schema 校验 |
| `Load Config…` | 加载 `synth-config/v1`，保留未识别字段到 metadata |
| `Save Config…` | 保存当前配置，写入 schema、board、patch hash |
| `Render Mix` | 渲染单声道或立体声 mix WAV |
| `Render Stems` | 渲染六条独立 WAV，文件名按 track 固定生成 |
| `Export Diagnostics…` | 写出诊断 JSON 和逐样本摘要 |

导入后显示：事件总数、每轨事件数、Loop ticks、BPM、有效/拒绝事件数、最大同时声部数。

### 3.2 中央时间线与声部监视

中央区域使用 128 tick 网格；如果输入 Loop 长度不同，按输入的 `loop_ticks` 创建等比例网格，不强制改成 128。

- 横轴：tick；每 4 tick 标记一拍，每 16 tick 标记一小节；
- 纵向：六轨固定顺序；
- `note_on`：实心矩形，宽度为 duration；颜色按 track 固定；
- `control_point`：竖线或菱形，不占用声部；
- `note_revoice`：带箭头的连续事件，不重新计数声部；
- 鼠标悬停：显示 event_id、tick、note、velocity、z_norm 和 source metadata；
- 下方状态条：当前选中事件、最大同时声部数、voice exhausted、clipping。

时间线只读。用户不能在此拖动事件修改主流程结果；修改事件必须回到 Capture & Loop UI 重新导出。

### 3.3 FPGA 模式与 patch 配置栏

顶部显示不可编辑的硬件基线：

```text
Board       GW5A-25A
System clk  50 MHz
Audio       48 kHz
Voice slots 4
Sample      signed Q1.15
Phase       unsigned Q0.32
```

第一阶段允许配置的全局字段：

| 字段 | 范围 | 默认值 |
| --- | --- | --- |
| `voice_slots` | 4 | 4 |
| `sample_rate` | 固定 48000 | 48000 |
| `master_gain` | 0.0–1.0 | 0.82 |
| `limiter_enabled` | true/false | true |
| `effect_mode` | `dry`、`delay`、`space` | `space` |
| `seed` | 非负整数 | 0 |

每条轨道有一个可折叠 patch 面板。公共字段为：

```text
enabled
waveform        triangle | saw | square | sine | noise
gain            0.0..1.0
pan             -1.0..1.0
attack_ms       1..2000
decay_ms        1..4000
sustain         0.0..1.0
release_ms      1..4000
timbre          0..255
z_to_timbre     -1.0..1.0
z_to_gain       -1.0..1.0
proximity_gain  -1.0..1.0
reverb_send     0.0..1.0
delay_send      0.0..1.0
```

轨道默认 patch：

- Lead：triangle，短 glide，Z 主要控制 timbre 和空间发送；
- Bass：square，短 release，Z 不改变音高；
- Pad：sine，慢 attack/release，允许有限 chord 声部展开；
- Arp：saw，短 gate；
- Drums：noise/脉冲包络，note 只作为鼓 ID；
- Texture：noise 或 sine drone，Z 只控制亮度、增益和效果发送。

UI 中的 Z 控件明确标注“expression only”，并在配置摘要中显示：`Z cannot create or retune notes`。

## 4. 文件契约

### 4.1 EventTable 输入

插件接受现有 Loop 导出的对象，并转换为 `synth-plugin-event/v1`。转换规则：

- 读取 `config.bpm`、`config.ticks_per_bar`、`config.loop_bars`；
- 读取 `events[*].type/track/tick/duration/note/velocity`；
- 复制 `color_layer/z_norm/proximity/cursor_gain/pitch_bend/amp_mod/timbre_mod`；
- 未识别字段保留在 `metadata`；
- 缺少必需字段或音高越界时拒绝并显示行号/event_id；
- 不改变事件排序，稳定键为 `(tick, order, event_id)`。

### 4.2 合成器配置

配置文件使用独立 schema：

```json
{
  "schema": "synth-config/v1",
  "board": "GW5A-25A",
  "system_clock_hz": 50000000,
  "sample_rate": 48000,
  "voice_slots": 4,
  "master_gain": 0.82,
  "limiter_enabled": true,
  "effect_mode": "space",
  "seed": 0,
  "patches": {
    "lead": {},
    "bass": {},
    "pad": {},
    "arp": {},
    "drums": {},
    "texture": {}
  }
}
```

保存时对浮点值执行范围校验；renderer 使用与 FPGA 相同的定点量化规则。配置 hash 写入 diagnostics，确保重复渲染可追溯。

### 4.3 输出文件

一次渲染产生：

```text
mix.wav
stems/
  lead.wav
  bass.wav
  pad.wav
  arp.wav
  drums.wav
  texture.wav
diagnostics.json
render-manifest.json
```

`render-manifest.json` 记录输入 hash、配置 hash、renderer 版本、sample rate、事件数和输出文件 hash。

## 5. 状态机和错误处理

```text
EMPTY
  → EVENT_LOADED
  → CONFIGURED
  → RENDERED
```

任何状态都可以回到 `EVENT_LOADED` 重新导入事件。配置错误不启动渲染，事件拒绝不静默丢弃：

- 有拒绝事件：状态显示 `INVALID EVENTS`，允许导出诊断但禁用 Render；
- 声部耗尽：渲染继续，但状态显示 `VOICE EXHAUSTED`，诊断记录每次发生的 tick/event_id；
- clipping：渲染继续，使用确定性饱和并记录样本数量；
- 文件写入失败：保留内存状态，显示具体目标路径和异常。

## 6. 验收标准

第一阶段完成必须满足：

1. 用现有 Capture & Loop UI 导出的 EventTable 可以被新 UI 打开；
2. 同一 EventTable 和配置重复渲染得到相同 render hash；
3. 可以独奏/静音六条轨道并输出 stems；
4. 四个同时 note_on 事件不会互相关闭；
5. Z 参数只改变表达参数，不改变 note、tick 或事件数量；
6. 配置 UI 显示 GW5A-25A、50 MHz、48 kHz 和 4 voice baseline；
7. 不修改 `tools/synthwave_loop.py`、`pc_receiver/synthwave_ui.py` 或其测试；
8. UI、adapter、renderer 都有离线单元测试；
9. 每个大阶段同步提交文档、测试和验证结果。

## 7. 后续阶段

本规范不包含：

- 把新 UI 嵌入现有 Capture & Loop UI；
- 实时 MIDI/UART 输入；
- FPGA 下载、寄存器写入或 bitstream 管理；
- 修改现有 Loop 算法；
- 32 声部或片上效果器的最终综合实现。

这些功能分别通过新 adapter 或后续规范增加，保持本阶段文件契约兼容。


