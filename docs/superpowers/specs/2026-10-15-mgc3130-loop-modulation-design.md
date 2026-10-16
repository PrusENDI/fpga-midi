# MGC3130 四轨 Loop 与三轴调制顶层规格

## 目标

在保留现有 MGC3130 手势输入逻辑的基础上，增加可恢复的四轨 Loop 音序器和三轴调制演奏模式。实时音频路径继续由硬件完成，控制、模式和 Loop 管理由后续软核或控制寄存器负责。

## 已确定的外部规格

- Loop 长度：8 小节
- 拍号：4/4
- BPM：60–180
- 时间量化：16 分音符
- 每拍 4 格，总计 128 个时间格
- 轨道数：4
- 每轨最多 16 个稀疏音符事件
- 整个 Loop 最多 64 个音符事件
- 同时发声上限：4 个音
- 模式切换：UART 命令
- MGC3130：只负责演奏输入，不负责切换系统模式

## 分层结构

```text
MGC3130 输入
    -> 输入解析与抗抖
    -> 演奏事件 FIFO
    -> 模式管理器
       -> LIVE 直接演奏
       -> RECORD 写入当前轨道
       -> LOOP_PLAY 读取四轨事件
       -> MODULATION 读取三轴调制
    -> 音符调度器
    -> DDS/混音器
    -> 音频 FIFO
    -> I²S/PCM5102A
```

UART 只负责模式、速度、轨道、Loop 控制和诊断，不直接参与 48 kHz 音频时序。

## 现有输入逻辑的保留范围

保留 `mgc3130_pattern_input` 的以下职责：

- 接收有效 XYZ 报告；
- X 左侧区域启动录音/演奏；
- X 右侧区域结束一次手势；
- Y 映射到离散音阶；
- Z 映射到力度；
- 音符确认、抗抖和音符变化检测；
- 产生 `note_on`、`note_off`、`expression_valid` 和 `cell_event`。

现有模块不直接写 Loop RAM，也不直接决定播放模式。

## 稀疏事件模型

128 个时间格只表示时间定位，不表示必须有 128 个音符。音符仅在实际触发时写入事件表。

每个事件至少包含：

```text
valid       事件有效
start_tick  0..127 的起始时间
length      持续时间，单位为 16 分音符格
note        MIDI 音符号
velocity    力度
```

每轨最多 16 个事件。事件表满时置位溢出标志，并拒绝新事件，不能覆盖正在播放的有效事件。

## 三轴调制模型

- X 轴：输入手势中的时间推进和事件定位；Loop 播放时间由统一节拍调度器产生。
- Y 轴：离散音符选择，并可生成连续音高调制，目标范围先定义为约 ±12 半音。
- Z 轴：力度/音量调制；预留映射到音色或滤波截止频率。

调制数据与音符事件分开处理。首版可按时间格保存稀疏控制点，并在播放时对相邻控制点插值；不能把每个 50 MHz 时钟样本当成独立音符。

## 模式

```text
IDLE          无演奏
LIVE          MGC3130 事件直接进入调度器
RECORD        将 MGC3130 事件写入选定轨道，同时可监听
LOOP_PLAY     播放已保存的四轨 Loop
OVERDUB       播放旧内容并把新事件叠加到选定轨道
ERROR         停止新事件，执行清理和恢复
```

模式只能由模式管理器切换。切换必须在事件边界或 Loop 边界生效；切换时统一执行 `all_notes_off`，避免残留音符。

## 音频数据面

以下部分保留为硬件实时逻辑：

- 48 kHz 采样节拍；
- DDS 音频合成；
- 四声部混音；
- 音频 FIFO；
- PCM5102A I²S 输出。

软核不得直接产生 48 kHz 每采样控制脉冲。软核只写配置、事件和模式寄存器。

## 错误恢复

每个模块需要提供独立的清理入口：

- 输入解析器：`clear_state`；
- 事件 FIFO：`flush`；
- Loop RAM：写入保护和溢出状态；
- 音符调度器：`all_notes_off`；
- 音频 FIFO：`flush`；
- I²C/UART：超时后重新初始化；
- 顶层：看门狗检测心跳，触发统一恢复。

错误状态必须可读，且恢复后继续输出固定格式诊断信息。

## 暂不纳入第一版

- 每轨超过 16 个事件；
- 复杂滤波器组和效果器；
- 直接保存每采样点的 XYZ 波形；
- MGC3130 手势切换系统模式；
- 软核直接控制音频采样时钟。

## 简化后的 FPGA 原生实现方向

第一版采用纯硬件、固定资源和事件表驱动的架构，暂不加入软核。原因是当前规格中的事件数量、轨道数量和调度频率都是有界的，适合 FPGA 的确定性时序和片上 B-SRAM。

