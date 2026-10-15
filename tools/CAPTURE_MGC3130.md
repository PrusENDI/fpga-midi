# MGC3130 坐标采集与 Gowin 回放

先让 FPGA 输出当前 ASCII 调试行，再在本目录运行：

确认 `rtl/mgc3130_uart_top.sv` 中 `AUDIO_STREAM = 0`，重新综合并下载 FPGA。
当 `AUDIO_STREAM = 1` 时，UART 是二进制 PCM 音频流（以 `A5 5A` 开头），
终端中会显示乱码，不能用于本坐标采集脚本。

当前顶层状态报告周期为 20 ms（约 50 报告/秒）。如果仍看到约 1 秒一条，
说明板上仍运行旧 bitstream，需要重新执行 Gowin 构建并下载生成的 `.fs` 文件。

```powershell
python capture_mgc3130.py COM4 --duration 30 --output-prefix capture_walk_01
```

脚本会生成：

- `capture_walk_01.csv`：有效报告的主机时间、时间间隔、X/Y/Z 和手势字段；
- `capture_walk_01.hex`：每行一个 64 位 `$readmemh` 字，布局为
  `X[63:48] Y[47:32] Z[31:16] G[15:8] reserved[7:1] VALID[0]`；
- `capture_walk_01.json`：有效/无效行数、坐标范围和时间间隔统计。
- `capture_walk_01.raw.log`：每一行原始 UART 文本及过滤原因，便于诊断为什么没有有效报告。

默认只保存 `P=1 && E=00 && K=0` 的 XYZ 报告。串口停止采集可按 `Ctrl+C`。
如果有效报告数为 0，先查看 `.raw.log`，其中会显示例如 `P=0`、`E=xx`、`K=xx`
或 `missing-field`，无需再次猜测串口格式。

在 Gowin 仿真中把 `sim/tb_mgc3130_pattern_input_replay.v` 加入工程，并设置：

```verilog
defparam REPLAY_FILE = "capture_walk_01.hex";
defparam REPORT_INTERVAL_CYCLES = 250000; // 5 ms @ 50 MHz
```

回放 testbench 每条记录产生一个 `report_valid` 单周期脉冲，驱动现有
`mgc3130_pattern_input`。`CSV` 中的真实间隔用于后续分析；仿真先用固定间隔，
这样不依赖主机文件 I/O 或浮点时间处理。

运行本地解析测试：

```powershell
python test_capture_mgc3130.py
```
