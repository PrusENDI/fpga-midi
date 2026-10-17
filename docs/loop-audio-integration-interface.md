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
原因是板级端口只有 `uart_tx`，没有 UART RX，无法接收规划中的二进制模式命令；
直接替换会使 RECORD/PLAY/STOP 无法操作。下一步应增加物理 UART RX 和 RX FIFO，
再把 `input_event_adapter` 的 live/record/modulation 输出接入此边界，并将
`performance_event_voice_bridge` 的输出切换为唯一 mixer 输入。

验证：`tb_loop_audio_path` 已验证空 Loop PLAY 拒绝、LIVE 事件到达 mixer、
STOP 关闭全部声部。此测试使用低频参数，只证明握手和事件语义，不证明 48 kHz
时序、PCM5102A 输出或板上位流功能。
