# Cursor DSP sharing candidate report (2026-10-29)

状态：资源候选 VERIFIED；100 MHz acceptance BLOCKED。
worktree：`C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-cursor-dsp`
branch：`work/v2-cursor-dsp`
base commit：`ec10de4`
RTL commit：`2c6aea8`；clean H0 source：`cd381e9e5e1e003764bff0805377740cd9904716`。

## 候选与语义复查

`rtl/v2_cursor_filter_timed.sv` 将 IIR X/Y/Z 和 motion X/Y 五个变量系数乘法收敛为一个按 FSM 状态选择操作数的乘法网。状态、帧延迟、FIFO、divider 和 `sample_ce` 快照逻辑不变；代价是操作数 mux 与控制扇出。

`dx_q/dy_q/dz_q`、`alpha_mz/alpha_motion`、`mul_a/mul_b` 均为 signed32，无切片或缩窄；原表达式与共享表达式都是 signed32×signed32，赋值上下文为 signed64，后续 `>>>16` 不变。六处捕获 X/Y/Z/Z_ONLY/motion PREP/Y 都有对应 mux 分支。`ST_MOTION_X` 为原有不可达枚举。

## 功能验证

早期 `tb_v2_cursor_replay PASS rows=976 adjacent=A/B` 与 `tb_v2_cursor_filter PASS` 仅验证 scalar reference，不能证明 timed 修改。`tb_v2_cursor_filter_timed PASS` 是 timed smoke。

主线程使用 resource 分支 `3f62a8a` 的独立 timed 双 DUT 脚本，固定提取基线 `ec10de4` 与候选 `cd381e9`，新鲜实跑：

```powershell
# 在 .worktrees/v2-cursor-resource 中执行
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_cursor_timed.ps1 -Baseline ec10de4 -CandidateRef cd381e9 -ExpectSameLatency
```

日志：`../v2-cursor-resource/impl/cursor_timed_03369de1362e4cdea0ae143539e44964/replay.log`。

```text
PASS rows=976 adjacent=4 frames=983/983
replay_max_cycles=127/127 burst_max_cycles=296/296
audio_checks=1938 baseline_scalar_differences=893
sample_window_differences=0 same_latency_checks=983
```

该检查覆盖完整帧输出和 FIFO sequence/timestamp、独立 48 kHz 音频快照 oracle、4 个相邻 burst、发布/sample 边沿，以及 983 帧逐帧同延迟。893 个 scalar 差异是基线 timed/reference 差异统计，不是候选与 timed 基线不一致。未覆盖满 8 深 FIFO、所有 reason/degraded 标志、处理中复位或任意 signed32 极值；因此是所测轨迹等价证据。

## 新鲜 H0 full-path 证据

由主线程执行，目录 `impl/v2_top_fullpath_cursor_dsp_cd381e9_1`；manifest source 为 clean `cd381e9`，dirty_state 为空。器件 `GW5A-LV25MG121NES`，Gowin `V1.9.12.04 (64-bit)`（PnR report 确认；manifest gw_sh_version 字段为 null）。profile 为真实 reader、Loop、Potts H32、32×2 voice、FX enable1/level1、CPU/SSPI GPIO。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path -LicenseServer '106.55.34.119:10559' -RunId cursor_dsp_cd381e9_1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_v2_fullpath_run.ps1 -RunDir impl/v2_top_fullpath_cursor_dsp_cd381e9_1 -Acceptance
```

Wrapper exit 0，acceptance verifier exit 1 / BLOCKED。touch decoder NL0002 inline 被接受；阻塞项为 3144 个 setup violation 及 Fmax 低于 100 MHz。

| 指标 | clean cd381e9 H0 |
|---|---:|
| Logic | 15163/23040 (12633 LUT + 2530 ALU) |
| Registers | 9123 (9118 logic FF + 5 I/O FF) |
| CLS | 10346/11520 |
| BSRAM | 36/56 |
| 物理 DSP 站点 | 8/28 |
| 全设计乘法元件 | 3 MULT27X36 + 2 MULTALU27X18 |
| Cursor MULT27X36 元件 | 2 |
| Fmax raw / verifier rounded | 68.671 / 68.67 MHz |
| Setup / hold violations | 3144 / 0 |
| Setup TNS / worst slack | -7815.501 / -4.562 ns |

综合网表 cursor 的两个 `MULT27X36` 为 `n3459_s0`（alpha 常量乘法）与 `mul_product2_0_s`（共享变量乘法）。旧 `tm_serial_1` 的 cursor 有 6 个乘法元件，因此变量乘法 5→1 的结构归因成立；乘法元件数量与物理 DSP 站点数量分别计数。

历史 `tm_serial_1` 为 15302 logic、8996 registers、10250 CLS、16 DSP、71.342 MHz。其 manifest 是 `85c2f89` 加 3 个 dirty 文件（serial RTL 后由 `fec4008` 包含），不是 clean `ec10de4` 基线。当前与该历史 run 的数值比较只能作为背景，不能确定地将 Fmax 降低、CLS/FF 变化归因于本候选。严格量化前后效应需匹配 clean source/profile 的新鲜基线。

证据文件：run 内 `harness-manifest.json`、`harness-verification.json`、`impl/gwsynthesis/v2_top_fullpath.vg`、`impl/pnr/v2_top_fullpath.rpt.txt`、`impl/pnr/v2_top_fullpath_tr_content.html`。

生成的 `impl/pnr/v2_top_fullpath.fs` SHA256：

```text
4B86CC0FC6012AB6FE7F7B028602E302828D686147CE998FEA3A3783C559077A
```

此 hash 仅标识本次失败 timing gate 的构建产物，不代表板级验收或可发布 bitstream。

## 风险与建议

共享变量乘法的资源目标已被网表归因和 8/28 物理 DSP 报表支持；建议保留为 DSP 资源备选，并以匹配 clean 基线及后续合并构建评估最终取舍。当前 Fmax 68.671 MHz，100 MHz gate 明确 BLOCKED，不能宣布 timing closure 或板级就绪。操作数 mux/控制布线仍可能影响时序，但现有历史对照不足以确定其因果贡献。

本次只更新报告，未改变 RTL、tests、H0 harness 或主进度台账，未启动新 Gowin run。
