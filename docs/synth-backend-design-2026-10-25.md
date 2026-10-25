# 合成器后端接口设计（PC 验证 → FPGA 移植）2026-10-25

版本：2026-10-25  
目标：在 7 天内交付「PC 上位机串口控制参数 + 光标轨迹参考 + FPGA 实时合成音频」的系统。  
参考：[`mgc3130_uart-synth-plugin`](../../mgc3130_uart-synth-plugin) 的既有后端（`performance_event_pkg`、`control_protocol_pkg`、`i2s_pcm5102a_tx`、`mgc3130_voice_mixer`、`performance_event_ingress`）。  
关联：[Lead 实现基线](lead-implementation-status.md)、[变分分段模型](curve-to-melody-variational-2026-10-24.md)

## 1. 题目要求 → 我们的实现

| 题目要求 | 我们的做法 | 验证方式 |
| --- | --- | --- |
| ≥2 个独立可控演奏维度 | Y→音高、X→运弓、Z→力度/音色、Touch→门控（4 维） | PC 回放对照 + 板上听音 |
| 触控/光电/压力等自研交互 | MGC3130 电容传感（非接触手势 + 触控电极） | 已有 73 段采集与实机验证 |
| 选音、和弦、触发、拨弦识别 | 变分分段出音高 + Touch/Bow 门控 + 触发电极 | 回放对比 |
| FPGA 纯 HDL 实时合成 | 全部语音在 FPGA 内逐样本生成，无预录 PCM | RTL 审查 + 频谱测试 |
| 总延迟 ≤10 ms（扩展 ≤5 ms） | 事件→发声 ≤2 ms；UART 8 字节 1 Mbaud ≈ 80 µs | 示波器测触发到波形起点 |
| 复音 ≥4（扩展 ≥32） | 32 声部，4 轨（lead/bass/pad/arp）；不足时降到 16 声部仍满足 ≥4 | `voice_mixer` 计数 |
| 实时变调、ADSR、多声部混音 | per-voice 32-bit 相位累加 + ADSR + 定点混音 | sim + 板上 |
| 扩展：≥32 声部或 ≥32 加法分量 | 32 声部 × 2 振荡器 = 64 个独立振荡器；或单声部 32 分量模式 | 频谱峰数 |
| 扩展：≥3 维表情 + ≥2 音色 | 亮度（cutoff）、滑音（glide）、颤音（vibrato）、力度（velocity）；2 音色切换 | 参数扫描录音 |
| 扩展：混响/延迟/合唱 | 定点 delay line + 反馈 + 简单 chorus（LFO 调制延迟） | RTL 审查 |
| 扩展：可视化 | LED 电平柱 + 频谱条 + Lissajous（用现有 LED/HDMI 资源） | 板上观察 |
| 扩展：LED 曲谱指引、蓝牙 App | 降级：LED 显示当前音级与拍位；蓝牙不做 | 说明取舍 |

## 2. 系统结构

```text
PC（现有流程）                                   FPGA（既有后端 + 新增桥接）
─────────────────────────────────────────────    ────────────────────────────────
MGC3130 → 光标 → 变分分段 → EventTable            uart_control_link
            │                                        → loop_control_plane
            ├─ 轨迹绘制（参考显示）                   → performance_event_ingress
            └─ synth_backend.py  ──UART 1Mbaud──→   → performance_event_router
                 · 事件编码（64-bit）                 → performance_event_voice_bridge
                 · CSR 写（32-bit）                   → 32 × voice（DDS + ADSR）
                 · 调度器（按 tick 提前发送）          → mgc3130_voice_mixer（混音 + FX）
                 · 参考合成器（bit-exact）            → i2s_pcm5102a_tx → PCM5102A
```

**关键决策：PC 只发"演奏指令"，不发音频。** 音频 100% 由 FPGA 逐样本生成，满足"严禁预录 PCM 播放"的合规要求。PC 侧的参考合成器只用于**离线比对**，不参与最终输出。

## 3. 传输层

### 3.1 物理层

- UART 8N1，**1 Mbaud**（现有 `uart_rx` 参数化，改 `BAUD` 即可）；115200 作为降级。
- 单向 PC→FPGA 控制流 + FPGA→PC 状态回传（复用既有 `uart_tx`）。

### 3.2 事件帧（复用 `performance_event_pkg`）

64-bit 字，小端逐字节发送：

