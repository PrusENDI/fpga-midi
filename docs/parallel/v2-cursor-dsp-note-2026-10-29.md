# Cursor filter DSP 归因与削减（2026-10-29）

本文件回答一个问题：V2 光标滤波（`rtl/v2_cursor_filter_timed.sv`）的 DSP 部分
能不能优化，优化后值多少。所有数字来自同一套共享 H0 full-path harness 的前后
对比，不跨构建引用。

## 1. 背景与目标

`2026-10-25` 计划 Task 4 的状态表写着：

> 顶层使用 `v2_cursor_filter_timed`……**旧 cursor 综合为 14 DSP；没有默认
> profile ≤4 DSP 的证据**

Task 4 的 final gate 是"默认 profile ≤4 DSP"。集成构建（A+B）里整片 DSP 是
18/28，其中 16 个站点来自 cursor，是唯一还没被处理过的大户。

## 2. 改动前的逐乘法器归因

从 `ab_probe_3_evonly` 的综合网表里逐个数 `v2_cursor_filter_timed` 的
`MULT27X36` 元件，并读它的 A/B 操作数：

| 元件 | A 操作数 | B 操作数 | 语义 |
| --- | --- | --- | --- |
| `n3148_s0` | 常量 57672（`ALPHA_HIGH_Q16 - ALPHA_LOW_Q16`） | `quotient_r[30:0]` | alpha 混合 |
| `mult_4867_s1` | 常量 7 | `depth_q` 邻近度项 | 邻近度 ×7 |
| `mult_6379_s1` | 常量 3 | `speed_q` | 速度 ×3 |
| `n40912_0_s` | `alpha_mz[16:0]` | 滤波中间量 | IIR X |
| `n41552_0_s` | `alpha_mz[16:0]` | 滤波中间量 | IIR Y |
| `n42192_0_s` | `alpha_mz[16:0]` | 滤波中间量 | IIR Z |
| `n69312_0_s` | `alpha_motion[16:0]` | 滤波中间量 | 运动 X |
| `n69952_0_s` | `alpha_motion[16:0]` | 滤波中间量 | 运动 Y |

即：**2 个小常量乘法（×7、×3）+ 1 个常量×变量（alpha 混合）+ 5 个真变量乘法
（IIR 系数）**。

## 3. 尝试一：把 ×65536 改成移位（零收益，保留）

`div_dividend <= (mz - Z_LOW) * 32'd65536;` 共 3 处（411/455/470 行），改成
`<< 16`。

实测（`ab_probe_4_cursor` 与 `ab_probe_3_evonly` 对比）：**资源与时序完全一致**
（13,137 logic、Fmax 63.909 MHz、TNS −8,021.715 ns、违规 3,009 全部逐位相同）。

结论：综合本来就把 2 的幂乘法折叠成连线，这一项没有优化空间。改动保留，因为它
把意图写明，且不改变任何硬件。

## 4. 尝试二：×7 / ×3 改成移位加法（有收益）

```systemverilog
// before
velocity_q <= 32'sd32768 + ((Q16_ONE - depth_q) * 32'd7 >>> 4);
velocity_control <= q16_u16(velocity_q + ((speed_q * 32'd3) >>> 4));

// after：先落到无符号 32 位临时量，再做移位加减，保证与原来的无符号逻辑右移
// 逐位一致
depth_term = Q16_ONE - depth_q;
depth_x7   = (depth_term << 3) - depth_term;
velocity_q <= 32'sd32768 + (depth_x7 >> 4);

speed_x3 = (speed_q[31:0] << 1) + speed_q[31:0];
velocity_control <= q16_u16(velocity_q + (speed_x3 >> 4));
```

关键点：原表达式里 `32'd7`/`32'd3` 是无符号字面量，因此整个乘法结果是无符号的，
`>>>` 实际执行逻辑右移。先赋给 `logic [31:0]` 临时量再做 `>>`，语义逐位相同。

### 实测（`ab_probe_5_cursor_sa`）

