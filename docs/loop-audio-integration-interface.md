# Loop 音频接线边界

`rtl/loop_audio_path.sv` 是控制层到现有 `mgc3130_voice_mixer` 的可仿真接线。
它包含：

```text
live_event / completed record_event
    -> input_event_mux
    -> loop_control_plane
    -> performance_event_voice_bridge
    -> mgc3130_voice_mixer
    -> sample_valid / mixed_sample
```

已完成录音事件带 `flags[61]`，只写入 Loop 存储，不再重复送入 mixer。
`performance_event_voice_bridge` 将 NOTE_ON、NOTE_OFF、ALL_NOTES_OFF 和
CONTROL_POINT 转为旧 mixer 的单周期脉冲；控制层的 valid/ready 握手在桥接处完成。

当前板级 `mgc3130_uart_top` 仍保留旧的 MGC3130→pattern_input→mixer 路径。
USB-UART RX 已由用户确认接到 FPGA `B3`，并已加入独立 `uart_rx` 8N1 接收器；
接收器和 16 字节 RX FIFO 已通过有效字节、连续帧、背压、溢出和帧错误仿真；
字节流尚未接入命令邮箱的完整顶层响应路径，直接替换仍不能宣称 RECORD/PLAY/STOP 已在板上可用。下一步应增加 RX FIFO，
再把 `input_event_adapter` 的 live/record/modulation 输出接入此边界，并将
`performance_event_voice_bridge` 的输出切换为唯一 mixer 输入。

验证：`tb_loop_audio_path` 已验证空 Loop PLAY 拒绝、LIVE 事件到达 mixer、
STOP 关闭全部声部。此测试使用低频参数，只证明握手和事件语义，不证明 48 kHz
时序、PCM5102A 输出或板上位流功能。
