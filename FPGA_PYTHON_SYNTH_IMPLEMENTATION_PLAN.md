# Python 合成器功能在 FPGA 上的实现规划

本文规划将 `mgc3130_uart_python/mgc3130_uart/tools/synth_reference.py` 的演奏逻辑逐步移植到当前 `mgc3130_uart` FPGA 工程。Python 用于验证映射、事件和听感；FPGA 使用固定点、有限状态机、固定数量声部和可综合存储器。

## 一、目标数据流

```text
mgc3130_reader
  -> report_valid/xyz_valid 锁存
  -> 坐标滤波与失联保护
  -> X/Y/Z 事件状态机
  -> Voice Manager
  -> 每声部 DDS、包络和增益
  -> Mixer、限幅
  -> 48 kHz UART PCM 或后续 I²S/PWM
```

必须保持的约束：

- 不修改 Gowin 官方 I²C MASTER、MCLR、TS、SDA、SCL 和管脚约束；
- 合成器直接使用 `mgc3130_reader` 并行 XYZ，不从 UART 回读；
- 只有 `report_valid && xyz_valid && !report_error` 才产生有效输入事件；
- `AUDIO_STREAM=1` 默认发送二进制 PCM；改为 `0` 后重新综合才发送 ASCII 调试。

## 二、分阶段实现

### 阶段 0：接口冻结和输入锁存

增加独立的输入锁存层：

```text
input_valid
latched_x[15:0]
latched_y[15:0]
latched_z[15:0]
latched_gesture[7:0]
```

锁存条件为：

```verilog
report_valid && xyz_valid && !report_error
```

UART 只读取诊断状态，不成为合成器生产数据路径。

### 阶段 1：移植 Python 事件前端

#### X 时间格

- 有效范围 `0x1000..0xF000`；
- 首版使用 8 个较宽时间格；
- 左边界连续 3 个有效报告开始录制；
- 右边界连续 3 个有效报告结束录制并提交；
- 右边界结束后清除活动声部。

#### 首个音符

采用 Python 当前策略：

- 左边界只进入录制，不立即发声；
- X 越过 `FIRST_NOTE_X_GATE = 0x2000` 后才允许首音符；
- Y 候选满足 `FIRST_NOTE_CONFIRM` 后产生 `note_on`；
- 首音符触发前失联或到达右边界，不产生无效音符。

#### Y 音高

首版使用 C 大调 8 个音符：

```text
C3 D3 E3 F3 G3 A3 B3 C4
48 50 52 53 55 57 59 60
```

Python 先把 Y 分成 13 个内部区间，再折叠到 8 个音阶音符。FPGA 可以先使用等宽 8 区，但必须用相同 CSV 回放比较事件差异。

#### Z 力度

Python 映射为：

```text
velocity = 64 + Z * 191 / 65535
```

FPGA 使用定点一阶 EMA：

```text
z_smooth_next = z_smooth + ((z_input - z_smooth) >>> 2)
```

不设置固定噪声门限，低力度有效触摸必须保持可听。

#### 超时

- 默认超时 100 ms；
- 50 MHz 下为 5,000,000 个时钟；
- 超时立即产生 `note_off`；
- 清空录制状态和候选计数；
- 允许下一次从左边界重新开始。

### 阶段 2：Voice Manager 和 4 声部基础引擎

首版固定 4 个独立声部，每个声部保存：

```text
active, owner/track_id, note[6:0], phase[31:0], phase_step[31:0],
velocity[7:0], envelope_level[15:0], envelope_state
```

事件接口建议为：

```text
event_valid, event_type, event_voice_id, event_note, event_velocity
```

Note Off 必须按 owner 释放对应声部，不能无条件关闭全部声部。和弦展开作为独立转换器，一个根音展开为 root、third、fifth 三个事件。

### 阶段 3：DDS、波形和 ADSR

#### DDS

使用 32 位相位累加器：

```text
phase_step = round(note_frequency * 2^32 / 48000)
```

相位只在 `sample_tick` 更新，不能在每个 50 MHz 系统时钟更新。所有 MIDI 音符的 phase step 使用常量表。