```text
[63:62] 保留   [61:58] flags   [57:50] timbre   [49:42] amplitude
[41:34] pitch  [33:26] velocity[25:19] note     [18:12] duration
[11:5]  tick   [4:3]   track   [2:0]   event type
```

PC 端编码器 `encode_event(event) -> bytes(8)`，与包内位域一一对应。

### 3.3 控制帧（复用 `control_protocol_pkg`）

32-bit CSR 写：`{8'hA5, cmd, arg_hi[15:0], arg_lo[15:0]}` → 4 字节；FPGA 返回 4 字节 ACK。

新增 CSR（在既有 0x00–0x44 之后追加）：

```text
0x48 CSR_TIMBRE      音色选择（0=lead saw, 1=lead square, 2=bass, 3=pad）
0x4c CSR_ADSR        {A[7:0],D[7:0],S[7:0],R[7:0]}
0x50 CSR_FX_MIX      {reverb[7:0], delay[7:0]}
0x54 CSR_GLIDE_MS    滑音时间
0x58 CSR_VIBRATO     {depth[7:0], rate[7:0]}
0x5c CSR_BEND        signed 16-bit，半音 ×256
```

### 3.4 时序与延迟

```text
事件在 tick 边界前 2 个 16 分音符提前发送（lookahead = 300 ms @100 BPM）
FPGA 侧按 tick 计数器对齐触发
端到端：PC 决定 → 字节到达（≤80 µs）→ 下一个样本周期（≤21 µs）→ 波形起点
```

满足扩展要求的 5 ms 确定性延迟（实际 <1 ms，余量用于 UART 排队）。

## 4. FPGA 侧微架构

### 4.1 声部（32 个）

```text
per voice:
  active, owner_track[1:0], note[6:0]
  phase[31:0], phase_inc[31:0]      // DDS：inc = f * 2^32 / fs
  env_state[1:0], env_level[15:0]   // 16-bit，48 kHz 步进
  velocity[7:0], timbre[1:0]
  pitch_bend[15:0], vibrato_phase[15:0]
```

- 每声部一个 32-bit 相位累加器（独立振荡器，符合计分规则）。
- 波形：sine 用 1024×16 BRAM；saw/square 由相位高位直接生成。
- 每声部一个 16×16 乘法（时分复用 4 个 DSP，100 MHz 下 32 声部 × 48 kHz = 1.5 M 次/秒，绰绰有余）。

### 4.2 混音与 FX

```text
sum = Σ (wave × env × velocity)      // 定点，饱和到 24-bit
→ 一阶 lowpass（cutoff 由 Z 控制）
→ delay (4096 样本) + feedback
→ reverb（3 个 comb + 2 个 allpass，简化版）
→ chorus（LFO 调制 8 样本延迟）
→ 限幅 → I2S
```

### 4.3 I2S

复用 `i2s_pcm5102a_tx.sv`（已存在，PCM5102A 引脚已在 `.cst` 中）。48 kHz、32-bit slot，BCLK = 3.072 MHz。

## 5. PC 侧要新增的三个模块

| 模块 | 职责 | 验证 |
| --- | --- | --- |
| `synth_backend.py` | 事件/CSR 编码、调度、串口发送 | 单元测试（字节级比对） |
| `synth_reference.py` | 定点镜像：同一 DDS/ADSR/FX 的 PC 实现 | 与 WAV 输出逐样本比对（容差 1 LSB） |
| `synth_probe.py` | 串口抓取 FPGA 回传状态，画延迟/声部占用 | 实测延迟 |

## 6. 7 天计划

| 天 | 目标 | 交付 |
| --- | --- | --- |
| D1（今天） | 接口冻结：本节文档 + `synth_backend.py` 编码器 + 单测 | 字节级协议测试通过 |
| D2 | PC 参考合成器（DDS+ADSR+混音），与现有 `render_loop` 对比 | 听感一致、逐样本容差 |
| D3 | FPGA 单声部打通：UART→事件→1 声部→I2S | 板上出声 |
| D4 | 32 声部 + 4 轨 + 混音 | 复音测试，频谱峰数正确 |
| D5 | FX（delay/reverb/chorus）+ 表情（bend/vibrato/glide） | 参数扫描录音 |
| D6 | 可视化（LED/频谱）+ 延迟测量 + 稳定性 | 演示脚本 |
| D7 | 联调、演示视频、答辩材料 | 完整系统 |

**降级方案（必做）**：若 D4 卡住，只做 **8 声部 lead**（仍满足 ≥4 复音），把扩展项的"32 声部"换成"单声部 32 加法分量"（更容易：一个声部 32 个相位累加器 + 共享 LUT）。

