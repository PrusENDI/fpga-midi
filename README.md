# MGC3130 → FPGA → PC：官方 I2C MASTER 版本

2026-10-11 已将自编写的 I2C 位时序替换为 Gowin V1.9.12.04 自带的官方 **I2C MASTER**。板载时钟、MCLR、TS 接线和已验证的板载 USB-UART 保持原配置。

## 现在烧录哪个文件

使用 `bitstream/mgc3130_uart_official_i2c_gao.fs`。它是最新 `impl/pnr/ao_0.fs` 的副本，包含 GAO。

**不要选择旧的 `impl/pnr/mgc3130_uart.fs`**：启用 GAO 后高云输出的是 `ao_0.fs`，旧文件可能仍留在目录里。

Programmer 选择已能正常工作的板载 USB-JTAG Cable，扫描 GW5A-25A，选择上述文件，执行 `SRAM Program`。完成后等约 2.25 秒，串口打开 **115200、8N1、无流控、文本显示**。

## 当前串口输出

约每秒一行，例如：

```text
TS=0 M=1 S=1 C=1 V=01 E=00 K=0 X=1234 Y=5678 Z=9ABC G=01 P=1 D=00000000 F=0012 L=12
```

- `TS/M/S/C`：TS、MCLR、SDA、SCL 的采样电平。读事务进行时 FPGA 也会主动拉低 TS。
- `V`：成功解析的 Sensor Data Output 数量，十六进制，8 位循环计数；错误报告不再计入 V。
- `E`：错误事件数量，十六进制，8 位循环计数。
- `K`：最近的错误码；成功解析传感器报告后清零。
- `X/Y/Z`：最近解析出的 16 位坐标，四位十六进制。
- `G`：最近解析出的 gesture 低字节，十六进制。
- `P`：最近坐标的有效标志，1 有效。P=0 时不要把 X/Y/Z 当作有效位置。
- `D`：最近错误发生时冻结的四字节上下文；成功解析传感器报告后清零。第一字节为 `(state << 2) | operation`，第二字节为 IP 状态寄存器，第三字节为正在读取的字节索引，第四字节为消息 Size。operation=0 地址、1 读取、2 错误 STOP。
- `F`：最近 0x91 消息的 16 位 DataOutputConfigMask，十六进制。
- `L`：同一条 0x91 消息的 Size，十六进制；L=12 表示 18 字节，不是 12 字节。

这仍是用于调试的每秒状态快照，不是逐报告实时输出。短暂的 gesture 可能不会出现在快照中。旧的 `mgc_uart_report_tx.sv` 二进制发送器保留，但当前顶层没有启用它。

| K | 含义 |
| --- | --- |
| 0 | 无错误／最近传感器报告解析成功 |
| 1 | 发送地址 0x85 后从机未应答 |
| 2 | 单条 IP 命令超过 10 ms |
| 3 | 官方 IP 报告仲裁丢失 |
| 4 | 消息头 Size 小于四字节 |
| 5 | 等待 SDA/SCL 空闲超过整个事务的 100 ms 限制 |
| 6 | 整条消息事务超过 100 ms，且非上述命令或空闲等待超时 |
| 7 | 0x91 消息短于掩码要求的长度，或包含未支持的保留位／电极模式 |
| 8 | 上层控制状态异常 |

## 接线

| 信号 | FPGA 球位 | 用途／底板位置 |
| --- | --- | --- |
| clk_50m | E2 | 板载 50 MHz 振荡器，无需外接时钟 |
| uart_tx | C3 | 板载 USB-UART 桥，沿用已验证的串口连接 |
| SDA | K4 | J3-5 |
| SCL | K1 | J3-2 |
| TS / EIO0 | L1 | J3-3，双向开漏 |
| MCLR | L2 | J3-4，开漏复位 |

MGC3130 接 3.3 V 并共地；SDA/SCL 使用传感器板现有的外部上拉。TS/MCLR 应有外部上拉。FPGA 上电将 MCLR 拉低 250 ms，释放后等待 2 s，再开始读取。