```text
MGC3130 I²C
    -> 输入采样与滤波
    -> 手势事件生成器
    -> 4 轨事件 RAM
    -> 统一 Loop 调度器
    -> 4 声部音符管理器
    -> DDS + 混音 + I²S
```

### 固定时序

- 使用一个 50 MHz 主时钟域；
- 由统一节拍发生器产生 `sample_tick`、`sixteenth_tick` 和 `loop_tick`；
- MGC3130 报告到达时间不能直接充当 Loop 时钟；
- 音频采样、DDS、混音和 I²S 不依赖 UART 或传感器是否正常。

### 固定数据结构

每个事件使用固定宽度字段：

```text
tick       7 bit
duration   7 bit
note       7 bit
velocity   8 bit
pitch_mod  8 bit
timbre_mod 8 bit
valid      1 bit
```

每轨固定 16 个事件槽，表满时置位 `overflow`、拒绝新事件并保留旧内容。录音和播放使用双缓冲，只在 Loop 边界交换缓冲区。

### 固定模式

中央模式控制器只允许以下状态：

```text
IDLE / LIVE / RECORD / OVERDUB / PLAY / ERROR
```

模式、Loop 指针、活动声部和音频相位分别由对应模块独占。模块之间只通过事件 FIFO、请求和应答通信，不能直接修改其他模块的状态。

### 简单 UART 控制

UART 暂时只实现有限命令：

```text
START  STOP  RECORD  OVERDUB  CLEAR  PLAY
BPM=xxx  TRACK=0..3  STATUS  RESET
```

UART 不参与 48 kHz 音频时序，也不能阻塞音频或 Loop 调度。

### 硬件恢复

```text
I²C 超时       -> 只复位 I²C
事件 FIFO 溢出 -> 丢弃新事件并记录错误
音符异常       -> all_notes_off
Loop 指针异常  -> 回到 tick=0
UART 卡住      -> 只复位 UART
系统错误       -> ERROR，再回到 IDLE
```

### 软核决策

在四轨、每轨 16 个事件的规格下，Loop 调度不需要软核。后续只有在需要复杂编曲编辑、大量参数管理或文件系统时，才重新评估加入软核。即使将来加入软核，48 kHz 音频数据面仍保留在硬件中。

## 已确认的模块接口规格

### 时钟、握手和复位

所有控制模块共用 `clk_50m`。48 kHz 音频和 16 分音符节拍使用 clock-enable，不新增异步时钟域：

```text
clk_50m       50 MHz 主时钟
sample_ce     48 kHz 采样使能
sixteenth_ce  16 分音符使能
loop_tick     0..127 的 Loop 位置
```

模块间事件统一采用 `valid/ready`：发送方在 `valid=1` 时保持数据，直到 `ready=1` 完成传输。所有 FIFO 提供：

```text
flush / full / empty / overflow / underflow / level
```

复位分为：

```text
power_reset   清除全部状态
module_reset  只复位指定模块
flush         清除队列和活动音符，保留 Loop 内容和配置
```

优先级为 `power_reset > module_reset > flush > 正常事件`。

### 演奏事件总线

输入前端、模式管理器、Loop 调度器和音符管理器之间使用固定 64 bit 事件：

```text
63:62  保留，必须为 0
61:58  flags
57:50  timbre_mod
49:42  amp_mod
41:34  pitch_mod，有符号，单位为 1/16 半音
33:26  velocity
25:19  note，MIDI 音符号
18:12  duration，单位为 16 分音符格
11:5   tick，0..127
4:3    track_id，0..3
2:0    event_type
```

事件类型为：

```text
0 NOTE_ON
1 NOTE_OFF
2 CONTROL_POINT
3 LOOP_BOUNDARY
4 ALL_NOTES_OFF
5 ERROR
```

`duration=0` 表示保持到显式 `NOTE_OFF`。输入前端只能产生 `NOTE_ON`、`NOTE_OFF`、`CONTROL_POINT` 和 `ERROR`；`LOOP_BOUNDARY`、`ALL_NOTES_OFF` 由调度器或恢复控制器产生。

### Loop 存储接口

Loop 使用双缓冲：

```text
active_bank   当前播放，只读
shadow_bank   当前录音或编辑，只写
```

每个 bank 固定为 4 轨、每轨 16 个事件槽，共 128 个槽位。事件不要求排序，调度器每个 tick 固定扫描 64 个有效播放槽位。存储接口为：

```text
write_valid / write_ready
write_track[1:0] / write_slot[3:0] / write_data[63:0]
clear_track / clear_all
prepare_overdub
commit_request / commit_ack
active_bank / shadow_bank
record_count[track] / overflow[track]
```

