# Potts H32 资源实测与事件容量上界（2026-10-29，B stream）

本文件记录 B stream 在共享 H0 full-path harness 下的第一次资源归因和优化结果。
它不是验收报告；验收结论见 `docs/parallel/v2-potts-resource-report.md`。

## 1. 测量方法与基线

全部数字来自共享 H0 harness（`scripts/run_gowin_cli.ps1` +
`scripts/synth_v2_top_fullpath_20261029.tcl`），器件 `GW5A-LV25MG121NES`，
profile 固定为 `reader1,loop1,potts1,h32,fx1,fxlevel1`。

| 构建 | logic | LUT | ALU | 说明 |
| --- | ---: | ---: | ---: | --- |
| Potts 原样（基线） | 25,538 | 21,610 | 3,928 | `RP0006`，超 2,498 |
| Potts 数据通路临时移除（诊断） | 21,860 | 18,607 | 3,253 | 综合通过；含 contour 扫描 |
| **Potts 真实成本** | **3,678** | 3,003 | 675 | 基线 − 诊断 |
| 本提交（EV_CAP） | 25,309 | 21,381 | 3,928 | `RP0006`，超 2,269 |

诊断构建只用于归因：它保留端口和一次 contour 顺序扫描，删除 dp/backtrace/事件
数据通路，因此 21,860 是"没有 Potts 数据通路"的下界，不是可用设计。

## 2. 本提交的改动

`rtl/v2_potts_commit_fsm.sv`：事件暂存 RAM 的深度由 DP 可产生的上界决定，而不是
固定 `MAX_EVENTS`。

```systemverilog
localparam integer EV_CAP =
    ((HORIZON/MIN_LENGTH+1) < MAX_EVENTS) ? (HORIZON/MIN_LENGTH+1) : MAX_EVENTS;
logic [95:0] events[0:EV_CAP-1];
```

理由：`HORIZON` 个 tick、最短段长 `MIN_LENGTH` 的 DP，最多只能分割出
`HORIZON/MIN_LENGTH + 1` 段，不可能写满 32 项。

- `HORIZON=32, MIN_LENGTH=4` → `EV_CAP=9`（板级 profile）；
- `HORIZON=128, MIN_LENGTH=4` → `33`，被 `MAX_EVENTS=32` 截断，**与改动前完全相同**。

事件顺序、96-bit 布局、backtrace、event_count、overflow、progress、tie-break 和
饱和逻辑均未改动；`overflow` 只在写入数超过容量时置位，而该条件在 H32 下不可达。

## 3. 行为等价证据

| 检查 | 结果 |
| --- | --- |
| `scripts/test_v2_top_potts.ps1` | PASS，`busy_cycles=1868572 events=1`（与改动前逐位相同） |
| `tb_v2_potts_commit`（H128 单元回归） | PASS，`events=2 cycles=1912649` |
| `python -m unittest tools.test_v2_potts_reference -v` | 5 tests OK |
| `git diff --check` | 通过 |

top 级 testbench 注入的 NOTE_ON 全部落在 tick < 32 内，因此 H32 与 H128 在该
contour 上产生同一事件序列，一次 H128 回放同时覆盖 H32 的共享前缀。

## 4. 资源结论

EV_CAP 只回收 **229 logic**（25,538 → 25,309）。Gowin 已经把 32:1 读多路选择
压得较紧，事件 RAM 不是主要成本。

主要成本仍在：

1. `dp[0:HORIZON]` 的两个 32-bit 变量下标读端口（`dp[s]`、`dp[e]`）；
2. 32-bit 加法/比较链（err、cost、dp）；
3. 每段 tick 的 `(contour-note)²` 累加。

这三项需要显式 DPB（同步读、单写口）加"读—算—写"三拍时序才能回收，估计
600–900 logic，但仍不足以在 B 分支单独关闭 23,040 门禁，原因见下节。

## 5. 门禁算术

- 无 Potts 数据通路下界：**21,860 / 23,040 = 95%**。
- 因此 B 分支要在 23,040 内，Potts 必须 ≤ **1,180**（现状 3,449，需再砍 66%）。
- 其中的大头是 voice engine：旧成功 P&R 网表（`impl/v2_top_board_20261026`，无 Potts）
  逐模块统计为 `v2_voice_engine_banked = 14,952 logic (69.5%)`。

结论：**RP0006 不能在 B 分支单独关闭**，它由 A stream 的 voice 修复决定。
按 A 的既有归因（voice 目标 ≈6,000 logic，省约 9,000），合并后全路径约为
`25,309 − 9,000 ≈ 16,300`，余量充足。B 的价值应以其 Potts 增量为度量，而不是
以 B 分支的绝对 logic 为度量。
