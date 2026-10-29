# Potts H32 资源实测与 DPB 化（2026-10-29，B stream）

本文件记录 B stream 在共享 H0 full-path harness 下的资源归因与两阶段优化。
它不是验收报告；验收结论见 `docs/parallel/v2-potts-resource-report.md`。

## 1. 测量方法与基线

全部数字来自共享 H0 harness（`scripts/run_gowin_cli.ps1` +
`scripts/synth_v2_top_fullpath_20261029.tcl`），器件 `GW5A-LV25MG121NES`，
profile 固定为 `reader1,loop1,potts1,h32,fx1,fxlevel1`。

| 构建 | logic | LUT | ALU | 说明 |
| --- | ---: | ---: | ---: | --- |
| Potts 原样（基线） | 25,538 | 21,610 | 3,928 | `RP0006`，超 2,498 |
| 诊断：移除 Potts 数据通路 | 21,860 | 18,607 | 3,253 | 综合通过；含 contour 扫描 |
| **Potts 真实成本（基线）** | **3,678** | 3,003 | 675 | 基线 − 诊断 |
| 阶段一：EV_CAP | 25,309 | 21,381 | 3,928 | 超 2,269 |
| **阶段二：EV_CAP + DPB** | **24,391** | **20,430** | **3,961** | 超 1,351 |

两阶段合计回收 **1,147 logic**，Potts 成本从 3,678 降到 **2,531（−31%）**。

## 2. 阶段一：事件暂存 RAM 按 DP 段数上界定尺

`HORIZON` 个 tick、最短段长 `MIN_LENGTH` 的 DP 最多只能分出
`HORIZON/MIN_LENGTH+1` 段，不可能写满 `MAX_EVENTS=32`：

```systemverilog
localparam integer EV_CAP =
    ((HORIZON/MIN_LENGTH+1) < MAX_EVENTS) ? (HORIZON/MIN_LENGTH+1) : MAX_EVENTS;
logic [95:0] events[0:EV_CAP-1];
```

H32 → 9 项；H128 → 33 被截断为 32，与改动前完全相同。回收 229。

## 3. 阶段二：dp 表改用显式 GW5A DPB lane

原先 `logic [31:0] dp[0:HORIZON]` 被综合成寄存器堆，每拍需要两个 32-bit
变量下标读端口（`dp[s]`、`dp[e]`），这是 Potts 里最大的一块纯组合逻辑。

现在 `HORIZON<=63` 的 profile（即板级 H32）把 dp 放进两个 DPB lane：

- 地址形式沿用 `v2_voice_state_bank` 中已验证的
  `{4'b0, addr[5:0], 4'b0011}`；一个 DPB lane 只有 64 个字（行号 = addr），
  所以 H128（129 项）无法用同一块，保持寄存器实现；
- 一个 cell 因此变成 `SEGMENT → RD1 → RD2 → CELL_COMMIT`：RD1 读 `dp[s]`，
  RD2 锁存它并读 `dp[e]`，CELL_COMMIT 用锁存的 `dp[e]` 比较并通过端口 B 写回；
- `bp_s`/`bp_d` 写回条件与 dp 写回共用同一个 `commit_upd`，backtrace 与事件
  生成保持原样。

寄存器路径与 DPB 路径执行**同样的 cell 序列、同样的比较与 tie-break**，差别只有
dp 存放位置和 1 拍读延迟，所以两者输出逐位一致。

## 4. 行为证据

| 检查 | 结果 |
| --- | --- |
| `scripts/test_v2_top_potts.ps1`（top，H128，寄存器路径） | PASS，`busy_cycles=1951261 events=1` |
| `sim/tb_v2_potts_commit_fsm.sv`（H32，**DPB 路径**） | PASS，`events=2 cycles=43158`，事件流 `t8/d24/n67`、`t0/d8/n57` |
| `tb_v2_potts_commit`（H128 单元回归） | PASS，`events=2 cycles=1995338` |
| `python -m unittest tools.test_v2_potts_reference -v` | 5 tests OK |
| `git diff --check` | 通过 |

top 回放的 `busy_cycles` 从 1,868,572 增至 1,951,261，增量 82,689 正好等于
40,960 个 cell 各多出的 2 拍（RD1/RD2），事件数不变。

H32 回归的期望值不是猜的：`lambda_q16` 是 16 bit，`65536` 会被截断成 0，
所以两段零误差的常量段必然优于一段混合段；RTL 输出的
`(t8,d24,n67),(t0,d8,n57)` 与该预测一致，且 backtrace 先发末段。

## 5. 剩余缺口

Potts 现状 2,531。B 分支总 logic 24,391，距 23,040 还差 **1,351**。

剩余成本集中在：

1. `events` 的 9:1 × 96-bit 组合读多路（约 250–300 logic），改成 DPB 需要把
   `event_data` 变成寄存器输出并保持 stall 期间稳定，会牵动 top tb 的时序假设；
2. `bp_s`/`bp_d` 的变量下标读（各约 90 logic）；
3. 32-bit 加法/比较链与每 tick 的平方累加（ALU 3,961）。

即使把 1、2 都做掉，估计再回收 400–600，仍不足以单独关闭 23,040：

- 无 Potts 数据通路的设计已是 **21,860 / 23,040 = 95%**；
- 其中 `v2_voice_engine_banked` 占 14,952 logic（69.5%，A stream 负责）。

按 A 的 voice 目标（≈6,000 logic，省约 9,000），合并后全路径约为
`24,391 − 9,000 ≈ 15,400`，余量充足。B 的验收量应取 Potts 增量
（3,678 → 2,531），而不是 B 分支的绝对 logic。