E2 兼用 SSPI 功能。工程必须保持 **Use SSPI as Regular IO = True**；`scripts/build.tcl` 已设置对应选项。之前的 PR2017/PR2028 与该配置有关。

## 代码结构

```text
mgc3130_uart.gprj
mgc3130_uart.cst / .sdc / .rao
rtl/
  mgc3130_uart_top.sv    接线、每秒 ASCII 状态和数据快照
  mgc3130_reset_seq.sv   MCLR 上电复位
  mgc3130_reader.sv      TS 控制、IP 寄存器操作、读消息、解析报告
  uart_tx.sv            115200 UART 字节发送
ip/gowin_i2c_master/
  I2C_MASTER_TOP.v      官方包装模块
  I2C_MASTER.vp         官方加密核心
  static_macro_define.vh 官方宏定义
  top_define.vh         本工程设置模块名 Gowin_I2C_Master
scripts/build.tcl        可重复执行的综合／布局布线入口
bitstream/               当前官方 IP 版本烧录文件
backup_before_official_ip/ 替换前的 reader、top、工程、GAO 和 README
```

三个厂商文件从当前安装目录直接复制，内容未修改。由于本机 Tcl IPFlow 没有成功生成该核，本工程直接编译官方 RTL 模板和加密核心，并按工程中的 GW5A-LV25MG121NES 映射；没有使用 GW1N 参考工程的位流、PLL 或管脚约束。

## 读取流程

1. 写分频低字节 0x63、高字节 0x00，再写控制寄存器 0x80。50 MHz 时钟对应 100 kHz I2C。
2. 检测 TS 低，FPGA 拉低 TS，并等待至少 10 µs 和 SDA/SCL 空闲。
3. 发送 `{0x42, Read}`，即线上地址字节 **0x85**。按官方例程使用命令 0x90：START + WRITE。
4. 轮询状态寄存器，先观察 TIP=1，再等待 TIP=0，随后检查 RX ACK；不依赖 IF，避免把命令刚启动时的 TIP=0 误认为完成。主机轮询每几拍一次，远快于 100 kHz 的字节传输时间。
5. 先读 Size，再按 Size 连续读取整条消息。中间字节命令 0x20：READ + ACK；末字节 0x68：READ + NACK + STOP。
6. 确认 STOP 后总线空闲，释放 TS；至少等待 5 ms 再读下一条。非 0x91 消息完整读取后直接消费，例如复位后的固件信息。
7. 地址无应答／非法 Size 时请求 STOP；命令卡住时复位官方 IP、释放 TS 并重新配置。IP 复位不会重新复位 MGC3130，也不能保证排除从机持续拉低总线的问题。

消息缓冲上限 255 字节。当前按 Microchip GestIC SDK 1.2.0 的 `gestic_handle_data_output()` 动态计算字段偏移，不再强制掩码 0x001E 或长度 24。

| 字段 | 掩码 | 字节数 |
| --- | --- | --- |
| DSP status | 0x0001 | 2 |
| Gesture | 0x0002 | 4 |
| Touch | 0x0004 | 4 |
| AirWheel | 0x0008 | 2 |
| XYZ | 0x0010 | 6 |
| Noise power | 0x0020 | 4 |
| CIC raw | 0x0800 | 电极数 × 4 |
| SD raw | 0x1000 | 电极数 × 4 |

这些可选字段按表中顺序排列，从字节 8 开始。掩码 bits 10:8 的电极模式 0/1 分别为 4/5 个电极，沿用官方 SDK 定义。实现解析 gesture 和 XYZ，其余字段按长度跳过／检查；未知保留位及其他电极模式仍拒绝。

例：F=0012 时，仅 gesture+XYZ，Size 为 18（0x12），XYZ 从字节 12 开始；F=001E 时 Size 为 24（0x18），XYZ 从字节 18 开始。XYZ 只在该字段存在且 SystemInfo bit0=1 时更新。缺少字段或位置无效时 P=0，并保留上次有效坐标；gesture 字段缺失时 G=0。