#### 波形

实现顺序：

1. 正弦 LUT，256 或 1024 点，片上 BSRAM；
2. 三角波，直接由相位高位计算；
3. 方波，使用相位最高位；
4. warm square，少量奇次谐波；
5. organ，基波、二次和三次谐波；
6. scan，多个波形之间的定点交叉淡化。

首版先保留正弦、三角和方波。

#### ADSR

每个声部使用：

```text
OFF -> ATTACK -> DECAY -> SUSTAIN -> RELEASE -> OFF
```

首版参数建议：attack 1 ms、decay 80 ms、sustain 0.72、release 40～280 ms。先用线性包络，资源和听感确认后再做指数近似。

### 阶段 4：混音和输出

每个 48 kHz sample tick：

1. 更新活动声部 phase；
2. 读取波形；
3. 乘 envelope 和 velocity；
4. 累加 4 个声部；
5. 右移缩放并饱和到有符号 16 位。

当前 UART PCM 使用：48 kHz、8 位、无符号、单声道，帧格式为 `A5 5A sequence length payload[32] checksum`。发送端以 32 个样本为一帧，在 921600 baud 8N1 下传输。UART PCM 只用于电脑验证，最终硬件输出优先 I²S 或 PWM。

## 三、Python 到 RTL 的映射

| Python 功能 | FPGA 模块 | 实现方式 | 状态 |
|---|---|---|---|
| `map_cell` | `mgc3130_pattern_input` | 定点整数映射 | 已有 |
| `map_note` | `mgc3130_pattern_input` | C 大调查表 | 已有 |
| `map_velocity` | `mgc3130_pattern_input` | 16 位乘法/移位 | 已有 |
| Z EMA | `mgc3130_pattern_input` | 定点一阶滤波 | 第一阶段已加入 |
| 左右边界 | `mgc3130_pattern_input` | FSM + 确认计数 | 已有 |
| 首音符门控 | `mgc3130_pattern_input` | `note_started` + X gate | 第一阶段已加入 |
| 报告超时 | `mgc3130_pattern_input` | 50 MHz 计数器 | 已有 |
| Note On/Off | `mgc3130_pattern_input` | 事件脉冲和候选计数 | 第一阶段已加入，Voice Manager 待重构 |
| 和弦展开 | `chord_event_expander` | root/third/fifth | 临时已有 |
| MIDI 频率 | `phase_step_lut` | 常量 ROM | 部分已有 |
| ADSR | `voice_envelope` | 每声部 FSM | 待加入 |
| sine/triangle/square | `waveform_bank` | LUT/相位组合 | 待加入 |
| organ/warm square | `waveform_bank` | 谐波叠加 | 第二阶段 |
| reverb/delay | `effect_delay` | BSRAM 循环缓冲 | 第二阶段 |
| chorus | `effect_chorus` | 调制延迟线 | 后续 |
| fixed BPM | `pattern_clock` | 节拍计数器 | 后续 |

## 四、资源和时序预算

首版目标为 4 声部、48 kHz。50 MHz 到 48 kHz 的采样分频约为 1041 个系统时钟，因此可以在一个采样周期内完成有限的顺序计算。

优先采用：

- 4 个相位累加器和包络寄存器；
- 共享或小型波形 ROM；
- 4 声部顺序混音；
- 片上 BSRAM 存放波表和延迟线；
- 常量乘法和移位，避免通用除法器。

高风险部分是复杂谐波乘法、大容量混响、8/16/32 声部扩展，以及组合逻辑过深。如果时序不满足，将混音改为采样子周期时分复用，保持 48 kHz 输出。

## 五、验证计划

### Python 参考模型

使用：

```text
tools/capture_fast_01.csv
tools/capture_fast_02.csv
```

输出事件 CSV、debug CSV 和 48 kHz WAV，检查首音符门控、Y 防抖、Z 平滑、右边界、超时和声部释放。

### RTL 仿真

使用 `sim/tb_mgc3130_pattern_input_replay.v` 加载 HEX 回放文件，检查：

