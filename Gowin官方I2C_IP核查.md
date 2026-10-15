# 高云官方 I2C IP 核查

核查日期：2026-10-11。目标：Tang Primer 25K（GW5A-25A）读取 MGC3130，并通过现有 UART 回传数据。

后续状态：用户确认替换后，已接入本机官方 RTL 模板和加密核心，完成综合、Place & Route 和位流生成。当前使用说明见 [README.md](README.md)。下文保留替换前的资料核查结论；clock stretching 仍未获得实机确认。

## 结论

本机 Gowin V1.9.12.04 已安装官方 **I2C MASTER**，是当前工程优先考虑的候选。已确认器件支持清单、连续读、ACK/NACK 和状态寄存器；**clock stretching 尚未获得明确的文档保证，不能据此宣称全部条件已满足**。

本次只进行资料核查，没有替换当前 RTL，也没有进行综合、仿真或板上验证。

## 逐项核对

| 要求 | 结果 | 证据 |
| --- | --- | --- |
| GW5A-25A 可选 | IP 清单支持 | 安装目录 i2cmaster.ipspec 支持通配符 `*`，仅排除 GW1Q-0P5A |
| 100 kHz / 400 kHz | 支持 | IPUG504-1.5E 第 3 页 |
| 7 位地址 0x42 | 支持 7 位地址；0x42 由控制器写入 | 第 3 页、发送寄存器和操作流程 |
| START / STOP / repeated START | 支持 | 第 3、10 页 |
| 连续多字节读取 | 支持 | 第 12 页，重复 READ 操作 |
| 中间字节 ACK，末字节 NACK + STOP | 支持 | 第 12 页：命令 0x20、末字节命令 0x68 |
| 地址/发送字节应答检测 | 支持 | 第 9 页：RX ACK 状态，1 为未收到应答 |
| Busy / 完成 / 仲裁丢失 | 支持 | 第 9 页：Busy、TIP、IF、AL |
| SDA / SCL 开漏 | 官方参考工程确认采用拉低或高阻 | 参考工程 i2c_master.v，IOBUF 的 I 接 GND，由 OEN 控制释放，外部上拉仍需要 |
| 从机 clock stretching | 未充分确认 | 用户指南没有明确描述；核心 RTL 加密，SCL 输入反馈本身不足以证明拉伸时序正确 |
| 超时、错误恢复 | 未确认 IP 内建支持 | 接入时应由上层控制器设计超时及恢复策略 |

文档页码指页脚标注的正文页码。

## 接口和接入方式

I2C MASTER 提供同步 SRAM 风格的寄存器接口：`I_TX_EN/I_WADDR/I_WDATA` 写寄存器，`I_RX_EN/I_RADDR/O_RDATA` 读寄存器，`O_IIC_INT` 通知事件。它不要求必须有 CPU，可以由 Verilog 状态机驱动。

对于当前目标，需要保留 MCLR 复位、TS 双向开漏握手、MGC3130 消息解析和 UART。IP 替换的是底层 I2C 位时序。上层仍需完成：

1. 配置分频及使能；50 MHz、100 kHz 按手册公式计算预分频值为 99。
2. 检测 TS 请求并在接收期间保持 TS 低。
3. 将 0x85 写入发送寄存器，发送 START + WRITE，检查完成与 RX ACK。
4. 连续读取，按消息头 Size 确定长度；中间字节发 ACK，最后一字节发 NACK + STOP。
5. 释放 TS，解析 X/Y/Z/gesture 并交给 UART。
6. 对无应答、操作超时等情况输出明确错误状态。

手册第 12 页的完整示例面向带存储地址的从机，包含先写存储地址的步骤。MGC3130 消息读取不能照搬这一段，应直接发送地址加读位。

官方参考工程的目标器件为 GW1N-LV4LQ144C6/I5，不应直接烧录其位流或复制管脚约束。应在当前 GW5A-25A 工程中从 IP Core Generator 的 `Soft IP Core → Interface and Interconnect → I2C MASTER` 生成 IP。

另外发现官方 **APB I2C**，提供主机/从机模式，但本项目无需 APB 总线，优先考虑 SRAM 接口的 I2C MASTER。该选择不等于 APB I2C 必须搭配 CPU。

## 来源与本地资料

- 官方页面：https://www.gowinsemi.com/en/support/ip_detail/2/
- 用户指南 IPUG504-1.5E：https://www.gowinsemi.com/upload/database_doc/2017/document/626a059480ac3.pdf
- 官方参考工程：https://www.gowinsemi.com/upload/database_doc/2018/document/66468901d2f35.zip
- 本地用户指南：`../Gowin_I2C_Master_Slave_User_Guide.pdf`
- 本地解压工程：`../Gowin_I2C_Master_refDesign/`
- 已安装 IP：`C:/Gowin/Gowin_V1.9.12.04_x64/IDE/ipcore/I2CMASTER/`

注意：官网简介仍提到 AXI4-Lite，但下载指南修订记录明确指出 1.3E 已由 AXI 改成 SRAM 接口。本机包装模块与指南均使用 SRAM 接口，应以实际生成模块和配套指南为准。