此版没有新增向 MGC3130 写运行参数的初始化流程，继续使用传感器中已有的固件／配置。若 V 增加但 P 始终为 0，应结合 F 的 0x0010 位和位置有效状态判断。

核对来源：本机 `C:/Program Files (x86)/Microchip/GestIC SDK 1.2.0/api/src/stream.c` 的 `gestic_handle_data_output()`，及 `api/include/gestic_api.h` 的 `gestic_DataOutConfigMask_t` 和 `gestic_SystemInfo_t`。未更改 Microchip 文件。

## 重新编译

在 Gowin IDE 中关闭并重新打开 `mgc3130_uart.gprj`，以重新加载新增的 IP 文件和 GAO 设置。

1. 确认器件 GW5A-LV25MG121NES，顶层 `mgc3130_uart_top`，语言 Verilog-2001。
2. Include Path 设置为本工程的 `ip/gowin_i2c_master` 目录；当前配置已写入 `impl/mgc3130_uart_process_config.json`。
3. 保持 Use SSPI as Regular IO 为 True。
4. 执行 Synthesize，再执行 Place & Route。启用 GAO 时最新位流为 `impl/pnr/ao_0.fs`。

也可直接执行：

```powershell
& 'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe' 'C:\weizijian\documents\gowin fpga\mgc3130_uart\scripts\build.tcl'
```

该脚本成功编译后，会将 `ao_0.fs` 复制到 `bitstream/mgc3130_uart_official_i2c_gao.fs`。

## GAO

## 合成器当前阶段

`rtl/mgc3130_pattern_input.sv` 使用 MGC3130 固定校准坐标建立临时无按键录制入口：X 在 `0x1000..0xF000` 内量化为 8 个较宽时间格，左边界连续确认 3 帧开始，右边界连续确认 3 帧提交；Y 量化为 C 大调内的 8 个根音区 `C/D/E/F/G/A/B/C`，Z 映射为 8 位 velocity。手势暂不参与音符逻辑。

`rtl/mgc3130_voice_mixer.sv` 维护 4 个独立方波 DDS 声部，在 48 kHz 采样节拍产生带饱和的有符号 16 位混音样本。当前输出只到 `mixed_sample` 数字接口，尚未连接 PWM、I2S、DAC 或新增物理管脚。

音符切换时先关闭旧声部并插入约 5 ms 的静音，再启动新音符，避免相邻量化音符听成连续阶梯滑音。

当前顶层参数 `AUDIO_STREAM=1` 默认选择 UART 音频串流：48 kHz、8 位无符号单声道 PCM，以 32 样本二进制帧通过 921600 8N1 发送。帧格式为 `A5 5A sequence length payload[32] checksum`。电脑端可用 `tools/play_pcm_uart.py COMx` 接收并保存/播放；需要 `pyserial` 和 `sounddevice`。需要 ASCII 坐标诊断时，将该参数临时改为 `0` 后重新综合并下载。

UART 每秒快照在原有 I2C 诊断字段后追加 `R`（录制状态）、`N`（音符编号）、`V`（力度）和 `A`（活动声部数）。

新配置采样时钟 50 MHz、8192 点，约 163.84 µs，触发为 `u_reader/state = 5`（开始发送地址）。足以观察地址字节和 ACK，但不足以覆盖整个 24 字节报告。

已删除旧的 `sda_oe/scl_oe/tx_bit` 探针，增加 `ip_wr_data`、`ip_status`、`rx_byte`、`frame_length` 和 `last_message_id`。

`ip_status` 是官方状态寄存器最近一次读取的快照：bit7=未收到 ACK，bit6=总线 Busy，bit5=仲裁丢失，bit1=TIP，bit0=IF。判断地址应答应结合状态和 operation；读取阶段的 bit7 不表示主机对接收字节发的 ACK。

SDC 将板载时钟与 GAO 的独立 JTAG TCK 声明为异步，仍分析两域各自内部的同步时序。该约束本身不构成 CDC 正确性的验证。

## 本次编译结果与边界

