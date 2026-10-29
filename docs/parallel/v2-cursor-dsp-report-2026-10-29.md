# V2 cursor DSP sharing candidate report (2026-10-29)

状态：NEEDS_REVIEW
worktree：`C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-cursor-dsp`
branch：`work/v2-cursor-dsp`
base commit：`ec10de4`
H0 commit：未运行（主线程协调 license）
stream commit：见本报告对应提交

## 候选

`rtl/v2_cursor_filter_timed.sv` 的 5 个变量系数乘法（IIR X/Y/Z 和 motion X/Y）现在共享一个 32x32 有符号乘法网。FSM 状态选择 `mul_a/mul_b`，每个原有乘法状态在同一拍捕获 `mul_product`。状态数量、帧处理顺序、FIFO、divider、`sample_ce` 音频快照契约均未改动；因此预计吞吐和输出拍位置保持不变。相比“增加多周期乘法器调度状态”的方案，此最小候选不增加帧延迟，代价是操作数 mux 和控制扇出。

预期资源收益是从 cursor 的 5 个变量乘法器降为 1 个（若 Gowin 综合识别该共享网），即约减少 4 个 `MULT27X36` 站点；最终 DSP 仍可能包含 alpha 常量乘法及其它模块。实际 Gowin 综合/P&R 数字待 H0 license 窗口执行，不能以预期替代实测。

## 基线与验证

基线在修改前运行 cursor replay：

```text
vlog -sv -work work rtl/v2_input_pkg.sv rtl/v2_touch_info_decoder.sv rtl/mgc3130_input_latch.sv rtl/v2_input_calibration.sv rtl/v2_position_validity.sv rtl/v2_cursor_filter.sv rtl/v2_cursor_filter_timed.sv sim/tb_v2_cursor_replay.sv
vsim -c -novopt work.tb_v2_cursor_replay -do 'run -all; quit -f'
tb_v2_cursor_replay PASS rows=976 adjacent=A/B
```

候选后新鲜 ModelSim 验证：

- `tb_v2_cursor_replay PASS rows=976 adjacent=A/B`（同一编译/运行命令）
- `tb_v2_cursor_filter_timed PASS`
- `tb_v2_cursor_filter PASS`
- `git diff --check` 通过

## 综合/P&R

本 stream 暂不启动 full-path Gowin P&R；没有新的资源、Fmax、TNS 或 NL0002 证据。主线程应在 H0 harness/license 可用时运行唯一 RunId 的 full-path acceptance profile，并确认 multiplier cell 归因及 cursor DSP 数量。

## 修改文件

- `rtl/v2_cursor_filter_timed.sv`
- 本报告

## 未解决问题

Gowin 是否将共享乘法网映射为单一 DSP、mux 是否影响时序，仍需新鲜综合/P&R 结果确认。若工具复制乘法器，下一候选应增加显式两阶段 operand/result 调度或 vendor DSP primitive。

## 主线程下一步

审查 diff 后 cherry-pick 本 stream commit；在 H0 license 可用时运行 full-path harness，采集资源/timing 机器检查，再决定是否保留该候选。