- 输入报告脉冲不丢失；
- 首音符、换音和结束事件顺序；
- 超时 Note Off；
- velocity 与 Python 的误差；
- phase step 对应的频率；
- 混音无溢出。

建议将 RTL 事件和 Python 事件都输出为：

```text
time report_valid recording time_cell note velocity note_on note_off
```

再进行事件顺序和允许时间误差比较。

### 综合和实机

每完成一个阶段运行：

```powershell
& 'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe' `
  'C:\weizijian\documents\gowin fpga\mgc3130_uart\scripts\build.tcl'
```

检查综合首错、已知 EX2629/EX3827、setup/hold、Fmax、位流时间戳和板上 `E=00/P=1/V`。

音频验收依次为：非静音 UART WAV、频谱中有预期音符、最终 I²S/PWM 示波器确认。没有实机或频谱证据时，只能声称编译/仿真通过。

## 六、实施顺序和回滚点

1. 输入锁存和 `note_started` 首音符门控（已完成）；
2. 修正 phase step 与 sample tick 的 DDS 频率；
3. Z EMA 与 1 ms attack；
4. Voice Manager 按 owner 释放声部；
5. 正弦 LUT、三角波和方波；
6. ADSR；
7. 4 声部和弦/独立声部混音；
8. organ/warm square；
9. delay/reverb；
10. Pattern 节拍量化和多轨叠加。

## 2026-10-14 第一阶段实施记录

已在当前 `mgc3130_uart` FPGA 工程完成第一阶段：

- 新增 `rtl/mgc3130_input_latch.sv`，在 50 MHz 时钟域锁存有效 XYZ/gesture，并输出单周期 `input_valid`；
- 顶层 `mgc3130_uart_top.sv` 已改为由锁存后的输入驱动 `mgc3130_pattern_input`；
- `pattern_input` 已加入 `note_started` 和 `FIRST_NOTE_X_GATE=0x2000` 首音符门控；
- X 仍使用 8 个时间格，左右边界分别使用 3 帧确认；
- Y 使用 C 大调 8 个音符区，并保留候选音符确认；
- Z 加入定点 EMA 平滑，更新形式为 `z_smooth += (z_input-z_smooth) >>> 2`，力度仍使用 `64 + Z*191/65535`；
- 失联超时仍为 100 ms，超时产生 `note_off` 并允许重新开始；
- 音频 UART 默认参数已改为 921600 baud、48 kHz、8 位单声道 PCM；
- `tools/play_pcm_uart.py` 默认同步改为 921600 baud 和 48000 Hz WAV。
- 音频 UART 校验和按帧发送前已完成 32 个 payload 字节的异或，校验字节直接发送累积值。

本阶段尚未完成 DDS/ADSR/Voice Manager 的重构，也尚未完成 Gowin 综合和板上 921600 链路压力测试。重新下载前必须用 `scripts/build.tcl` 生成新的 bitstream，并确认板载 USB-UART 在 921600 下无丢帧。

每一步保留上一版可综合 RTL 作为回滚点。I²C reader、官方 IP、管脚约束和 UART 帧格式不随音频功能重构。

## 七、首版不直接移植的功能

以下 Python 功能暂不直接移植到首版 FPGA：

- 32 声部离线渲染；
- 浮点频率和包络计算；
- 动态 voice 字典；
- chorus 的可变延迟插值；
- 复杂 reverb 网络；
- 依赖电脑时间戳的自由模式时序；
- WAV 文件处理和离线轨道切分。

这些功能在 4 声部 FPGA 闭环稳定后，再依据资源、时序和听感逐步加入。

## 八、三模式演奏与 Loop 控制设计（讨论确定）

系统固定为三种顶层模式：

```text
MODE_KICK    点按触发底鼓，点按间隔形成节奏
MODE_MELODY  X 时间格、Y 音符、Z 力度，右边界提交旋律短句
MODE_LOOP    在循环时间轴上叠加 Phrase，并可记录调制曲线
```

`MODE_MELODY` 和 `MODE_LOOP` 都使用“检测抬起后，第一次经过左侧起始位置”作为新一轮录制触发。模式切换由中间区域长按触发；控制识别必须与普通 XYZ 音乐事件分层，不能在录制事务中途切换模式。

### Loop 子状态

```text
LOOP_PLAY
LOOP_ADD_ARMED
LOOP_RECORDING
LOOP_COMMIT
```

- `LOOP_PLAY`：已有 Phrase 按固定时间轴循环播放；经过左侧不会自动开始新录音。
- 中间区域长按后进入 `LOOP_ADD_ARMED`，已有 Loop 可继续播放，但等待新的录制起点。
- 抬起后第一次经过左侧进入 `LOOP_RECORDING`，沿用 X/Y/Z 和右边界提交规则。
- 右边界提交后将新 Phrase 叠加到 Loop，返回 `LOOP_PLAY`。
- `LOOP_ADD_ARMED` 中再次中间长按取消添加并退出 Loop；超长按也可直接退出。

Loop 录制的第一版先记录离散音符/力度事件，后续再将曲线映射到 cutoff、wavetable position、vibrato depth 或 effect send 等连续调制参数。

## 九、本地 MGC3130 SDK 手势能力核查（2026-10-14）

本机存在 Microchip GestIC SDK 1.2.0：

```text
C:\Program Files (x86)\Microchip\GestIC SDK 1.2.0
```

同时核对了本地 DFRobot 驱动和 MGC3130 数据手册。除连续 XYZ 和 GestureInfo 外，MGC3130 还支持独立的 Sensor Touch / Tap / Double Tap 字段：

- Touch：Down、Left、Up、Right、Center
- Single Tap：五个电极分别报告
- Double Tap：五个电极分别报告
- GestureInfo：四方向 Flick、顺/逆时针 Circle
- AirWheelInfo：顺/逆时针连续旋转信息
- Approach Detection：接近检测，用于唤醒，不适合作为精确的音乐控制命令

DataOutputConfigMask 字段如下：

```text
0x0002 GestureInfo
0x0004 TouchInfo
0x0008 AirWheelInfo
0x0010 XYZ position
```

当前工程主要使用 `F=0x0112`，即 GestureInfo + XYZ；当前 `mgc3130_reader` 没有把 TouchInfo 和 AirWheelInfo 输出到合成器。SDK 说明表明这些字段与 XYZ 是并列数据，可在同一报告中读取，因此比在 XYZ 曲线上自行识别长按更适合作为模式控制输入。

### 推荐的控制方案

优先使用 Sensor Touch 的 Center 电极事件作为控制通道：

- Center Long Touch：进入/退出模式选择或 Loop 编辑预备态
- Center Single Tap：播放/停止 Loop
- Center Double Tap：确认模式切换或添加 Phrase
- Left/Right/Up/Down Tap：可分配为清除、撤销、轨道选择等命令

在 `MODE_MELODY` 和 `MODE_LOOP` 的 XYZ 旋律/调制过程中，TouchInfo 仍作为独立事件读取；控制层只消费明确的 Touch/Tap/Double Tap 事件，不把普通 XYZ 位移解释为控制命令。Loop 的“第一次经过左侧”仍只在 `LOOP_ADD_ARMED` 子状态中生效。

AirWheel 可作为后续连续调制或参数扫描输入，但首版不建议同时用它做模式切换，因为它是连续数据流，容易与 Loop 调制语义混淆。Flick/Circle 可作为备用的显式模式命令，但它们依赖整段空间轨迹识别，优先级低于 Center Double Tap。

### 实现前提

1. 确认当前 MGC3130 配置启用了 Touch Detection，并在 DataOutputConfigMask 中加入 `0x0004`；如需要 AirWheel，再加入 `0x0008`。
2. 扩展 `mgc3130_reader` 输出 `touch_info[31:0]` 和 `airwheel_info[15:0]`，保持动态字段偏移解析。
3. 输入锁存层同时锁存 XYZ、gesture、touch、airwheel，并为每类事件产生独立 valid 脉冲。
4. 控制层只在明确的 Touch/Tap/Double Tap 事件上改变三种顶层模式；不修改当前 X/Y/Z 旋律映射。
5. 通过实机报告确认 Center Tap/Double Tap 的稳定性后，再冻结具体命令映射。
