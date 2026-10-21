# MGC3130 FPGA Loop 项目开发记录

日期：2026-10-18
分支：`feat/loop-event-store`
基线提交：`632a9c7 Separate Loop event ingress paths`

## 记录范围

本记录汇总今天完成的校准采集、LIVE 输入链路重构、音频 mixer/DDS 修改、仿真验证和位流生成。工作过程中没有执行 `git reset` 或 `git clean`。

## 一、MGC3130 校准采集路径

新增了 FPGA 校准采集顶层和配套工具：

- `rtl/mgc3130_calibration_capture.sv`
- `rtl/mgc3130_uart_calibration_top.sv`
- `tools/capture_mgc3130_calibration.py`
- `tools/mgc3130_calibration_protocol.py`
- `scripts/build_calibration.tcl`
- `scripts/test_calibration_capture.ps1`
- `scripts/test_calibration_top.ps1`

采集路径直接保存 MGC3130 的有效 XYZ 报告，保留原始坐标、时间戳、有效标志和帧信息，避免把 FPGA 内部的音符映射结果混入校准数据。

今天整理的采集会话包括：

- `session_001` 至 `session_003`：无人静止、X/Y 端点和中心轨迹；
- `session_005_x_left_center`、`session_006_x_right_center`：X 左右端点到中心；
- `session_007_y_bottom_center`、`session_008_y_top_center`、`session_009_y_bottom_center`：Y 端点到中心；
- `session_0010_center_static`：中心静止；
- `session_0011_side`、`session_0012_side`：顺时针四边轨迹；
- `session_0013_z`：Z 轴从悬空到触摸的触发样本；
- `session_0014_boardside`、`session_0015_boardside`：物理板边缘采集；
- `session_0016_NEWCENTER`、`session_0017_NEWCENTER`：修改 Sensing Area 后的新中心数据。

结论记录在 `docs/mgc3130-calibration-summary-2026-10-18.md`。目前没有把这些数据强行压缩成一个最终坐标变换，因为边缘区域存在明显非线性、轨迹折返和腕部遮挡影响；校准资料保留用于后续分段拟合和板上验证。

## 二、LIVE XYZ 输入链路

新增 `rtl/live_xyz_mapper.sv`，并在 `rtl/mgc3130_loop_control_path.sv` 中将 LIVE 专用输入与 RECORD/OVERDUB 输入分开。

当前 LIVE 映射定义为：

```text
X：完整 0x0000–0xFFFF，划分为 8 个音区，目标音为 C4 D4 E4 F4 G4 A4 B4 C5
Y：当前仅参与 X/Y 变化率稳定确认，不直接改变音高或音色
Z：负责 NOTE_ON、NOTE_OFF 和力度
```

Z 参数：

```text
Z_TOUCH_MIN = 4096
Z_ON         = 18432
Z_OFF        = 20480
```

Z 越小，力度目标越大；力度作为 latest-value modulation 传给 mixer，不占用离散事件 FIFO。X 音区变化经过稳定确认后生成 LIVE-only `EVENT_NOTE_REVOICE`，不会写入 Loop RAM。

RECORD/OVERDUB 仍使用原有输入适配器、Loop tick、RECORD FIFO 和调度器，不使用 LIVE 专用 X/Z 门控。

## 三、事件桥接和音频 mixer

新增并接入 `EVENT_NOTE_REVOICE`：

- `rtl/performance_event_pkg.sv`
- `rtl/performance_event_voice_bridge.sv`
- `rtl/loop_audio_path.sv`

`NOTE_REVOICE` 只改变目标音高，不创建新的和弦 bank。当前 mixer 的设计目标是连续弦乐/特雷门琴式演奏：

- 主 DDS 相位保持连续；
- 目标相位步进平滑逼近新目标；
- 主振荡器为三角波，辅助振荡器为低比例 saw；
- 两个振荡器使用同一个滑音目标，避免独立漂移造成跑调；
- Z 力度经过 sample-rate gain slew；
- NOTE_OFF 保持原设计的硬静音语义。

今天定位到的关键 DDS 问题是：旧相位表按 50 MHz 每时钟更新计算，而新 mixer 改为音频 sample enable 更新后仍直接使用旧步进，导致音频频率降到亚赫兹范围。之后又发现整数 `50 MHz / 1041` 分频会造成实际采样率和理想 48 kHz 不一致。当前 RTL 已改用 fractional sample tick，使平均 sample rate 精确为 48 kHz。

当前 RTL 仍需要在硬件上继续验证以下听感问题：

- Z 在阈值附近抖动时是否会产生重复 NOTE_ON/OFF；
- 大力度下是否仍有削波或听感跑调；
- X revoice 的滑音时间是否适合实际演奏；
- Y 是否需要后续接入连续 timbre 控制。

## 四、仿真验证

今天通过的重点 ModelSim 测试：

```text
scripts/test_calibration_capture.ps1
scripts/test_calibration_top.ps1
scripts/test_live_xyz_mapper.ps1
scripts/test_live_fifo_burst.ps1
scripts/test_voice_mixer.ps1
scripts/test_loop_audio_path.ps1
scripts/test_input_pipeline.ps1
scripts/test_board_integration.ps1
scripts/test_top_loop.ps1
scripts/test_control_plane.ps1
scripts/test_voice_bridge.ps1
scripts/test_mode_gated_event_paths.ps1
```

其中 LIVE mapper 测试包含静止 XYZ 多帧检查，确保手停在一个位置时不会重复生成 NOTE_ON/OFF；mixer 测试包含 DDS 相位推进、非硬方波、满力度不削波和 NOTE_REVOICE 不增加声部数量的检查。

## 五、位流状态

最后一次成功完成 Gowin 综合、布局布线和位流生成的文件是：

`bitstream/mgc3130_uart_loop.fs`

```text
生成时间：2026-10-18 23:06:22
SHA256：9714F068F640736E70D6E5CE11FD9BB5171477D6658EDEDF7DCC1BA5BD822899
```

注意：该位流包含 C4–C5 音区、较快 X 滑音和柔和双振荡器 mixer，但不包含之后新增的 fractional sample tick 修改。当前 RTL 与该位流不完全一致，后续烧录前必须重新执行 `scripts/build.tcl` 并重新核对 SHA256。

## 六、后续建议

1. 重新综合当前 fractional DDS RTL，生成与源码一致的新位流。
2. 烧录前后分别读取 `diag-input`、`diag-audio` 和 `diag-router`。
3. 用固定 X/Y、逐步改变 Z 的方式单独验证力度，不同时移动 X/Y。
4. 用固定 Z、跨越相邻 X 音区的方式测量滑音连续性。
5. 若仍出现短促滴声，优先记录 NOTE_ON/OFF 计数和 Z 原始值，再调整 Z 滞回，不先改音色参数。
6. Y 音色控制应作为独立的平滑 timbre 参数接入 mixer，不能复用 NOTE_ON/OFF 或 NOTE_REVOICE 事件。

## 七、2026-10-19 后续讨论索引

音频之前的 MGC3130 输入反馈思路已记录于
[MGC3130 音频前输入反馈设计讨论](mgc3130-pre-audio-feedback-discussion-2026-10-19.md)。
内容包括位置估计反馈、候选与已生效控制状态的确认机制，以及 X 和声、Y 节奏、Z 主奏力度的 Synthwave 探索方向。该文档是待验证的讨论记录，不代表 RTL、位流或实机问题已经修复。
