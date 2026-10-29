# V2 cursor DSP sharing candidate report (2026-10-29)

状态：NEEDS_REVIEW
worktree：`C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-cursor-dsp`
branch：`work/v2-cursor-dsp`
base commit：`ec10de4`
H0 commit：未运行（主线程协调 license）
stream commit：见本报告对应提交

## 候选

`rtl/v2_cursor_filter_timed.sv` 的 5 个变量系数乘法（IIR X/Y/Z 和 motion X/Y）现在共享一个 32x32 有符号乘法网。FSM 状态选择 `mul_a/mul_b`，每个原有乘法状态在同一拍捕获 `mul_product`。状态数量、帧处理顺序、FIFO、divider、`sample_ce` 音频快照契约均未改动；因此预计吞吐和输出拍位置保持不变。相比“增加多周期乘法器调度状态”的方案，此最小候选不增加帧延迟，代价是操作数 mux 和控制扇出。

预期资源收益是从 cursor 的 5 个变量乘法器降为 1 个（若 Gowin 综合识别该共享网），预期减少 4 个乘法功能块。`MULT27X36` 元件/功能块数量与 Gowin 报表物理 DSP 站点数量不是同一计数，本文不将两者等同；最终物理站点数还取决于器件映射、alpha 常量乘法及其它模块。实际 Gowin 综合/P&R 数字待 H0 license 窗口执行，不能以预期替代实测。

## 基线与验证

基线在修改前运行 reference cursor replay（`tb_v2_cursor_replay` 仅实例化 `v2_cursor_filter`，没有实例化 timed DUT）：

```text
vlog -sv -work work rtl/v2_input_pkg.sv rtl/v2_touch_info_decoder.sv rtl/mgc3130_input_latch.sv rtl/v2_input_calibration.sv rtl/v2_position_validity.sv rtl/v2_cursor_filter.sv rtl/v2_cursor_filter_timed.sv sim/tb_v2_cursor_replay.sv
vsim -c -novopt work.tb_v2_cursor_replay -do 'run -all; quit -f'
tb_v2_cursor_replay PASS rows=976 adjacent=A/B
```

候选后新鲜 ModelSim 验证：

- Reference：`tb_v2_cursor_replay PASS rows=976 adjacent=A/B`（同一编译/运行命令）；此结果不覆盖本次 timed RTL 修改，不能用作 timed 逐帧等价证据。
- Timed：`tb_v2_cursor_filter_timed PASS`，仅为有限 smoke 场景覆盖。
- Reference：`tb_v2_cursor_filter PASS`。
- `git diff --check` 通过

## 有符号位宽与状态调用复查

- `dx_q/dy_q/dz_q`、`alpha_mz/alpha_motion`、新 `mul_a/mul_b` 均为 `logic signed [31:0]`。mux 是同宽有符号赋值，没有缩窄、切片或无符号字面量参与。
- 原表达式与共享表达式均为 `$signed(32-bit operand) * $signed(32-bit operand)`，目标均为 signed 64-bit；SystemVerilog 赋值上下文将乘法扩展到 64-bit，保留完整有符号 32x32 乘积。后续 `product_x/y/z >>> 16` 不变。
- 消费状态完整映射：`ST_MUL_X`→dx/alpha_mz，`ST_MUL_Y`→dy/alpha_mz，`ST_MUL_Z`和`ST_MUL_Z_ONLY`→dz/alpha_mz，`ST_MOTION_PREP`→dx/alpha_motion，`ST_MOTION_Y`→dy/alpha_motion。全部六处产品捕获都有对应 mux 分支。
- `ST_MOTION_X` 是原有未使用枚举值，无状态跳转指向它，也无乘法捕获。共享逻辑未改变这点。
- 每个乘法状态前原有寄存器准备/更新边界不变，捕获使用该状态期间的 mux 输出；没有新增时钟边界或状态。该静态复查支持同拍语义，但不替代 timed 全回放。

Timed 976-frame replay、48 kHz `sample_ce` 与吞吐验证等待主线程提供新的 timed test/script；目前不能声称 timed 逐帧等价或整个契约已由回归验证。

## 综合/P&R

本 stream 暂不启动 full-path Gowin P&R；没有新的资源、Fmax、TNS 或 NL0002 证据。主线程应在 H0 harness/license 可用时运行唯一 RunId 的 full-path acceptance profile，并确认 multiplier cell 归因及 cursor DSP 数量。

## 修改文件

- `rtl/v2_cursor_filter_timed.sv`
- 本报告

## 未解决问题

Gowin 是否将共享乘法网映射为单一乘法功能块、实际占用多少物理 DSP 站点、mux 是否影响时序，仍需新鲜综合/P&R 结果确认。若工具复制乘法器，下一候选应增加显式两阶段 operand/result 调度或 vendor DSP primitive。

## 主线程下一步

先使用主线程提供的新 timed replay/script 验证 976-frame 逐帧结果、音频快照和吞吐；再在 H0 license 可用时运行 full-path harness，分别采集乘法元件归因、物理 DSP 站点和 timing 机器检查，再决定是否保留该候选。
