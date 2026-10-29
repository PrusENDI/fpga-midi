# v2-potts-resource 流报告（B stream）

状态：BLOCKED
worktree：`C:\weizijian\documents\gowin fpga\mgc3130_uart\.worktrees\v2-potts-resource`
branch：`work/v2-potts-resource`
base commit：`af447aa`（实际接入基线为 `5abe390`，已含 H0 harness，未再 cherry-pick）
H0 commit：`9de0c0a`（共享 harness）；工作树 HEAD 已包含，无重复 cherry-pick
stream commit：见本提交自身 hash

## 命令

~~~powershell
# 基线（未改动 Potts）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
  -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path `
  -LicenseServer '106.55.34.119:10559' -RunId h0_b_diag_wrapper_20261029

# 本提交
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
  -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path `
  -LicenseServer '106.55.34.119:10559' -RunId h0_b_potts_v3

# 回归
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_top_potts.ps1
python -m unittest tools.test_v2_potts_reference -v
git diff --check
~~~

## 测试结果

- `tb_mgc3130_v2_top_potts PASS busy_cycles=1868572 events=1`（与改动前逐位相同）
- `tb_v2_potts_commit PASS events=2 cycles=1912649`（H128 单元回归）
- Python Potts reference：5 tests OK
- `git diff --check`：通过
- 未发现 `NL0002 swept` 涉及 Potts 路径

## 综合资源

| 构建 | logic | LUT | ALU | FF | DPB | DSP | 结果 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 基线 Potts | 25,538 | 21,610 | 3,928 | — | — | — | RP0006，超 2,498 |
| 诊断（移除 Potts 数据通路） | 21,860 | 18,607 | 3,253 | 6,317 | 33 | 9 | 综合通过 |
| 本提交 | 25,309 | 21,381 | 3,928 | — | — | — | RP0006，超 2,269 |

Potts 实际成本 = 25,538 − 21,860 = **3,678 logic**；本提交回收 **229 logic**。

## P&R / timing

无。两次 full-path 综合均以 `RP0006` 终止，没有新网表、P&R 或位流；因此
Fmax/setup/hold 与 E2/5、CPU/SSPI regular_io、PR2017/PR2028 **均未评估**。
不引用任何旧产物。

## 修改文件

- `rtl/v2_potts_commit_fsm.sv`（事件暂存 RAM 深度按 DP 段数上界 `EV_CAP` 定尺）
- `docs/v2-potts-h32-resource-note-2026-10-29.md`（新增，实测与门禁算术）
- `docs/parallel/v2-potts-resource-report.md`（本文件，新增）

未触碰 voice RTL、H0 harness 三个文件、A 的测试与报告、`docs/v2-progress-log.md`。

## 未解决问题

1. **RP0006 无法在 B 分支单独关闭。** 不含 Potts 数据通路的设计已是
   21,860/23,040 = 95%，即 Potts 必须 ≤1,180（现状 3,449）。主因是
   `v2_voice_engine_banked` 占 14,952 logic（69.5%，A stream 负责）。
2. Potts 剩余成本集中在 `dp` 两个 32-bit 变量下标读端口、32-bit 加法/比较链和
   每 tick 的平方累加；需要显式 DPB（同步读、单写口）+ 读-算-写三拍才能再回收
   约 600–900 logic，仍不足以单独过门禁。
3. H32 board profile 下的 P&R/timing 从未取得过证据（历史 2.616 MHz 属诊断）。

## 主线程下一步

1. 把 B 的资源门禁改为"在 A+B 合并分支上评估"，或用 Potts 增量（3,678 → 3,449）
   作为 B 的验收量；按 A 的 voice 目标（≈6,000 logic），合并后约 16,300，余量充足。
2. 若仍要求 B 分支单独过 23,040，需先合并 A 的 voice 修复，否则该门禁在数学上
   不可达。
3. 合并后再跑一次 H0 full-path，得到首个真实的逻辑资源 + P&R/timing 数字。