2026-10-11 使用 Gowin V1.9.12.04 完成综合、Place & Route 和位流生成。加入可变字段解析后的最新时序报告 setup/hold 违例端点均为 0；50 MHz 域 Fmax 报告约 73.991 MHz，满足 50 MHz。含 GAO 使用 BSRAM 28/56、逻辑 2511/23040。

综合有两项来自未修改的官方加密核心的警告：EX2629（不综合 delay）和 EX3827（full_case 的综合／仿真差异）。没有报告语法、未知模块或管脚放置错误。

本工程没有进行 RTL 仿真。官方 IP 的 clock stretching 行为仍未通过文档明确保证；但下方的实机日志已经确认 MGC3130 数据帧可被 FPGA 读取。

## 已验证的实机 I2C 通讯结果

2026-10-11 使用最新位流在 Tang Primer 25K 上实机验证，PC 串口收到如下类型的连续输出：

```text
TS=0 M=1 S=1 C=1 V=79 E=00 K=0 X=0000 Y=540F Z=D5F4 G=00 P=1 D=00000000 F=0112 L=12
```

这证明以下链路已经打通：

```text
MGC3130 TS 请求
  -> Gowin I2C MASTER 产生 START / 0x85 / ACK / 连续 READ / NACK+STOP
  -> FPGA 按 Size 接收并解析 0x91 消息
  -> UART 115200 8N1 发送到 PC
```

实机输出字段的含义：

| 输出 | 含义 | 本次结果 |
| --- | --- | --- |
| `E=00` | I2C 和消息处理错误计数 | 没有错误 |
| `V=79` | 成功解析报告计数，8 位循环计数 | 正在持续增加 |
| `F=0112` | `DataOutputConfigMask` | 电极配置 `0x0100` + gesture `0x0002` + XYZ `0x0010` |
| `L=12` | 消息 Size，十六进制 | `0x12` = 18 字节 |
| `P=1` | SystemInfo 的 Position Valid | 该帧 XYZ 有效 |
| `X/Y/Z` | 小端序 16 位坐标 | 已收到非零数据 |
| `G=00` | gesture 字段低字节 | 当前样本无手势事件，属于正常状态 |
| `TS=0` | 该快照时 TS 被拉低 | FPGA 正在处理一次 TS 请求或采样时刻处于请求期间 |

`V` 是 8 位计数器，达到 `FF` 后回到 `00`，所以日志中出现 `F9 -> 8F` 等跳变是计数回绕，不是 I2C 丢包。`X/Y/Z` 某一帧为 0 也不表示链路失败，应以 `P=1` 和连续帧观察为准；传感器在不同帧可能报告零坐标分量。

### F=0x0112 的实际消息布局

消息从字节 0 开始计数：

| 字节 | 内容 |
| ---: | --- |
| 0 | Size = `0x12` |
| 1-2 | MGC3130 消息头保留／协议字段 |
| 3 | Message ID = `0x91`，Sensor Data Output |
| 4-5 | DataOutputConfigMask = `0x0112`，小端序 |
| 6 | 时间戳 |
| 7 | SystemInfo，bit0=1 表示 XYZ 有效 |
| 8-11 | GestureInfo，低字节为 gesture code |
| 12-17 | X、Y、Z，各 16 位小端序 |

因此 `L=12` 表示 18 字节，而不是 12 字节。此前代码固定等待 24 字节并固定使用 `0x001E` 偏移，导致 18 字节消息被误报为 `K=7`；现已改为按掩码动态计算偏移。

### 已验证的 I2C 主机命令序列

当前上层状态机通过官方 I2C MASTER 的 SRAM 接口执行：

1. 写 `PRERLO=0x63`、`PRERHI=0x00`，得到 100 kHz 总线时钟（`50 MHz / (5×100 kHz) - 1 = 99`）。
2. 写 `CTR=0x80`，使能 Master。
3. TS 变低后，写 `TXR=0x85`，然后写 `CR=0x90`，产生 START 并发送读地址。
4. 读取 `SR`，先等待 `TIP=1`，再等待 `TIP=0`；完成后检查 `RX ACK` 位。
5. 读取 `RXR` 得到第一个字节 Size，再根据 Size 重复读取：中间字节 `CR=0x20`（READ+ACK），最后字节 `CR=0x68`（READ+NACK+STOP）。
6. 读取完整消息后释放 TS，并等待 5 ms 再处理下一次请求。