## 7. 风险

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| PCM5102A 模块未到货 | 无法出声 | 先用 PWM/ΔΣ 输出到耳机口做临时验证 |
| 1 Mbaud UART 在 50 MHz 下采样误差 | 丢字节 | 保留 115200 降级；或用 921600 |
| 32 声部资源不足（25K） | 降复音 | 降到 16 声部；或换 Mega 60K |
| FX 资源超预算 | 砍 FX | 只保留 delay + 简单 reverb |
| PC 与 FPGA 时钟漂移 | 长循环错位 | 以 FPGA 为主时钟，PC 按 tick 提前发送 |

## 8. 与现有 PC 流程的接缝

现有 `compile_loop()` 已经产出 `EventTable`（含 `track`、`tick`、`duration`、`note`、`velocity`、`pitch_mod`、`timbre_mod`、`color_layer`）。后端只需：

```python
for event in sorted(table["events"], key=lambda e: e["tick"]):
    if event["type"] == "note_on":
        send(encode_event(...))          # 64-bit
    elif event["type"] == "control_point":
        send(encode_csr(CSR_FX_MIX, ...))  # 32-bit
```

**不需要改动现有的曲线→事件链路**，这是本次设计最重要的性质：前端保持不变，后端可替换。

## 9. 全链路下板：PC 只做参数与显示

最终形态不是"PC 算事件、FPGA 发声"，而是**整条链路都在 FPGA 内**，PC 只负责参数控制与光标显示。

### 9.1 目标数据流

```text
FPGA 内：MGC3130 → 锁存 → 光标（alpha/冻结/限速）→ 出音（电平穿越 + 门控）
                 → 32 声部 → 混音/FX → I2S
          ↑ 参数（PC→FPGA）              ↓ 遥测（FPGA→PC）
PC：参数面板（密度/门控/音色/ADSR/FX）+ 光标与轨迹显示
```

### 9.2 反向遥测（新增，必须）

PC 要画光标，就必须收到 FPGA 内的光标状态。200 Hz、每帧 8 字节 = 1.6 kB/s：

```text
帧头 0x5A | x[15:0] | y[15:0] | z[15:0] | note[7:0] | flags[7:0] | 校验
```

`flags` 位：touch、engaged、note_on、voice_overflow。

### 9.3 参数下行（复用 CSR 帧，接在 0x44 之后）

```text
0x60 CSR_GATE        0=bow 1=touch
0x64 CSR_NOTE_RULE   {hysteresis[7:0], min_len[7:0]}
0x68 CSR_CURSOR      {alpha_low[7:0], alpha_high[7:0], max_step[7:0], settle[7:0]}
0x6c CSR_SCALE       音阶位图（12 bit）
0x70 CSR_Z_RANGE     {z_low[15:0], z_high[15:0]}
```

### 9.4 出音规则分两种模式

**变分分段（Potts DP）不能逐帧流式**：它要整段录制完成后求全局最优。所以拆成：

| 模式 | 规则 | 实时性 | 何时用 |
| --- | --- | --- | --- |
| LIVE | 电平穿越 + 滞回 + 最小间隔 | 逐帧实时 | 现场演奏（默认） |
| LOOP | 录完一圈后在 FPGA 内跑 Potts DP | 提交后毫秒级 | 循环乐句 |

DP 状态规模 `128 tick × 8 音级 × 4 段长 = 4096`，100 MHz 下约 41 µs，**FPGA 完全算得动**，只是"录完再算"。按 COMMIT 后精修当前圈，再循环播放——实时性与变分算法两者都保住。

### 9.5 移植顺序与砍单线

| 阶段 | 内容 | 必须？ |
| --- | --- | --- |
| 1 | 输入锁存 + 光标（alpha/冻结/限速）+ LIVE 出音 + 单声部 + I2S | **必须** |
| 2 | 32 声部 + 4 轨 + 混音 + ADSR | **必须**（≥4 复音是硬指标） |
| 3 | 触控门控 + 参数下行 + 遥测回传 + PC 显示 | **必须** |
| 4 | FX（delay/reverb/chorus）+ 表情（bend/vibrato/glide） | 扩展项 |
| 5 | LOOP 模式的 DP 精修 | 加分项 |
| 6 | 可视化（LED/频谱） | 扩展项 |

**砍单顺序**：6 → 5 → 4（先砍 chorus，再砍 reverb）。1–3 不可砍。
