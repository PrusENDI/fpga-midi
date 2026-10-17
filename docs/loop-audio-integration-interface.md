# Loop 音频接线边界

`rtl/loop_audio_path.sv` 是控制层到现有 `mgc3130_voice_mixer` 的可仿真接线。
它包含：

```text
live_event -> LIVE FIFO ─┐
completed record_event -> RECORD FIFO -> loop_control_plane
    -> performance_event_voice_bridge
    -> mgc3130_voice_mixer
    -> sample_valid / mixed_sample
```

已完成录音事件带 `flags[61]`，只写入 Loop 存储，不再重复送入 mixer。
`performance_event_voice_bridge` 将 NOTE_ON、NOTE_OFF、ALL_NOTES_OFF 和
CONTROL_POINT 转为旧 mixer 的单周期脉冲；控制层的 valid/ready 握手在桥接处完成。

板级 `mgc3130_uart_top` 通过 `LOOP_CONTROL_ENABLE` 在旧路径和 Loop 路径之间选择；
`mgc3130_uart_loop_top` 固定启用 Loop 路径。USB-UART RX 接到 FPGA `B3`，C3
输出二进制 ACK；16 字节 RX FIFO、命令邮箱、输入适配器和唯一 Loop mixer 输入均已接入。
Loop 模式会关闭旧 ASCII 状态流，避免两种协议混流。

该 RTL 接线已通过仿真和 ModelSim 编译。2026-10-17 已用 Gowin V1.9.12.04 完成
`mgc3130_uart_loop_top` 的综合、GAO 合并、Place & Route 和时序检查，生成
`bitstream/mgc3130_uart_loop.fs`；实机烧录和 RECORD/PLAY/STOP、PCM5102A 输出验证仍待执行。

Loop 位流上电后会在 MGC3130 启动等待结束时一次性发送 `LOOP UART READY\r\n`。
这段标记用于确认实际烧录文件、板载 USB-UART 通道和 C3 TX 物理链路；二进制
控制 ACK 会在标记发送完成后继续从同一条 115200 8N1 链路输出。上位机的 ACK
扫描器会忽略这段 ASCII 标记。

验证：`tb_loop_audio_path` 已验证空 Loop PLAY 拒绝、LIVE 事件到达 mixer、
STOP 关闭全部声部。此测试使用低频参数，只证明握手和事件语义，不证明 48 kHz
时序、PCM5102A 输出或板上位流功能。

## 现场诊断

读取 CSR `0x40`（命令行 `diag-audio`）返回：

```text
31:16 sample_count
15:8  note_on_count
7     flush_events
6     live_enable
5     live_ready
4     live_valid
3     adapter_overflow
2     router monitor_pending
1     router record_pending
0     router output_pending
```

命令行工具会同时打印这些字段。LIVE 空闲且无事件时低字节通常为 `0x60`；若输入
适配器发生过溢出，`adapter_overflow` 会置位为 `0x08`，直到执行 STOP/RESET
或重新上电。用户提供的旧日志 `0xFFFFFF00` 低字节为零，说明那份位流尚未
包含这组诊断位。

读取 CSR `0x44`（命令行 `diag-router`）返回独立队列占用：

```text
bits 3:0 LIVE FIFO level (0–15)
bits 7:4 RECORD FIFO level (0–15)
```

该寄存器用于确认录音写入阻塞是否正在填充 RECORD FIFO；LIVE FIFO
即使录音写端阻塞也可以独立接收事件。`diag-audio` 的 router 位仍显示
monitor、record、output pending 以及 flush/kill 状态。
