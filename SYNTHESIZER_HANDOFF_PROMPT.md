# 下一个对话的合成器开发交接提示词

请继续 `C:\weizijian\documents\gowin fpga\mgc3130_uart` 工程，目标是在已经实机验证的 MGC3130 I2C 读取链路后开发 FPGA 合成器模块。

当前事实：

1. 器件为 Tang Primer 25K，GW5A-LV25MG121NES，板载 50 MHz 时钟输入 E2。
2. MGC3130 使用官方 Gowin I2C MASTER IP，工程文件位于 `ip/gowin_i2c_master`；不要重新实现 I2C 位时序，也不要破坏已验证的 `mgc3130_reader.sv`。
3. MGC3130 实机读取已经成功。串口曾收到：`E=00`、`V` 持续增加、`F=0112`、`L=12`、`P=1`，并有非零 X/Y/Z。
4. `F=0x0112` 表示电极配置 `0x0100`、gesture `0x0002`、XYZ `0x0010`；`L=0x12` 表示 18 字节消息。解析已经按 Size 和 DataOutputConfigMask 动态计算偏移。
5. `mgc3130_reader` 输出接口为：`report_valid`（1 个 clk_50m 周期脉冲）、`xyz_valid`、`x_position[15:0]`、`y_position[15:0]`、`z_position[15:0]`、`gesture_code[7:0]`、`report_error`、`busy`。
6. 合成器必须直接连接这些并行输出，不能从 UART 回读。输入数据应在 `report_valid && xyz_valid && !report_error` 时锁存。
7. 当前 UART 是约 20 ms 一次的 ASCII 调试快照；保留它用于调试和轨迹采集，但不要让它成为合成器数据路径。
8. 最新可烧录文件由 `scripts/build.tcl` 生成到 `bitstream/mgc3130_uart_official_i2c_gao.fs`。最近一次综合/布局布线 setup 和 hold 违例均为 0；50 MHz 域 Fmax 报告约 73.991 MHz。

请按以下顺序推进：

1. 先阅读 `mgc3130_uart/README.md`、`mgc3130_uart/rtl/mgc3130_reader.sv`、`mgc3130_uart/rtl/mgc3130_uart_top.sv` 和 `MGC3130_FPGA_REAL_HARDWARE_IMPLEMENTATION.md`，确认接口和工程约束。
2. 先提出一个简短设计：输入锁存层、坐标滤波/中心偏置、gesture 事件锁存与去重、坐标到频率/音量映射、合成器类型（DDS/相位累加器/波表）和音频输出接口。默认优先使用简单、可综合、易实机验证的单声道 DDS 或 PWM 方案，除非工程中已有明确的 DAC/I2S 接口。
3. 不要修改 I2C、MCLR、TS 或现有管脚约束，除非发现会阻碍合成器接入的明确问题。
4. 明确所有数值格式：坐标是否无符号、中心点、缩放范围、频率范围、相位累加器位宽、PWM/I2S 采样率，以及 gesture 如何触发音符或波形变化。
5. 编写合成器模块和必要的输入锁存模块，接入顶层；保持 Verilog-2001/Gowin 可综合语法，避免多个 always 块驱动同一信号。
6. 给 UART 调试行增加合成器关键状态（例如锁存后的坐标、频率、音符或 output_valid），但不要删除现有 I2C 诊断字段。
7. 使用高云 `gw_sh.exe` 执行 `mgc3130_uart/scripts/build.tcl`，完成综合和 Place & Route；检查第一条错误、setup/hold 违例和生成的 `.fs` 文件。
8. 最后说明哪些行为已经由编译验证，哪些还需要板上听音或示波器验证。不要声称音频输出已验证，除非有实机证据。

实现时优先保证：I2C 链路不回归、输入脉冲不丢失、坐标变化能稳定改变合成参数、gesture 不因连续报告重复触发，以及输出接口和当前开发板实际硬件一致。

## 2026-10-12 轨迹采集进度

今天完成了真实 MGC3130 坐标采集链路的诊断和提速：

- `tools/capture_mgc3130.py` 现在会生成 CSV、HEX、JSON 和 `.raw.log`，并记录过滤原因；默认只保存 `P=1 && E=00 && K=0` 的有效 XYZ 报告。
- 发现板上曾运行 `AUDIO_STREAM=1` 的旧 bitstream，UART 输出的是以 `A5 5A` 开头的二进制 PCM，因此终端出现乱码。顶层默认值已恢复为 `AUDIO_STREAM=0`，用于 ASCII 调试/采集。
- `rtl/mgc3130_uart_top.sv` 的 `STATUS_PERIOD` 已从 50,000,000 改为 1,000,000 个 50 MHz 时钟，即约 20 ms 一条状态报告。85 字符报告在 115200 8N1 下约需 7.4 ms，低于报告周期。
- `tools/capture_fast_01.json` 显示：约 30 秒采集得到 968 条有效报告，平均有效间隔约 30.4 ms；X 范围 `0000..FFFF`，Y 范围 `0000..DC7A`，Z 范围 `0000..FFFF`。
- 对应回放文件为 `tools/capture_fast_01.hex`，每行格式为 `X[63:48] Y[47:32] Z[31:16] G[15:8] reserved[7:1] VALID[0]`，可由 `sim/tb_mgc3130_pattern_input_replay.v` 的 `$readmemh` 加载。
- 该采集已经足够开始调整 X 时间格、Y 音高分区、坐标确认帧、失联保护和 Z 力度映射；不要再用每秒一条的旧采集文件估计防抖参数。

重新修改 RTL 后必须重新执行 Gowin 构建并下载新的 `bitstream/mgc3130_uart_official_i2c_gao.fs`；仅修改源码不会改变板上运行的 bitstream。当前环境未在 PATH 中发现 `gw_sh.exe`，因此本次仅完成源码和采集数据验证，未宣称重新综合通过。