播放 bank 不能被录音过程改写。`commit_request` 只设置待提交标志，实际交换只能在 Loop 边界执行。录音失败时丢弃 shadow bank，active bank 保持不变。

### 节拍与调度器

BPM 使用 32 bit 相位累加器生成 `sixteenth_ce`：

```text
sixteenth_hz = BPM × 4 / 60
```

播放过程中不使用除法器。每次 `sixteenth_ce`：

1. PLAY 从 tick 0 立即扫描；后续相位溢出才推进当前 `loop_tick`；
2. 按 NOTE_OFF、NOTE_ON、CONTROL_POINT 三轮扫描 4 轨、64 个播放事件槽，保证全局事件类型优先级；
3. 将匹配当前 tick 的事件送入调度 FIFO；
4. 扫描完成后保持当前 tick，等待下一次相位溢出，不能因扫描完成提前推进音乐时间；
5. tick 127 持续完整一格后回到 0，先发送 ALL_NOTES_OFF，再发送 LOOP_BOUNDARY 事件；边界事件被接受后才产生存储提交脉冲，并等待存储切换完成再扫描新 tick 0。

FIFO 无空间时保持扫描索引和事件数据，不能跳过事件。若背压持续到下一格截止时间，停止调度、锁存故障并请求 ALL_NOTES_OFF，不静默丢格或集中补发过期音符。
该时序细化保证一个 Loop 包含完整 128 格，而不是在扫描完最后一格事件后提前结束。
详细接口、取消语义和验证见 `docs/loop-scheduler-interface.md`。

事件优先级为：

```text
flush / all_notes_off > loop_boundary > NOTE_OFF > NOTE_ON > CONTROL_POINT
```

### 模式和 UART 命令

UART 使用固定二进制帧：

```text
55 AA opcode length arg0[15:0] arg1[15:0] sequence checksum
```

UART 只写单深度命令邮箱，不直接修改播放状态。命令包括：

```text
STATUS / SET_MODE / SET_BPM / SELECT_TRACK
PLAY / STOP / RECORD / OVERDUB / CLEAR_TRACK
CLEAR_ALL / COMMIT / RESET
```

模式枚举为：

```text
IDLE / LIVE / RECORD / OVERDUB / PLAY / ERROR
```

命令应答分为：

```text
ACK_ACCEPTED   已进入命令邮箱
ACK_APPLIED    已在安全边界生效
ACK_REJECTED   参数或当前模式不允许
ACK_BUSY       邮箱或存储器忙
ACK_ERROR      帧校验或内部错误
```

`STOP` 可立即禁止新 Note-On、发送 `ALL_NOTES_OFF` 并清空实时事件 FIFO；`PLAY`、`RECORD`、`OVERDUB` 和 bank 提交在 Loop 边界生效。

### 错误和恢复

每个长期运行模块提供：

```text
heartbeat_toggle
fault_valid / fault_code[7:0] / fault_info[31:0]
module_reset / flush
```

错误分级如下：

- 输入、UART 帧和局部 FIFO 错误只复位对应模块；
- 事件或 Loop 错误执行 `ALL_NOTES_OFF`、清空事件 FIFO、保留 active bank、丢弃 shadow bank；
- 音频错误关闭声部、清空音频 FIFO，但保持 I²S 时钟运行；
- 只有多个模块失去心跳、模式非法或连续恢复失败时才进入顶层 `ERROR`。

错误记录锁存 `error_valid`、`error_code`、`error_module`、`error_count`、`error_timestamp` 和 `error_info`，只能由 `RESET` 命令清除。

所有恢复路径必须最终满足：

```text
active_voice_count == 0
event_fifo_empty == 1
mode == IDLE 或 PLAY
active Loop bank 未被破坏
```

## 已确认的交互行为规格

### 三轴职责

系统把 MGC3130 解释为二维轨迹乐器，而不是键盘：

```text
X：乐句推进、方向和节奏动作
Y：基础音高，默认 C 大调 8 音区
Z：连续音量和音色表达
```

Y 进入新音区并经过稳定确认后才换音，X 不参与音高换区判定。Z 不产生 `NOTE_ON` 或 `NOTE_OFF`，只更新 `velocity`、`amp_mod` 和 `timbre_mod`。

### LIVE 模式

`LIVE` 由 UART 开启。收到有效报告后，Y 稳定在音区即可开始发音；手停留时保持当前音符；Touch/Presence 事件、报告失效或有效报告超时会释放音符。

X 被量化为 8 个带滞回的位置区：

```text
向右跨区：重触发当前 Y 音符，形成节奏脉冲
向左移动：只回看位置，不重触发
X 停止：保持当前音符
回到左侧：重新 arm，下一次向右跨区才推进新乐句
```

