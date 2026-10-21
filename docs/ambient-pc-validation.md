# Ambient 合成器 PC 验证

> **历史基线**：当前产品语义以 [MGC3130 Melodic Synthwave 交互合成器系统设计](mgc3130-melodic-synthwave-system-design-2026-10-19.md) 为准。本文件只保留早期 Ambient 分析器的输入输出说明；其中的临时 Bass/Pad/Drums 生成不属于当前实现。

这份文档记录早期的 PC 算法基线：验证“完整 MGC3130 轨迹 → Ambient Lead 事件表”，不把音频样本或 FPGA 时序混进判断。输入是已经解码的 XYZ 报告，输出格式可以交给现有 Loop event store。当前 v0 分析器仍会生成临时 Bass/Pad/Drums 示例事件；这些事件只是旧基线的占位，不能作为最终产品语义。

## MGC3130 SDK 边界

本机安装了 Microchip GestIC SDK 1.2.0：

```text
C:\Program Files (x86)\Microchip\GestIC SDK 1.2.0
```

SDK 包含 Windows `gestic.dll`、`stream-static.exe` / `stream-dynamic.exe`、C 头文件和 `stream.c` 源码。`gestic_open()` 通过 SDK 支持的 USB-I²C 桥连接 MGC3130，`gestic_data_stream_update()` 处理分片消息，最终由 `gestic.result.pos` 提供 X/Y/Z。SDK 负责设备通信和 MGC3130 数据帧解码，不负责本项目的节奏、音阶、Viterbi 或 Loop 编曲。

当前 FPGA 也已经把同一层数据导出为 `samples.csv`，因此离线验证不依赖 SDK 设备连接。等算法稳定后，可以把 SDK 的 `gestic_position_t` 转成同样的 CSV/行流格式，复用后面的分析器。

## 运行离线分析

在 `mgc3130_uart` 目录执行：

```powershell
python tools\test_ambient_analyzer.py
python tools\ambient_analyzer.py `
  calibration\session_0011_side\samples.csv `
  --output calibration\session_0011_side\analysis\ambient_events.json
```

分析器只使用 Python 标准库。它会过滤无效报告，进行弧长重采样、单调回归、五点二次 Savitzky–Golay 平滑、Douglas–Peucker onset 提取、带累积残差的 128 tick 网格量化，并以 A 小调五声为候选集做确定性 Viterbi。输出包含 Lead 事件以及高点位置、音阶、vamp 和 FX 参数诊断。旧版代码中的 Bass、Pad 和 Drums 事件只用于早期试听，新的设计要求这三条轨道由 MGC3130 Touch/Tap 逐轨独立录制，不能由 Lead 或模板派生。

当前验证结果（`session_0011_side`）：

```text
有效报告：4666
事件总数：29
Lead：5 个音符
Bass：8 个事件
Pad：12 个事件
Drums：4 个事件
高点：71.65% loop 位置
终音：A
```

## 与 FPGA Loop 的关系（旧基线）

PC 端只生成控制事件，不生成或保存音频。旧基线曾把 Lead/Bass/Pad/Drums 一起写入 shadow bank；新设计改为 Lead 由轨迹编译器生成，Bass/Pad/Arp/Drums 由当前选定轨道逐轨录制 Touch/Tap 事件后再写入 shadow bank。现有 `loop_scheduler`、`loop_event_store`、`loop_audio_path` 和 48 kHz mixer 保持不变。事件槽容量、层数限制和 UART 控制语义仍由 FPGA 侧执行。

目前还没有把 `gestic.dll` 直接加载进 Python，也没有宣称 USB-I²C SDK 实时链路已经验证；这一步先用真实 FPGA 采集数据验证算法。下一步可以增加一个 SDK/串口适配器，把实时 `gestic_position_t` 或 FPGA UART 行流接到同一个 `ambient_analyze()` 输入接口。
