# MGC3130 I2C -> UART

最小实机工程：读取 MGC3130 的 24 字节 Sensor Data Output，解析 X/Y/Z 和 gesture，通过 115200 8-N-1 UART 回传到 PC。核心板同时通过 BTB 向 MGC3130 传感器板提供 3.3 V 电源。

## 工程文件

- `rtl/mgc3130_uart_top.sv`：顶层
- `rtl/mgc3130_reader.sv`：I2C/TS 读取和报告解析
- `rtl/mgc3130_reset_seq.sv`：MCLR 上电复位时序
- `rtl/mgc_uart_report_tx.sv`：UART 二进制报告帧
- `rtl/uart_tx.sv`：UART 发送器
- `mgc3130_uart.cst`：管脚和 IO 约束
- `mgc3130_uart.sdc`：50 MHz 时钟约束

## 当前暂定管脚

- `clk_50m = E2`，来自板载 X1 50 MHz 振荡器
- `uart_tx = J4`，J3-6
- `mgc_sda = K4`，J3-5
- `mgc_scl = K1`，J3-2
- `mgc_ts = L1`，J3-3
- `mgc_mclr = L2`，J3-4

## MGC3130 供电和接线

核心板通过 BTB 的 `VDD_3V3` 输出给 MGC3130 供电：

```text
核心板 J2-46 / J2-48 / J2-50  (VDD_3V3) → MGC3130 VDD/3V3
核心板任意 GND 排针               → MGC3130 GND
```

`J2-46/J2-48/J2-50` 是同一个 `VDD_3V3` 电源网络的并列引脚，选择其中一个供电即可，另外的 3.3 V 引脚可以作为备用。不要把 `VDD_1V8` 或 `VDD_2V5` 接到 MGC3130。

MGC3130 传感器板应在芯片电源脚附近放置本地去耦，至少包括 `100 nF`，并按传感器板原理图增加 `1 µF` 或更大的储能电容。SDA、SCL、TS 的上拉电阻必须连接到同一 3.3 V 电源；如果传感器板已经带上拉，FPGA 端不再重复安装强上拉。

四个 MGC 信号使用你图片中的 J3 排针：`SDA→J3-5(K4)`、`SCL→J3-2(K1)`、`TS/EIO0→J3-3(L1)`、`MCLR→J3-4(L2)`。UART 回传使用 `J3-6(J4)`。这些是 FPGA 封装球位和 J3 排针位置，接线时以底板丝印方向为准。供电使用 `VDD_3V3→MGC3130 VDD`，并共地。

MCLR 连接为 `MCLR→E1`。FPGA 将它作为开漏输出：上电后拉低 250 ms，随后释放为高阻，由传感器板上的外部 10 kΩ 上拉拉高；释放后继续等待 2 s，完成后才启动 I²C 读取。MCLR 不应由 FPGA 强推高。

## UART 帧

```text
AA 55 0A 01 SEQ X_L X_H Y_L Y_H Z_L Z_H GESTURE FLAGS CHECKSUM
```

115200 baud，8 数据位，无校验，1 停止位。`CHECKSUM` 是从长度字节到 FLAGS 的逐字节 XOR。

## Gowin IDE

打开 `mgc3130_uart.gprj`，确认顶层为 `mgc3130_uart_top`，替换 `.cst` 中的 MGC 管脚后执行 Synthesize、Place & Route、生成 `.fs`，再用 Programmer 进行 SRAM 下载。

工程器件必须选择开发板实际型号 `GW5A-LV25MG121NES`。如果 Gowin IDE 仍显示旧的 `NC1/I0` 器件，关闭工程后重新打开 `mgc3130_uart.gprj`，并删除旧的 `impl/` 输出目录后重新综合和布局布线。

## 编译步骤

1. 启动 Gowin IDE。
2. 选择 `File -> Open`，打开本目录下的 `mgc3130_uart.gprj`。
3. 在工程层次窗口确认顶层模块为 `mgc3130_uart_top`。
4. 检查工程文件列表包含：
   - `rtl/mgc3130_uart_top.sv`
   - `rtl/mgc3130_reader.sv`
   - `rtl/mgc3130_reset_seq.sv`
   - `rtl/mgc_uart_report_tx.sv`
   - `rtl/uart_tx.sv`
   - `mgc3130_uart.cst`
   - `mgc3130_uart.sdc`
5. 确认 `mgc3130_uart.cst` 中的管脚：时钟 `E2`、UART `J4`、SDA `K4`、SCL `K1`、TS `L1`、MCLR `L2`。
6. 在左侧 `Process` 窗口执行 `Synthesize`。
7. 综合成功后执行 `Place & Route`。
8. Place & Route 成功后执行 `Generate Bitstream` 或 `Generate Programming File`。
9. 在工程输出目录找到生成的 `.fs` 文件。文件名通常类似 `mgc3130_uart.fs`。

如果综合或布局布线失败，先看 Process 窗口中的第一条错误。常见原因是顶层端口名与 `.cst` 不一致、管脚冲突、器件型号不一致或 Bank 电压约束不匹配。

## Programmer 下载到 FPGA

### 临时下载到 SRAM

这种方式适合调试，断电后 FPGA 配置会丢失。

1. 给开发板接好电源。
2. 连接 Gowin USB-JTAG 下载器和开发板 JTAG 接口。
3. 打开 Gowin IDE 的 `Tools -> Programmer`。
4. 在 Programmer 中选择 USB-JTAG Cable，点击扫描/刷新。
5. 确认扫描到 GW5A 器件。
6. 选择生成的 `.fs` 文件。
7. Operation 选择 `SRAM Program` 或 `SRAM Configuration`。
8. 点击 `Program/Configure`。
9. 看到 `Program Successful` 后，FPGA 已开始运行。

### 上电自动运行

SRAM 下载断电会消失。需要长期保存时，在 Programmer 中选择外部 Flash 编程操作，并确认开发板上的 Flash 型号、SPI 电压和启动模式正确。首次调试建议只使用 SRAM 下载，不要先擦写 Flash。

## 实机连接

烧录前确认：

```text
MGC3130 VDD      -> 核心板 VDD_3V3
MGC3130 GND      -> 核心板 GND
MGC3130 SDA      -> J3-5 / K4
MGC3130 SCL      -> J3-2 / K1
MGC3130 TS       -> J3-3 / L1
MGC3130 MCLR     -> J3-4 / L2
PC/USB-UART RX   -> J3-6 / J4 (FPGA uart_tx)
```

MCLR 必须有传感器板侧的约 `10 kΩ` 上拉，SDA/SCL/TS 也必须有连接到 3.3 V 的上拉。PC 串口参数为 `115200, 8-N-1`。
## Onboard USB-UART connection

The Tang Primer 25K official UART example connects the FPGA transmit signal to
FPGA pin `C3` and the receive signal to `B3`. The onboard debugger exposes this
UART as a Windows COM port; no separate USB-UART adapter or mode switch is
needed. This project only transmits, so `uart_tx` is assigned to `C3`.

After changing this constraint, rerun Place & Route and regenerate the
bitstream before programming. Open the COM port at 115200 baud, 8 data bits,
no parity, 1 stop bit. The MGC3130 project sends binary frames beginning with
`AA 55`, so use a hex-capable terminal or a small serial reader.

