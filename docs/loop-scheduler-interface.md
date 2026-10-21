# Loop 调度器接口

实现：`rtl/loop_scheduler.sv`。单一 `clk`，默认 50 MHz；`rst_n` 复位。
它读取 `loop_event_store` 的 active bank，输出统一事件，不直接驱动合成器，
也不修改任何 Loop RAM。当前未实例化进板上演奏顶层。

本文原有 RTL 骨架按旧四轨事件宽度实现；Melodic Synthwave 规格已冻结为六轨，
因此轨道 ID、事件宽度和 96 槽扫描将在六轨集成任务中统一升级。本文的边界、背压和完整 128 tick 语义继续有效。

## 时间与扫描

`run` 上升沿请求从 tick 0 开始；启动不先等待一个空白音符间隔。
`loop_tick` 始终表示当前音乐格，扫描完成后保持，下一次节拍截止时间才递增。
128 个完整 16 分音符间隔之后进入下一轮，避免最后一格被提前截断。
`sixteenth_ce` 在启动和每个截止时间输出一拍，作为音乐时间标记。

每格有固定的三轮扫描，每轮 96 槽：NOTE_OFF → NOTE_ON → CONTROL_POINT。
同类按槽索引升序，跨轨亦遵循类型优先级。
RAM 请求 `read_enable/read_index`，响应 `read_valid/read_slot_valid/read_data`。
对空槽和 RAM 中不属于演奏类的事件类型不产生输出。

`event_valid/event_ready` 握手时才完成事件交付；背压期间保持事件和扫描位置。
`stall` 表示当前输出在等待 ready，不代表音乐时钟暂停。
若新一格到达而上一格仍未完成，报告超时并停止，不跳格、不补发成串过期音符。
默认 50 MHz、120 BPM 时每格约 625 万个时钟，正常扫描只需数百个时钟。

### 音符持续时间

NOTE_ON 的 duration>0 时，除发出原始事件，还在 `start_tick+duration<128`
的结束格派生 NOTE_OFF，保留 track/note 等字段，更新 type/tick，清零 duration。
duration=0 等待显式 NOTE_OFF 或 Loop 边界。
结束点恰好为 128 或越过边界时，由边界 ALL_NOTES_OFF 关音，不在下一轮产生旧音符的 Note-Off。
后级声部管理器应以调度器发出的关音事件为准，避免重复实现时长计时。

### Loop 边界

1. tick 127 持续完整一格，音乐位置回到 0。
2. 输出 ALL_NOTES_OFF，等待接收。
3. 等待 `boundary_ready` 许可（录音排空和提交准备完成），再输出 LOOP_BOUNDARY 事件，等待接收。
4. 输出一拍 `loop_boundary` 给存储层。
5. 保留一个存储切换保护周期，然后开始新 bank 的 tick 0 扫描。

两个边界事件也遵守背压；尚未接收边界标记时不得提交 bank。
若边界事件拖延到下一格截止时间则故障关音，保留尚未提交的 active bank。
模式控制器须在存储看到提交脉冲前完成 COMMIT_REQUEST 握手；存储同拍的新请求等待下一次边界。

## BPM

`bpm_value[15:0]` 允许 90–120，在启动与实际 128 格时间边界锁存；
其他时刻的修改不影响当前 Loop。`active_bpm` 返回锁存值。
非法 BPM 在锁存点引发故障，不在非法速度下播放或提交存储。

32 位相位累加器的 step 使用编译期常数和定点乘法计算，无运行时除法器：

```text
scale_q16 = floor(2^48 / (15 * CLK_HZ))
step = floor((BPM * scale_q16 + 32768) / 65536)
```

32 位 step 量化有小量速度误差，未声称外部 MIDI 时钟同步精度：

| 50 MHz 配置 | step | 实际 BPM | 速度误差 |
| --- | ---: | ---: | ---: |
| 60 BPM | 344 | 60.070306 | +0.11718% |
| 180 BPM | 1031 | 180.036295 | +0.02016% |

测试可降低 `CLK_HZ`，但需 ≥10000，确保最短格内有完整扫描预算。

## 停止、恢复和待启动

`stop`、`flush`、`reset_position` 或 `run` 下降沿取消当前扫描与待发普通事件，
清零位置并输出 ALL_NOTES_OFF，保持到下游接受。
取消是 valid/data 保持规则的显式例外：同拍禁止旧 NOTE_ON 握手，不能为了排空而继续发音。
恢复控制器还需清理下游 FIFO；仅本模块停止不能撤回已经交付的事件。

STOP 后即使 run 仍高也不会自动重播，需要新 PLAY 上升沿。
如果新 PLAY 在前次 ALL_NOTES_OFF 尚未排空时到来，保留一位待启动请求，
关音完成后启动；再次取消或 run 下降会撤销该请求。

`fault_valid/code/info` 锁存首次故障，只由 rst_n 清除；新的有效 PLAY 可恢复调度，
诊断信息仍保留。fault_valid 由顶层恢复控制器接管，不等于整个系统已恢复。

| code | 故障 | info |
| --- | --- | --- |
| 1 | 锁存点 BPM 非法 | BPM 数值 |
| 2 | 前次工作超过下一格截止时间 | 低 6 位槽索引、接着 7 位 tick |
| 3 | RAM 响应超时 | 槽索引 |
| 4 | 状态编码非法 | 状态值 |

`READ_TIMEOUT_CYCLES` 默认 16。故障路径取消当前工作并请求关音，直到收到新启动请求。
`heartbeat_toggle` 在时间推进、读响应和关音完成时翻转；静止 IDLE 不要求心跳。

## 验证

```powershell
.\scripts\test_loop_scheduler.ps1 -ModelSimBin 'C:\modeltech64_10.6d\win64'
& 'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe' scripts/synth_loop_scheduler.tcl
```

单元测试使用低频时钟参数验证节拍、完整 Loop、类型顺序、全部 96 槽、持续时间、背压、取消和故障。
联合测试连接真实 store，在 RTL RAM 与 Gowin 官方 DPB 模型下运行：验证旧 bank
最后一格、新 bank 首格、边界提交保护周期、持续时间关音及 STOP 保留 active。
仿真输出在 `impl/modelsim_loop_scheduler/`；独立综合位于 `impl/loop_scheduler_synth/`。
独立综合不等于最终顶层的布局布线、时序收敛或板上演奏验证。

2026-10-16 最终验证：三组 ModelSim 测试均 PASS，单元测试结束时间 11.933360 ms；
最终 testbench 含关音背压期间/接收同拍的新 PLAY，以及四种取消路径撤销待启动请求。
Gowin V1.9.12.04 独立综合退出码 0：Logic 356（284 LUT + 72 ALU）、
182 寄存器、1 个 MULTALU27X18 DSP、0 BSRAM、0 latch。
这是 scheduler 单模块资源，不是六轨系统的最终总资源。
