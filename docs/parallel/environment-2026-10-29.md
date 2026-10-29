# 干净集成环境（2026-10-29）

本文件定义一个可复现、无历史残留的集成基线，供后续功能修复与时序收敛使用。
所有数字都来自本环境新跑的命令，不引用其它 worktree 的旧产物。

## 1. 环境清单

| 路径 | 分支 | HEAD | 角色 |
| --- | --- | --- | --- |
| `mgc3130_uart` | `feat/loop-event-store` | `5abe390` | 主工作区（共享基线，含 H0 harness），不在此工作 |
| **`.worktrees/v2-integration`** | **`work/v2-integration`** | **`338435c`** | **本文件定义的干净集成环境，后续工作都在这里** |
| `.worktrees/v2-integration-probe` | `work/v2-integration-probe` | `338435c` | 证据归档：保存 `ab_probe_1..5` 的 impl 产物，只读 |
| `.worktrees/v2-potts-resource` | `work/v2-potts-resource` | `4b47514` | B stream 交付分支 |
| `.worktrees/v2-voice-timing` | `work/v2-voice-timing` | `38302a1` | A stream 交付分支 |

新建方式（可复现）：

```powershell
cd 'C:\weizijian\documents\gowin fpga\mgc3130_uart'
git worktree add .worktrees/v2-integration -b work/v2-integration 338435c
```

干净环境的判据：`git status --short` 为空、无 `impl/` 目录、源码副本 17 MB。

## 2. 基线提交链

`work/v2-integration` 从共享基线 `5abe390` 线性叠加 5 个提交：

```text
338435c  perf(v2): replace the cursor constant multiplies with shift-add
3d6aac0  perf(v2): register the Potts event-stream read
0a47678  perf(v2): map the board-profile Potts dp table to DPB lanes
95eac88  perf(v2): bound the Potts event buffer by the DP segment limit
3d24f74  perf(v2): pipeline banked voice victim selection      (A stream)
5abe390  docs(v2): record H0 line-ending reproducibility fix   (base, H0 harness)
```

## 3. 自检（本环境实测，全部通过）

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| Python 全量 | `python -m unittest discover -s tools -p 'test_*.py'` | **175 tests OK**（8.7 s） |
| Potts top（H128）+ H32 DPB | `scripts/test_v2_top_potts.ps1` | `tb_mgc3130_v2_top_potts PASS busy_cycles=1951261 events=1`；`tb_v2_potts_commit_fsm PASS events=2 cycles=43158 ev0=t8/d24/n67 ev1=t0/d8/n57` |
| Cursor 逐帧回放 | `vsim work.tb_v2_cursor_replay` | `PASS rows=976 adjacent=A/B` |
| Cursor 冒烟 | `vsim work.tb_v2_cursor_filter` | `PASS` |
| 全路径综合 + P&R | `run_gowin_cli.ps1 ... -RunId clean_baseline_1` | `V2_FULLPATH_SYNTH_PASS` + `V2_FULLPATH_PNR_PASS` |

cursor 两个回归没有现成脚本，编译与运行方式：

```powershell
cd impl/ms_cursor
vlog -sv -work work rtl/v2_input_pkg.sv rtl/v2_touch_info_decoder.sv rtl/mgc3130_input_latch.sv `
  rtl/v2_input_calibration.sv rtl/v2_position_validity.sv rtl/v2_cursor_filter.sv `
  rtl/v2_cursor_filter_timed.sv sim/tb_v2_cursor_replay.sv sim/tb_v2_cursor_filter.sv
vsim -c -novopt work.tb_v2_cursor_replay -do 'run -all; quit -f'
vsim -c -novopt work.tb_v2_cursor_filter -do 'run -all; quit -f'
```

（向量路径是 `../../tools/testdata/...`，所以必须在 `impl/<子目录>` 下运行。）

## 4. 基线数字（`impl/v2_top_fullpath_clean_baseline_1/`）

| 指标 | 值 |
| --- | --- |
| 器件 | GW5A-LV25MG121NES |
| 实际 Fmax | **68.014 MHz**（约束 100 MHz，18 级） |
| setup 违规端点 / TNS | **3,125 / −7,704.703 ns** |
| hold 违规 | 0 |
| logic | **12,787 / 23,040（56%）**（10,272 LUT + 2,515 ALU） |
| Register | 7,839 / 23,280（34%） |
| **CLS** | **9,752 / 11,520（85%）** ← 真正的瓶颈 |
| BSRAM | 36 / 56（65%） |
| DSP | 16 / 28（58%） |
| I/O | 10 / 86 |
| 诊断位流 | `698D1843D99580CD0135FD5C96883F9176A05769101ABC4E6A04F20D397E2887`（**不可烧板**） |

与归档环境 `ab_probe_5_cursor_sa` 逐项一致（logic、Fmax、TNS、违规数全同），说明该
基线可复现；`impl/` 已加入 `.gitignore`，产物不入库。

## 5. 已知遗留（进入本环境时仍然存在）

1. **两条 `NL0002 swept`**：`v2_touch_info_decoder`（`mgc3130_input_latch` 内）与
   `v2_test_mode`（顶层）。它们不在网表里，H0 verifier 因此判 `BLOCKED`。
2. **I2S 输出无时序约束**：`mgc3130_v2_top_observable.sdc` 只有 `clk_50m` 与
   `uart_rx` false path，没有 BCLK/LRCK/DIN 的输出约束。
3. **patch / wavetable / vibrato 未接到声音路径**：`patch_active_value` 与
   `wt_read_sample` 只用于 CSR 读回，顶层把 `vibrato_hz_q8_8`/`vibrato_cents_q8_8`
   硬接 `16'd0`。
4. **FX 使能是编译期参数**（`FX_ENABLE != 0`），运行期不可改。
5. 时序距 100 MHz 还差 32%，瓶颈是布局拥塞（CLS 85%），不是逻辑深度。

## 6. 工作约定

- 所有 Gowin 运行必须带唯一 `-RunId`；harness 拒绝复用已存在的
  `impl/v2_top_fullpath_<RunId>` 目录。
- 不改其它 worktree；不 `git reset --hard`、不 `git clean`、不 push。
- `docs/v2-progress-log.md` 由主线程维护，各 stream 只写自己的报告。
- 每次提交必须带：命令、RunId、commit、六项数字（Fmax / setup 违规 / TNS /
  CLS / BSRAM / DSP）。
