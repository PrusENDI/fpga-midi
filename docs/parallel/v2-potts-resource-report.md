# v2-potts-resource 流报告（B stream）

状态：BLOCKED（门禁未通过；Potts 资源已降到 2,531，绝对 logic 24,391）
worktree：`C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-potts-resource`
branch：`work/v2-potts-resource`
base commit：`af447aa`（实际接入基线 `5abe390`，已含 H0 harness，未再 cherry-pick）
H0 commit：`9de0c0a`（共享 harness）
stream commit：本文件所在提交（`5719597` 之后的 DPB 提交）

## 命令

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
  -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path `
  -LicenseServer '106.55.34.119:10559' -RunId h0_b_potts_v4
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_top_potts.ps1
python -m unittest tools.test_v2_potts_reference -v
git diff --check
~~~

## 测试结果

- `tb_mgc3130_v2_top_potts PASS busy_cycles=1951261 events=1`（H128，寄存器路径）
- `tb_v2_potts_commit_fsm PASS events=2 cycles=43158 ev0=t8/d24/n67 ev1=t0/d8/n57`
  （H32，**DPB 路径**，板级 profile）
- `tb_v2_potts_commit PASS events=2 cycles=1995338`（H128 单元回归）
- Python Potts reference：5 tests OK；`git diff --check` 通过
- Potts 路径无 `NL0002 swept`

## 综合资源

| 构建 | logic | LUT | ALU | 结果 |
| --- | ---: | ---: | ---: | --- |
| 基线 Potts | 25,538 | 21,610 | 3,928 | RP0006，超 2,498 |
| 诊断（无 Potts 数据通路） | 21,860 | 18,607 | 3,253 | 综合通过 |
| 阶段一 EV_CAP | 25,309 | 21,381 | 3,928 | RP0006，超 2,269 |
| **阶段二 EV_CAP + DPB** | **24,391** | **20,430** | **3,961** | RP0006，超 **1,351** |

Potts 实际成本：3,678 → **2,531**（−31%，两阶段共 −1,147）。

## P&R / timing

无。所有 full-path 综合仍以 `RP0006` 终止，没有新网表、P&R 或位流，因此
Fmax/setup/hold 与 E2/5、CPU/SSPI regular_io、PR2017/PR2028 **均未评估**；
不引用任何旧产物。

## 修改文件

- `rtl/v2_potts_commit_fsm.sv`（EV_CAP；`HORIZON<=63` 时 dp 表改用两个 DPB lane，
  cell 变为 SEGMENT→RD1→RD2→COMMIT）
- `sim/tb_v2_potts_commit_fsm.sv`（新增：H32 板级 profile 的 DPB 路径回归，
  断言精确事件流）
- `scripts/test_v2_top_potts.ps1`（在 top 回归之后追加 H32 DPB 回归）
- `docs/v2-potts-h32-resource-note-2026-10-29.md`、本文件

未触碰 voice RTL、H0 harness 三个文件、A 的测试与报告、`docs/v2-progress-log.md`。

## 未解决问题

1. **RP0006 仍无法在 B 分支单独关闭**：24,391 对 23,040，差 1,351。无 Potts
   数据通路的设计本身已是 21,860（95%），`v2_voice_engine_banked` 占 14,952
   logic，属 A stream。
2. 剩余可回收项：`events` 9:1×96 组合读（改 DPB 需把 `event_data` 变寄存器输出
   并保持 stall 稳定，会牵动 top tb 时序）、`bp_s`/`bp_d` 变量读、32-bit 比较链。
   合计估计 400–600，仍不足以单独过门禁。
3. H32 board profile 的 P&R/timing 从未取得过证据（历史 2.616 MHz 属诊断）。

## 主线程下一步

1. 以 Potts 增量（3,678 → 2,531）作为 B 的验收量；资源门禁改在 A+B 合并分支上评估。
2. 按 A 的 voice 目标（≈6,000），合并后约 `24,391 − 9,000 ≈ 15,400`，余量充足。
3. 合并后跑一次 H0 full-path，取得首个真实逻辑资源 + P&R/timing 数字。

## Integration probe result (2026-10-29, A+B)

A throwaway worktree `.worktrees/v2-integration-probe` (branch
`work/v2-integration-probe`) was created from the shared base `5abe390` and the
three stream commits were cherry-picked in order:

~~~text
3d24f74  A: pipeline banked voice victim selection   (from 38302a1)
95eac88  B: bound the Potts event buffer by the DP segment limit
0a47678  B: map the board-profile Potts dp table to DPB lanes
~~~

The shared H0 harness then produced the first full-path synthesis **and P&R**
of this line: `V2_FULLPATH_SYNTH_PASS` and `V2_FULLPATH_PNR_PASS`, exit 0,
`device.cfg` carries `SSPI regular_io = true` and `CPU regular_io = true`, and
the run has no `PR2017`/`PR2028`.

| configuration | logic | FF | Fmax | worst slack | setup violations | TNS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| A+B (`ab_probe_1`) | 13,285 | 7,842 | 59.668 MHz | −6.759 ns | 2,974 | −8,846.8 ns |
| A+B + contour prefetch + ev_q (`ab_probe_2_pipe`) | 14,325 | 8,871 | 61.447 MHz | −6.274 ns | 3,198 | −10,301.3 ns |
| **A+B + ev_q only (`ab_probe_3_evonly`, accepted)** | **13,137** | 7,839 | **63.909 MHz** | **−5.647 ns** | 3,009 | **−8,021.7 ns** |

The contour prefetch variant was rejected: it bought 1.8 MHz while adding
1,040 logic and 1,029 registers, and it made TNS worse by 2,280 ns because the
extra registers increased placement congestion (the worst path is ~50% routing
at 86% CLS utilisation).

The accepted change registers the event-stream read (`ev_q`) so the 96-bit
`events[rd]` mux no longer feeds the voice bank write-data path combinationally.
It is the only variant that improves Fmax, worst slack and TNS together.

Bitstream `impl/v2_top_fullpath_ab_probe_3_evonly/impl/pnr/v2_top_fullpath.fs`
SHA-256 `AE2D79675EE7B5E5C73BD7869B4F2A932BECE7B489E9BBB33B88BF4A2B3E1B27`.
It is a diagnostic artifact: 3,009 setup endpoints still violate at 100 MHz, so
it must not be programmed as a final image.

Remaining blockers, measured:

- the worst path is still the Potts segment accumulate
  (`seg_t` → `err_acc`, 15.6 ns, 23 levels); the multiply→accumulate chain is
  ~8 ns by itself, so a contour prefetch alone cannot help;
- the verifier still reports `NL0002` for `v2_touch_info_decoder` and
  `v2_test_mode`; both are pre-existing (they appear in builds without the A or
  B changes) and need a main-lane ruling on whether they are required paths;
- 63.9 MHz against the 100 MHz gate is a congestion/placement problem, not a
  logic-depth problem: 24 levels with ~0.4 ns cell delay and ~0.66 ns per level
  end-to-end.