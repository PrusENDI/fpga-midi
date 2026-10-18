# MGC3130 原始坐标校准

这是一个临时校准路径，不属于 Loop 生产顶层。它从 `mgc3130_reader` 的解析输出直接采集原始 `X/Y/Z`，通过 C3 以 115200 8N1 发送固定长度二进制帧。

校准位流使用 `mgc3130_uart_calibration_top`，生产 Loop 位流仍使用 `mgc3130_uart_loop_top`。生成校准位流时必须使用独立文件名，例如 `bitstream/mgc3130_uart_calibration.fs`，不要覆盖 `bitstream/mgc3130_uart_loop.fs`。

采集命令：

```powershell
python tools\capture_mgc3130_calibration.py --port COM4 --seconds 60 --out calibration\session_001
```

输出文件：

- `frames.bin`：串口收到的原始字节，便于重新解析。
- `samples.csv`：每个有效帧的原始字段和 flags。
- `metadata.json`：协议版本、BUILD_TAG、端口和采集时间。
- `summary.json`：帧数、丢帧、CRC 错误和坐标范围。

每次采集前记录传感器板方向、安装高度、MGC 固件/配置和动作编号。建议按以下顺序操作：

1. 远离传感器采集 5 秒，记录无手基线。
2. 在传感器表面固定网格位置，每个位置静止 2–3 秒，重复 3 次。
3. 固定 Y 做纯 X 左右移动。
4. 固定 X 做纯 Y 上下移动。
5. 固定 X/Y 做 Z 靠近、停留、离开，重复至少 20 次。

采集工具会把序号跳变记入 `gap_before`，并把 CRC 错误计入 `summary.json`。若没有收到 metadata 帧，先停止参数分析，检查校准位流、C3/COM4 和波特率。

帧布局为 32 字节：`A5 5A version type length sequence timestamp flags x y z gesture error_code touch_info build_tag reserved crc8`。多字节字段使用 little-endian；CRC8 多项式为 `0x07`，计算范围是 `version` 到 `reserved`。
