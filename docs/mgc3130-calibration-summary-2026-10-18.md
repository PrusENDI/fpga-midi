# MGC3130 校准工作总结（2026-10-18）

## 文档范围

本文记录今天对 MGC3130 传感器和 FPGA 音频 Loop 项目的校准工作。它是分析记录，不代表任何参数已经写入生产 RTL，也不代表已经生成或烧录新的 Loop 位流。

工程基线仍为 `feat/loop-event-store` 分支的 `632a9c7 Separate Loop event ingress paths`。生产 Loop UART 协议和 `mgc3130_uart_loop_top` 未修改。校准使用独立的 `mgc3130_uart_calibration_top`，没有覆盖生产位流，也没有执行 `git reset` 或 `git clean`。

## 采集路径

```text
MGC3130 -> I2C reader/report parser -> calibration capture FIFO
         -> UART serializer -> FPGA C3 -> COM4 115200 8N1
         -> frames.bin / samples.csv / summary.json
```

采集的是 `mgc3130_reader` 解析后的原始 X/Y/Z 和状态字段，位于输入滤波、滞回、音符映射和 LIVE Z 门控之前。固定帧含序号、时间戳、flags、X/Y/Z、错误字段、BUILD_TAG 和 CRC8。序号缺口记录在 `gap_before`，便于区分传感器问题和串口采集丢帧。

采集命令：

```powershell
python tools\capture_mgc3130_calibration.py --port COM4 --seconds 60 --out calibration\session_xxx
```

每次采集保留 `frames.bin`、`samples.csv`、`metadata.json` 和 `summary.json`。

## 已确定的设计目标

### X/Y

需要实际确认：

```text
x_left, x_center, x_right
y_bottom, y_center, y_top
```

不能只用仿真中的 `0x8000` 作为中心。重新设置 Aurea `Sensing Area` 后，四个输出边界已经可以覆盖到接近 0 和 65535。

LIVE 设计要求：

- Y 使用全音音阶。
- LIVE Y 上下各裁掉约 5%。
- LIVE X 触发距离缩短为原来的约一半。
- 最终音色为方波。
- 这些门控只作用于 LIVE。
- RECORD/OVERDUB 的换音继续由 Loop 计时器和已记录事件决定。

中心确认后，计划使用中心锚定的分段线性映射：

```text
x <= x_center:
  x_norm = 0.5 * (x - x_left) / (x_center - x_left)

x > x_center:
  x_norm = 0.5 + 0.5 * (x - x_center) / (x_right - x_center)
```

Y 轴同理，必要时翻转方向。LIVE Y 裁切计划在归一化后执行：

```text
y_live = clamp((y_norm - 0.05) / 0.90, 0, 1)
```

### Z

用户希望 Z 越小声音越大，靠近触摸状态的约 20% 量程用于力度；Z 高于该区间时渐进式抬键并停止发音。

`session_0013_z` 显示：

```text
浮空：约 61000–65535
触摸：约 300–4100
```

暂定 LIVE 起点：

```text
Z_TOUCH     = 5000
Z_FORCE_END = 16000
Z_REPRESS   = 14000
gain = 0.20 + 0.80 * (16000 - Z) / (16000 - 5000)
```

超过 `Z_FORCE_END` 后计划使用约 30–80 ms 的释放包络。最终阈值必须以板上有效帧确认，并使用滞回，不能按单帧切换。这部分尚未写入生产 RTL，也尚未完成最小仿真。

## 传感器和边缘问题

查阅本地 MGC3130/GestIC 资料后的判断：

- 四个外围 Rx 电极形成的空间定位场在边缘、角落处天然更不线性。
- 电极尺寸、Rx-Tx 距离、对地寄生、盖板、手的接地状态和安装结构都会影响 XY。
- 默认 XY 参数可能不适合当前板卡。
- Aurea 提供 `Sensing Area`、`E-field Linearization`、`Electrode Weighting`、Minimum/Maximum Z Level 和 Filter Adjustment。
- 手册没有把“坐标快速塌缩到左下或右下”列为单独故障名，但它与电场非线性、传感区域参数和电极权重不匹配相符。

今天没有向 MGC3130 发送未经确认的 force-baseline 命令，也没有修改 UART 协议。以后如需验证 baseline，必须先取得与当前固件匹配的正式命令帧定义。

## 数据采集结论

### 早期 X/Y 和中心数据

`session_002`、`session_003`、`session_005_x_left_center`、`session_006_x_right_center`、`session_007_y_bottom_center`、`session_008_y_top_center` 和 `session_009_y_bottom_center` 显示：