LIVE 不写 Loop RAM。

### 首轮 RECORD

UART `RECORD` 只进入 `RECORD_ARMED`，不立即写入 Loop。起点检测采用滞回和多数确认：

```text
START_ENTER = 可调左侧进入门限
START_EXIT  = 可调左侧释放门限，且 START_EXIT > START_ENTER
```

最近 3 个有效报告中至少 2 个满足 `X <= START_ENTER` 时：

1. 锁存 `record_start`；
2. 将 `loop_tick` 置为 0；
3. 清空选定轨道的 shadow 槽位；
4. 进入固定 128 tick 的 `RECORDING`。

触发后必须收到 `X >= START_EXIT` 才能再次 arm。录音过程中 X 不负责结束 Loop，结束条件只有硬件 BPM 时钟完成 128 个 tick。

### RECORD 事件量化

事件按发生时的硬件 `loop_tick` 写入，而不是按手势速度或 X 的绝对坐标写入。连续的 Y 音区保持合并为一个带 `duration` 的事件；Y 改变并确认后写入旧音符结束和新音符开始。X 向右跨区对当前音符产生一次重触发；Z 在当前事件和控制点中保存表达参数。

Loop 完成后，有效事件数大于零才提交并自动进入 `PLAY`；空录音丢弃 shadow bank 并返回 `IDLE`。

### PLAY 模式调制

`PLAY` 只播放 active Loop，同时接收 XYZ 作为非破坏实时调制，不写入 Loop RAM：

```text
X -> 全局音高/移调偏移
Y -> 音色或滤波偏移
Z -> 音量/表达偏移
```

最终参数由 Loop 保存曲线与实时调制叠加得到。退出 `PLAY` 或执行 `STOP` 时清除实时调制层。

### OVERDUB 模式

`OVERDUB` 播放旧 active Loop，同时监听并记录新手势。开始前复制 active bank 到 shadow bank；新事件只追加到选定轨道的空闲槽位。事件槽满时拒绝新事件、锁存溢出并保留旧 Loop。128 tick 完成后在 Loop 边界提交；没有新事件则丢弃 shadow bank。

### 模式转换基线

```text
IDLE -> LIVE / RECORD_ARMED / PLAY
LIVE -> IDLE / RECORD_ARMED
RECORD_ARMED -> RECORDING / IDLE
RECORDING -> COMMIT_PENDING / IDLE
COMMIT_PENDING -> PLAY
PLAY -> IDLE / OVERDUB_ARMED
OVERDUB_ARMED -> OVERDUB / IDLE
OVERDUB -> COMMIT_PENDING / IDLE
任意状态 -> ERROR（非法状态或连续恢复失败）
```

`STOP` 的行为固定为：禁止新 `NOTE_ON`、发送 `ALL_NOTES_OFF`、清空实时事件 FIFO；录音或叠加中的 shadow bank 被丢弃，active Loop 保留。`CLEAR_TRACK` 和 `CLEAR_ALL` 只允许在 `IDLE` 执行。

### 交互实现默认参数和边界

以下实现决策已经冻结：

- MGC3130 开启并解析 `touch_info`，作为 Presence/Touch 释放依据；XYZ 仍作为连续演奏输入；
- X 起点使用 `START_ENTER`/`START_EXIT` 滞回，最近 3 个有效报告至少 2 个进入左区才触发；具体门限保留为 CSR 可调参数；
- X 的 8 个 LIVE 区域使用滞回和连续报告确认；
- 同一 tick 的事件优先级为 `LOOP_BOUNDARY > NOTE_OFF > Y 换音 > X 重触发 > Z 调制`；
- BPM 修改在下一次 Loop 边界生效；
- `PLAY` 从 `tick=0` 开始；`STOP` 清零播放位置但保留 active Loop；
- 无有效 Loop 时，`PLAY` 返回 `ACK_REJECTED`；空录音丢弃 shadow bank 并返回 `IDLE`；
- 同一轨同一 tick 的相同音符合并，不同音符允许共存；超过四个同时声部时按固定轨道优先级抢占并计数；
- UART checksum、ACK 帧和 CSR 地址必须在控制接口实现任务中固定，不能由各模块自行解释。

### Touch 数据路径

输入链路扩展为：

```text
MGC3130 DataOutputConfigMask
    -> reader 动态字段解析
    -> touch_info[31:0] / touch_valid
    -> input latch
    -> LIVE 释放和 RECORD 输入状态
```

Touch/Presence 只负责“存在/释放”语义，不能直接产生音符；音符仍由稳定 Y 音区和 X 节奏动作生成。若 Touch 字段暂时无效，报告失联超时仍作为后备释放路径。
