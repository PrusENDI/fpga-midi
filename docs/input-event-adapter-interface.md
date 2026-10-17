# MGC3130 输入事件适配器

`rtl/input_event_adapter.sv` 是新 Loop 控制层使用的输入边界。它与旧的
`mgc3130_pattern_input.sv` 并行存在，直到 Task 6 完成声音适配器接线；旧模块
仍保留“到右侧结束录音”的历史行为，新模块使用硬件 Loop 时钟完成录音。

输入报告必须使用单周期 `report_valid`，并由 `xyz_valid/report_error` 描述有效性。
`presence_valid/present` 是独立的 Presence 解码输入；如果未提供（`presence_valid=0`），
TouchInfo 只作为诊断字段。MGC3130 SDK 的 TouchInfo 低五位是南、西、北、东、中心电极，
并没有“手存在”位，因此不能把 `touch_info==0` 当作释放。无效报告、明确的 Presence
释放或超时才会释放当前音符。`touch_valid/touch_info` 仍透传接口，便于后续使用 Tap/DoubleTap。

适配器输出三条独立 valid/ready 流：

- `live_event`：即时 NOTE_ON/OFF、向右跨区重触发和表达控制点；不写 Loop。
- `record_event`：音符结束时输出带原始 `loop_tick`、轨道和持续时间的 NOTE_ON；
  同一 tick 同音符重触发合并。起点为 0 且持续完整 128 格时 duration=0，交给边界关音。
- `modulation_event`：PLAY 的非破坏 CONTROL_POINT；X 为有符号移调偏移，Y 为音色偏移，
  Z 为音量偏移，中性值均为 128（X 为 0）。

RECORD/OVERDUB 的 Y 映射使用 MGC3130 校准活动面 `0x1000..0xF000` 的八个数值等宽
区域。LIVE 默认裁掉活动范围上下各约 5%（`LIVE_Y_MIN=0x1700`、`LIVE_Y_MAX=0xE900`），
使用独立的 9 点边界参数 `LIVE_Y_B1..LIVE_Y_B7`（默认 `0x2B40,0x4580,0x5FC0,0x7A00,
0x9440,0xAE80,0xC8C0`）。这些边界保留实测校准入口。LIVE 的 8 个区域映射到原来的全音
音阶间隔 `48,50,52,54,56,58,60,62`；Y 只预选音符，X 位移达到阈值并通过连续报告
确认后才触发换音；当前 X 触发距离为此前的一半。边界加入 `NOTE_HYSTERESIS` 死区；一次跨越多个区域会直接落到目标
区域，避免大幅移动逐区追赶。X 使用 `X_MIN..X_MAX` 的八个等宽时间区，并使用滤波后的
坐标、滞回和连续确认：
只向右跨越历史最高区触发当前音符重触发；向左只回看，回到左侧后重新 arm。默认
`COORD_FILTER_SHIFT=2`，每帧移动四分之一剩余距离；设置为 `0` 可关闭滤波用于标定。
`INPUT_X_MIN/MAX` 和 `INPUT_Y_MIN/MAX` 可在顶层覆盖，用于适配不同 MGC3130 固件的
有效坐标窗口；默认值保持当前工程的 `0x1000..0xF000`。
LIVE 还按运动主轴做 XY 解耦：相邻报告的 `dx/dy` 只有在超过
`XY_DECOUPLE_DEADBAND` 时才切换主轴；Y 主导移动只积分 Y，X 主导移动只积分 X，
因此传感器在竖直移动时附带的 X 漂移不会累积成换音位移。对角线和小幅抖动沿用上一主轴。
Z 使用按下/释放双阈值和连续报告确认：默认 `PRESS=0x9000`、`RELEASE=0xB000`，
因此常见的 `Z=0x8000` 可直接发声；`Z>=LIVE_Z_RELEASE_THRESHOLD` 发送 NOTE_OFF。
释放后再次按下同一 Y 区仍会产生新的 NOTE_ON。两个阈值可由顶层参数覆盖。X 重触发同音
时必须先回到 `start_enter` 左侧重新 arm，避免手停在远端时重复发音。
Z 经过反向映射：`0x0000` 约为 255，`0x8000` 为 128，`0xffff` 约为 32，保证传感器
靠近方向对应更大音量，同时保留最低可听电平。RECORD_ARMED 使用最近三个有效报告的
2/3 左区多数确认并通过 `record_start_ready` 握手。

输出队列是有限的：两个实时事件、一个已完成录音事件、一个调制事件。消费者背压时
保持 valid/data；新的不可缓存报告置 `overflow` 并排出 ALL_NOTES_OFF。控制器必须
在溢出后 abort 当前 take，`flush` 才清除粘滞状态。`idle` 包含未完成音符和全部尾事件，
因此模式管理器在提交前必须同时等待适配器和路由器排空。

输入适配器独立综合资源：512 LUT、72 ALU、224 FF、2 DSP、0 BSRAM。TouchInfo
不参与当前组合逻辑，综合警告表示该诊断端口暂未用于发音决策。