实机输出 `E=00`、`V` 持续增加和 `P=1`，同时证明地址 `0x85`、ACK、连续读取、末字节 NACK/STOP 及消息解析均已工作。

## 当前进度：可接入合成器模块

截至 2026-10-11，I2C 读取链路已达到后级合成器接入条件：MGC3130 的 TS 请求、官方 Gowin I2C MASTER、按 Size 接收 0x91 消息、按 `DataOutputConfigMask` 解析 XYZ/gesture，以及 UART 调试回传均已在 Tang Primer 25K 实机验证。后续合成器不应读取 UART，而应直接连接 `mgc3130_reader` 的并行输出。

### 合成器接口

```text
report_valid  : 新消息解析完成脉冲，保持 1 个 clk_50m 周期
xyz_valid     : 当前消息的 XYZ 是否有效
x_position    : 16 位坐标，小端消息已转换为并行数值
y_position    : 16 位坐标，小端消息已转换为并行数值
z_position    : 16 位坐标，小端消息已转换为并行数值
gesture_code  : gesture 信息低字节；0 表示当前帧没有手势事件
report_error  : 当前消息或解析是否出错
busy          : I2C 事务正在进行
```

推荐在合成器前增加一个同一 `clk_50m` 时钟域的输入锁存层：当 `report_valid && xyz_valid && !report_error` 时锁存 X/Y/Z 和 gesture，并产生合成器自己的 `input_valid` 脉冲。`report_valid` 是脉冲，不能只在后级持续读取电平；坐标应在该脉冲周期锁存。当前坐标是 16 位无符号值，中心偏置、缩放、限幅和有符号转换由后级完成。

推荐数据路径：

```text
mgc3130_reader
  -> 坐标锁存/中心偏置/缩放
  -> 手势事件锁存与去重
  -> 合成器控制参数
  -> 相位累加器/波表或 DDS
  -> PWM、I2S 或 DAC 输出
```

当前仍未完成的合成器工作包括：确定坐标到音高/音量/声道的映射、坐标滤波和死区、gesture 事件去重、音符/频率状态机、音频输出接口，以及必要的 FIFO 或 ready/valid 背压。I2C 模块本身不负责这些策略。UART 状态输出仍是调试用途，不作为合成器生产数据接口。

## 首次实机回报 K=2 后的修订

首次实机输出 V=00、K=2，确认发生读取超时，但旧日志没有指出超时阶段。
与官方例程比较后，将 0x91/0x21/0x69 改为 0x90/0x20/0x68，并将 IF+TIP 判断改为先忙后空的 TIP 判断；STOP-only 命令为 0x40。同时新增冻结的 D 错误上下文，并区分 K=2/5/6。
这纠正了接入代码与官方范例的差异；是否就是实机超时的原因，需要这次烧录结果确认，不能仅凭编译判断。

若仍超时，请保留完整行，尤其是 K 和 D。例如 D 第一字节为 0x20 表示 state=8（状态判断）、operation=0（地址），0x21 表示读字节，0x10 表示 state=4（等待总线空闲）。若 watchdog 恰在读寄存器子状态发生，第一字节也可能为 0x1C、0x54、0x58 等，应按上述公式解码。

## 收到 18 字节消息后的修订

用户回报 K=7、D=31811112。第一字节 0x31 对应解析状态 12、读操作 1；末两字节表示最后读到索引 17、Size 为 18。旧解析器只接受 24 字节和 0x001E，因此拒绝了已完整读取的 0x91 消息。

此次修订按上述官方 SDK 的可选字段布局解析，并增加 F/L 输出。日志自身未给出实际掩码，不能仅由 18 字节断定一定是 0x0012；以新串口 F 值为准。
