# Loop 控制层接口与验证

`rtl/loop_control_plane.sv` 将命令邮箱、CSR、模式管理、事件路由、
双缓冲存储和调度器连接起来。全部使用同一个默认 50 MHz 时钟。
当前是独立可综合模块，尚未实例化到板上顶层。

现有 RTL 接口仍有旧四轨/64 位事件的历史边界；Melodic Synthwave 设计规格已冻结为六轨，
轨道 ID、事件宽度、命令范围和存储容量将在六轨集成阶段一起升级，避免只改一个模块造成接口不一致。

## 边界与所有权

- UART 端口是字节级 `rx_valid/ready/data`、`tx_valid/ready/data`。
  `uart_rx` 已实现 8N1 接收，`uart_rx_fifo`（默认 16 字节）隔离物理时序和解析器，
  满载时向接收器施加背压并粘滞记录 overflow/framing_error。B3 是本板 USB-UART RX。
  TX 字节流的物理串行化和完整 mailbox 顶层接线仍待后续集成。
- 输入、输出为六轨演奏事件 valid/ready。输入适配器负责确认音符、持续时间、
  重复合并和 Touch/Presence；控制层只标记所选轨道、当前 tick 和追加槽位。
- 模式管理器独占模式、轨道、BPM、录音生命周期；CSR 不直接写 RAM。
- 路由器分别完成实时监听和录音握手，任何一路阻塞都不能导致另一条重复交付。
  输出仲裁为关音优先、实时输入其次、调度器最后。flush 显式取消待发事件。
- 调度器的 `boundary_ready` 等待录音最后一个写入排空、COMMIT_REQUEST 就绪。
  取得许可后发布 LOOP_BOUNDARY，背压时不撤回 valid；接收后才允许 bank 交换。
  等待超过下一音乐格仍触发调度故障，不能无限挂起。

## UART 二进制协议

命令固定 10 字节，参数均为小端：

```text
55 AA opcode 04 arg0_lo arg0_hi arg1_lo arg1_hi sequence checksum
```

checksum 为 opcode 到 sequence（含长度 04）的逐字节 XOR。
应答固定 10 字节：

```text
AA 55 opcode status data0 data1 data2 data3 sequence checksum
```

应答 checksum 为 opcode 到 sequence 的 XOR，data 为 32 位小端。
sequence 原样返回用于关联，不提供去重或自动重试保证。

| opcode | 命令 | 参数 |
| --- | --- | --- |
| 0 | STATUS | 保留；主机发送 0 |
| 1 | SET_MODE | arg0=0 IDLE 或 1 LIVE；arg1=0 |
| 2 | SET_BPM | arg0=90–120；arg1=0 |
| 3 | SELECT_TRACK | arg0=0–5；arg1=0 |
| 4 / 5 | PLAY / STOP | 两参数均为 0 |
| 6 / 7 | RECORD / OVERDUB | 两参数均为 0 |
| 8 / 9 | CLEAR_TRACK / CLEAR_ALL | 两参数均为 0 |
| 10 | COMMIT | 两参数均为 0；只观察正在自动提交的操作，不提前结束录音 |
| 11 | RESET | 两参数均为 0；停止并清除诊断，保留 active Loop |
| 12 | READ_CSR | arg0 低 8 位为地址，其余参数位为 0 |
| 13 | SET_THRESHOLDS | arg0=进入阈值，arg1=退出阈值；要求 arg0<arg1 |

status：0 ACCEPTED、1 APPLIED、2 REJECTED、3 BUSY、4 ERROR。
ACCEPTED 只表示进入邮箱，最终还会返回 APPLIED 或失败状态。
已拒绝的帧不先返回 ACCEPTED。长度/校验错误返回 ERROR；不完整帧超时丢弃。
邮箱只保留一个正在执行的 CSR 请求、一个解析完的帧、四个完整应答。
普通命令在前一命令未结束时返回 BUSY。

校验正确且参数为 0 的 STOP/RESET，在完整帧接收后立即触发 urgent_stop，
不等待前一命令 ACK 发完：取消旧操作、flush、停止调度、abort shadow、关音。
非法参数的 STOP/RESET 没有上述副作用。旧操作取消后返回 ERROR，优先命令随后执行。
若主机持续阻塞 TX，回复队列和待处理帧最终会填满，RX 将反压；
不能保证尚未被接收的 STOP 字节穿过满队列。物理接收溢出必须由后续顶层处理。

## CSR

一次写请求原子携带 `{arg1,arg0}`，不使用可被另一命令覆盖的分离参数寄存器。
读请求返回快照，写请求通过模式管理器验证；只读或未定义地址写入被拒绝。

