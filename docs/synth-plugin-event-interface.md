# Synthesizer Plugin Event Interface

版本：2026-10-25
状态：独立插件第一版接口；不修改 PC Capture & Loop 主流程，也不替代现有 FPGA `performance_event_pkg`。

## 1. 目的

此接口把现有 EventTable 或未来实时事件流转换为插件内部可验证的音乐事件。它是文件和逻辑边界，不要求主流程导入插件代码。

插件输入必须描述“已经决定的音乐事件”。插件不能根据 XYZ、landmarks 或曲线重新猜测音符；如果需要这些诊断信息，可作为只读 metadata 保存。

## 2. JSON 文件封装

```json
{
  "schema": "synth-plugin-event/v1",
  "sample_rate": 48000,
  "bpm": 100,
  "ticks_per_beat": 4,
  "loop_ticks": 128,
  "loop_bars": 8,
  "pitch_profile_hash": "...",
  "source_event_table_hash": "...",
  "events": []
}
```

字段规则：

| 字段 | 类型 | 规则 |
| --- | --- | --- |
| `schema` | string | 必须是 `synth-plugin-event/v1` |
| `sample_rate` | integer | 第一版必须为 48000 |
| `bpm` | number | 60–180；用于 tick 到样本的换算 |
| `ticks_per_beat` | integer | 第一版为 4 |
| `loop_ticks` | integer | 正整数；通常为 128 或配置后的 Loop 长度 |
| `loop_bars` | integer | 与 `loop_ticks` 和拍号一致时填写 |
| `events` | array | 按 `(sample_position, order, event_id)` 稳定排序 |

## 3. 事件字段

最小事件结构：

```json
{
  "event_id": 17,
  "order": 0,
  "type": "note_on",
  "track": "lead",
  "tick": 24,
  "duration": 8,
  "note": 64,
  "velocity": 96,
  "pitch_bend": 0,
  "timbre": 96,
  "amp": 100,
  "color_layer": 1,
  "z_norm": 0.22,
  "proximity": 0.78,
  "cursor_gain": 0.82,
  "flags": {}
}
```

通用字段：

| 字段 | 范围 | 含义 |
| --- | --- | --- |
| `event_id` | 非负整数 | 同一输入文件内唯一；仅用于诊断 |
| `order` | 非负整数 | 同一 tick/sample_position 内的显式处理顺序 |
| `type` | 枚举 | `note_on`、`note_off`、`note_revoice`、`control_point`、`all_notes_off` |
| `track` | 枚举 | `lead`、`bass`、`pad`、`arp`、`drums`、`texture` |
| `tick` | `0..loop_ticks-1` | 音乐位置；插件不重排事件 |
| `duration` | 非负整数 | `note_on` 的持续 tick；其他类型通常为 0 |
| `note` | MIDI `0..127` | `note_on`/`note_revoice` 的目标音高 |
| `velocity` | `0..127` | 起音或动态目标 |
| `pitch_bend` | 有符号 8 bit | 以固定配置解释的有限滑音量 |
| `timbre` | `0..255` | 波形/patch 亮度目标 |
| `amp` | `0..255` | 额外幅度目标 |
| `color_layer` | `0..2` | Lead 深度颜色层；其他轨道可省略 |
| `z_norm` | `0..1` | 深度归一化值，只调表达参数 |
| `proximity` | `0..1` | 接近程度，只调动态/力度 |
| `cursor_gain` | `0..1` | 光标跟随增益，只调连续表现 |
| `flags` | object | `accent`、`legato`、`tie`、`generated_reason` 等诊断标记 |

`note`、`tick`、`duration` 和事件类型是结构字段。`z_norm`、`proximity`、`cursor_gain`、`color_layer` 和 `control_point` 不能改变结构字段的音高来源。

## 4. 事件语义

### `note_on`

申请一个声部并开始包络。声部分配优先级为：同一 track 的空闲槽、已释放槽、最早进入 RELEASE 的槽，最后才按明确的 voice stealing 规则选择。第一版 4 声部中，无法分配时返回 `voice_exhausted` 诊断，不静默增加声部。

### `note_off`

释放由 `event_id`、track 和 note 共同确认的声部。不能关闭其他 track 的同音高声部。若事件由 `duration` 派生，派生事件必须保留 `parent_event_id`。

### `note_revoice`

保持声部相位和包络，只把目标频率改为新音高，并用固定 `pitch_slew` 滑移。它不增加声部数量，也不重新触发 attack。

### `control_point`

更新指定 track 或全局的表达目标，例如幅度、timbre、滤波亮度、delay/reverb send 或 vibrato depth。控制点使用固定 slew，不产生 `note_on`。

### `all_notes_off`

按规定的 release/flush 策略关闭全部声部。Loop 边界和 STOP 可以使用该事件。

## 5. Tick 到样本

第一版使用确定性整数换算：

```text
seconds_per_tick = 60 / (bpm * ticks_per_beat)
sample_position  = round(tick * sample_rate * seconds_per_tick)
```

渲染器内部使用有理数累加器，避免逐事件浮点误差。相同 `sample_rate`、BPM、tick 配置和事件顺序必须得到相同样本位置。

当 `loop_ticks` 超过默认 128 时，事件必须先由输入方限制到编译后的 Loop 长度；插件只执行边界校验和诊断，不把事件悄悄折返到默认长度。

## 6. 与现有 EventTable 的映射

插件 adapter 读取现有导出事件中的：

```text
type, track, tick, duration, note, velocity,
color_layer, z_norm, proximity, cursor_gain,
pitch_bend, amp_mod, timbre_mod, diagnostic_refs
```

无法识别的字段保留在 `metadata`，不影响渲染；缺失的表达字段使用 patch 的确定性默认值。缺少 `track`、`tick`、事件类型或 MIDI 音高越界时拒绝该事件，并在诊断中给出 `invalid_event`。

插件不直接导入 `tools.synthwave_loop`。如果主流程 EventTable 字段变化，增加版本化 adapter，并保留旧 schema 的读取能力。

## 7. 未来 FPGA 适配边界

未来 FPGA adapter 可以把相同事件映射到现有硬件事件字段：

```text
note_on       → EVENT_NOTE_ON
note_off      → EVENT_NOTE_OFF
control_point → EVENT_CONTROL_POINT
all_notes_off → EVENT_ALL_NOTES_OFF
note_revoice  → EVENT_NOTE_REVOICE
```

现有 `rtl/performance_event_pkg.sv` 的 64 位字段布局不是本插件第一版的内部 ABI。适配时必须明确截断、缩放和量化规则，尤其是 `pitch_bend`、`timbre`、`amp`、`z_norm` 和 `color_layer`，不能直接强制类型转换。

## 8. 确定性和验证

插件每次运行都输出：

```json
{
  "schema": "synth-plugin-diagnostics/v1",
  "event_count": 0,
  "accepted_count": 0,
  "rejected_count": 0,
  "voice_exhausted": 0,
  "clipping_samples": 0,
  "first_affected_sample": 0,
  "render_hash": "..."
}
```

验证要求：

- 相同事件文件和 patch hash 得到相同 `render_hash`；
- 事件顺序稳定，重复渲染逐采样一致；
- 4 个同时发声事件不会互相关闭；
- `note_revoice` 不增加 `active_voice_count`；
- STOP/Loop 边界后不残留未授权声部；
- 频谱测试能识别多组独立频率峰值；
- 固定点模型与未来 RTL 的差异按 LSB 范围验收。
