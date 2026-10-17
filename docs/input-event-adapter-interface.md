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

LIVE/RECORD 的 Y 映射为 C 大调八个区域 `C4..C5`，稳定确认后换音。X 使用八区、
滞回和连续确认：只向右跨越历史最高区触发当前音符重触发；向左只回看，回到左侧后
重新 arm。Z 只更新表达，不产生音符。RECORD_ARMED 使用最近三个有效报告的 2/3
左区多数确认并通过 `record_start_ready` 握手。

输出队列是有限的：两个实时事件、一个已完成录音事件、一个调制事件。消费者背压时
保持 valid/data；新的不可缓存报告置 `overflow` 并排出 ALL_NOTES_OFF。控制器必须
在溢出后 abort 当前 take，`flush` 才清除粘滞状态。`idle` 包含未完成音符和全部尾事件，
因此模式管理器在提交前必须同时等待适配器和路由器排空。

输入适配器独立综合资源：512 LUT、72 ALU、224 FF、2 DSP、0 BSRAM。TouchInfo
不参与当前组合逻辑，综合警告表示该诊断端口暂未用于发音决策。