| 地址（十六进制） | 含义 | 读回布局 |
| --- | --- | --- |
| 00 | STATUS，只读 | mode[3:0] |
| 04 | MODE | mode[3:0] |
| 08 | BPM | 高16位 active BPM、低16位 shadow BPM |
| 0C | TRACK | track[1:0] |
| 10 / 14 / 18 / 1C | PLAY / STOP / RECORD / OVERDUB，只写 | — |
| 20 / 24 / 28 / 2C | CLEAR_TRACK / CLEAR_ALL / COMMIT / RESET，只写 | — |
| 30 | THRESHOLDS | 高16位退出、低16位进入 |
| 34 | POSITION，只读 | tick[6:0]，bit8 active_valid，bit9 commit_pending，bit10 fault |
| 38 | FAULT，只读 | bit0 sticky fault |

## 状态与恢复

模式值：0 IDLE、1 LIVE、2 RECORD_ARMED、3 RECORDING、4 COMMIT_PENDING、
5 PLAY、6 OVERDUB_ARMED、7 OVERDUB；8 ERROR 保留，本实现故障关音后返回 IDLE 并锁存 fault。

RECORD 从 IDLE/LIVE 准备 shadow，覆盖所选轨道并保留其他轨道，等待 record_start。
从 tick0 起录制完整128格；最后写入排空后自动提交并进入 PLAY。
空录音 abort 回 IDLE；OVERDUB 从 PLAY 复制旧 Loop，下一边界开始录制一轮，
在下一边界提交。录音轨道16槽满时故障退出并保留 active bank，不静默截断。

STOP 保留 active；PLAY 只允许 IDLE 且 active_valid，从 tick0 开始。
CLEAR 仅允许 IDLE，经 shadow 和内部边界原子提交。
SELECT_TRACK 仅允许 IDLE/LIVE/PLAY；阈值只允许 IDLE/LIVE。

BPM 在 IDLE/LIVE 修改下次启动配置，立即 APPLIED；PLAY 中等待实际边界生效后 APPLIED。
录音、叠录及其待命/提交状态均返回 BUSY，避免改变固定乐句的时间基准。
取消尚未生效的 BPM 请求会恢复旧 shadow；若调度器已锁存新 BPM，保留已生效值。
因此 ERROR 表示命令未完成确认，并非任何情况下都无副作用；主机应重新读 CSR。

普通控制操作默认1秒超时，边界等待单独允许34秒（60 BPM 完整乐句32秒）。
调度故障、录音溢出和控制超时触发 abort/flush/停止/关音，并锁存诊断。
RESET 清除诊断与调度器故障，不清空已提交音乐。

## 验证记录（2026-10-17）

`scripts/test_control_plane.ps1`：邮箱、CSR、模式管理、事件路由单元测试，
以及 RTL RAM / Gowin 官方 DPB 两套联合测试均 PASS。
联合测试包含首次录音、自动提交与回放、OVERDUB 保留旧事件并追加、
TX 阻塞时 STOP 取消 BPM、active 保留、CLEAR 和状态读取。
调度器与存储的6组既有回归也全部 PASS。

`scripts/synth_control_plane.tcl` 经 Gowin V1.9.12.04 综合成功：
1837 LUT + 127 ALU（Logic 1964/23040）、1053 FF、0 latch、4 BSRAM、1 MULTALU27X18。
唯一 RTL 警告为输入事件 track 位 in_data[4:3] 未使用：路由器按 selected_track 重写该字段。
这是包含 Loop 存储和调度器的独立控制层资源，不含合成器、传感器和物理 UART。
没有执行板级 P&R、烧录或硬件播放验证；现有位流不包含这些新增功能。

## 板级集成状态（2026-10-17）

`mgc3130_loop_control_path` 已连接 B3 RX、RX FIFO、命令邮箱、MGC3130 输入适配器和 Loop 音频路径。`mgc3130_uart_top` 增加 `LOOP_CONTROL_ENABLE` 参数：启用时，C3 输出 mailbox 二进制应答，I²S/音频 UART 使用 Loop mixer；关闭时保留旧 ASCII/音频路径。

板级诊断信号已暴露为 `rx_overflow`、`rx_framing_error` 和 `adapter_overflow`，控制故障继续由 `fault_latched` 提供。Presence 当前采用 XYZ 无效或输入超时释放；TouchInfo 保留为诊断字段，未将其解释为通用 presence 位。

验证脚本：`scripts/test_top_loop.ps1`、`scripts/test_uart_byte_serializer.ps1` 和 `scripts/test_board_integration.ps1`。Gowin 全工程 P&R 和实机烧录仍需在新顶层完成后执行。