| 指标 | 改动前 | 改动后 | 变化 |
| --- | ---: | ---: | ---: |
| logic | 13,137（10,235 LUT + 2,902 ALU） | **12,787（10,272 LUT + 2,515 ALU）** | −350 |
| ALU | 2,902 | 2,515 | −387 |
| FF | 7,839 | 7,839 | 0 |
| CLS | 9,939（87%） | **9,752（85%）** | −187 |
| DSP（Gowin 站点） | 18/28（9 × MULT27X36） | **16/28（7 × MULT27X36 + 2 × MULTALU27X18）** | −2 |
| cursor 内 MULT 块 | 8 | **6** | −2 |
| 实际 Fmax | 63.909 MHz | **68.014 MHz** | **+4.105** |
| 最差 slack | −5.647 ns | **−4.703 ns** | +0.944 |
| setup 违规端点 | 3,009 | 3,125 | +116 |
| setup TNS | −8,021.715 ns | **−7,704.703 ns** | +317 |

违规端点数略增、TNS 与 Fmax 同时改善：布局噪声，但三点同向的部分（Fmax、最差
slack、TNS）都变好了。

改为 18 级逻辑后，最差路径已经从 Potts 的段累加转到
`u_potts/wr_* → u_voice/state_bank/.../DIB`（14.77 ns）。

## 5. 语义回归

| 检查 | 结果 |
| --- | --- |
| `tb_v2_cursor_replay`（976 帧 latch→calibration→validity→cursor 逐帧比对） | **PASS rows=976 adjacent=A/B** |
| `tb_v2_cursor_filter` | PASS |
| 改动前后 `div_dividend` 路径 | 仅 `<<16`，位等价 |

回放是逐帧比对 cursor 坐标、pitch、velocity、depth、状态、rebase、音频快照，所以
这两处移位改写没有改变任何一帧输出。

## 6. 剩下的 6 个乘法器

| 类别 | 数量 | 能否省 |
| --- | ---: | --- |
| IIR 系数（`alpha_mz` ×3、`alpha_motion` ×2） | 5 | 只能靠**共享一个乘法器 + 多周期复用** |
| alpha 混合（常量 57672 × `quotient_r`） | 1 | 常量乘法可换移位加法网络，但约 500–800 LUT，比 1 个 DSP 更贵 |

要把 cursor 压到 ≤4 站点（2 块），必须把 5 个 IIR 乘法串行化：该模块本来就是多周期
FSM（34 状态扫描、单帧 200 Hz），把 X/Y/Z 三个分量排到同一乘法器的连续三拍是可行
的，代价是每帧多几十拍（预算 500,000 拍/帧，完全够）。

## 7. 结论

- "DSP 不是瓶颈所以不用管"这个判断被实测推翻了一半：去掉 2 个 DSP 后 Fmax 涨了
  4.1 MHz，说明这些宽乘法器的周边布线和选择逻辑确实在拖时序。
- 但 68.0 MHz 距 100 MHz 仍差 32%，而且最差路径已经不在 cursor 上（转到 Potts→voice
  bank 的跨模块路径）。
- DSP 站点 16/28 仍高于计划 Task 4 的 ≤4 目标；剩余削减需要改结构（共享乘法器），
  不是改写法。

## 8. 复现

```powershell
# 全路径资源/时序（每次唯一 RunId，拒绝复用目录）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
  -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path `
  -LicenseServer '106.55.34.119:10559' -RunId ab_probe_5_cursor_sa

# cursor 逐帧回放（在 impl/ms_cursor 下运行，向量路径是 ../../tools/testdata/...）
vlog -sv -work work rtl/v2_input_pkg.sv rtl/v2_touch_info_decoder.sv rtl/mgc3130_input_latch.sv `
  rtl/v2_input_calibration.sv rtl/v2_position_validity.sv rtl/v2_cursor_filter.sv `
  rtl/v2_cursor_filter_timed.sv sim/tb_v2_cursor_replay.sv
vsim -c -novopt work.tb_v2_cursor_replay -do 'run -all; quit -f'
```