- 水平移动左侧可能快速转成竖直并落到 Y 零点。
- 竖直移动中间可能断开，可能与腕部遮挡有关。
- Y 下边存在较大的 X 偏差。
- 四条物理边缘的另一轴会明显变化。
- 传感器输出不是理想的正方形仿射坐标。

`session_0010_center_static` 得到旧配置下的中心候选：

```text
x_center ≈ 41444
y_center ≈ 52024.5
```

这些值没有写入生产 RTL。

### Z 数据

`session_0013_z` 支持“Z 越小越接近触摸、声音越大”的方向判断，但阈值仍是暂定值。

### Sensing Area 调整前

`session_0014_boardside`：

- 总帧数 4951，有效 XYZ 约 4949，CRC 0。
- 轨迹主要覆盖右边和上边。
- X 右边中位数约 65535，Y 上边中位数约 65436。
- 没有获得有效的物理左边和下边验证段。

因此旧配置下不能用它确定四边，也不能区分“未走到左/下边”和“发生塌缩”。

### Sensing Area 调整后

`session_0015_boardside` 是今天最重要的结果：

- 4736 帧全部有效。
- 序列缺口 0，CRC 错误 0。
- X 左边：1179 帧，中位数 0，范围 0–4086。
- X 右边：768 帧，中位数 65535，范围 61439–65535。
- Y 下边：104 帧，中位数 0，范围 0–4043。
- Y 上边：1612 帧，中位数 65534，范围 61440–65534。

这说明重新设置 `Sensing Area` 后，四条物理边缘都能稳定映射到对应输出边界，之前只出现右边和上边的问题明显改善。

边缘段另一轴仍然变化很大，例如 X 左边样本的 Y 范围为 0–54141，Y 上边样本的 X 范围为 5721–64090。沿正方形边缘移动时这属于实际几何轨迹，不能简单裁成固定中心值。

### 新中心数据

`session_0016_NEWCENTER` 有 59 帧序列缺口，只有短暂低运动窗口：

```text
x ≈ 24238
y ≈ 47721
```

它不足以替代旧中心，也不足以作为最终参数。

`session_0017_NEWCENTER`：

- 总帧数 4323，有效帧 4320，CRC 0。
- 最大序列缺口 3966 帧，约 1.44 秒。
- 主段包含下边缘、左边缘、上边缘和内部移动。
- 边缘样本：左 76、右 1、下 105、上 54。
- 内部轨迹主要为 X 约 10000–16000、Y 约 52000–58000。
- 较宽内部段中位数约为 X=13207、Y=55472。
- 短暂最低运动窗口约为 X=15748、Y=55430。

因此当前只能暂记：

```text
y_center ≈ 55000       // 候选
x_center ≈ 13000–16000 // 未确认
```

中心采集已暂停，不把这些候选值写入 RTL。

## 当前参数状态

可以暂用的输出边界：

```text
x_left   = 0
x_right  = 65535
y_bottom = 0
y_top    = 65535
```

尚未最终确认：

```text
x_center
y_center
```

当前不建议继续使用旧中心 `41444/52024.5`，也不建议直接采用新中心候选。重新恢复校准时，应在物理中心单独静止至少 2 秒，并且不要在同一份数据中先经过边缘再进入中心。

## 文件和工具

- `tools/capture_mgc3130_calibration.py`：COM4 原始采集。
- `tools/mgc3130_calibration_protocol.py`：固定帧解码和 CRC8。
- `tools/analyze_session_0011_side.py`：边界、轨迹和 SVG 分析。
- `tools/analyze_session_0013_z.py`：Z 轴分析。
- `tools/analyze_session_0014_boardside.py`：物理板边缘分析。
- `calibration/session_0015_boardside/analysis/`：调整后的四边结果。
- `calibration/session_0016_NEWCENTER/analysis/`：中心候选结果。
- `calibration/session_0017_NEWCENTER/analysis/`：最新中心结果。

## 暂停后的结论

1. 重新设置 `Sensing Area` 有效，四边可达性明显改善。
2. 边缘另一轴的大幅变化是当前传感器几何输出的一部分，不能用简单单轴边界值消除。
3. 中心点尚未完成校准；今天的两份新中心数据都不足以作为最终参数。
4. FPGA 裁切只能限制演奏有效区域，不能修复电场非线性；若边缘问题再次出现，应优先检查 Aurea 的线性化、Electrode Weighting 和安装结构。
5. LIVE Z 力度/抬键逻辑应先增加最小仿真，再修改 RTL；RECORD/OVERDUB 不得受 LIVE 专用门控影响。
6. 不生成或覆盖生产 Loop 位流，直到校准参数和 RTL 仿真结果另行确认。
