# V2 完整设计与当前进度缺口审查（2026-10-29）

当前状态：**A+B 已在同一 full-path 链路完成联合综合和 P&R，诊断配置的逻辑资源门槛已过；完整功能、100 MHz 时序、I2S 接口和板级验收均未关闭。** 后续应先修复会改变数据流的功能缺口，再对确定的生产数据流收敛时序。模块被实例化、专项测试通过和工具生成位流，分别有价值，但不足以证明完整设计验收通过。

## 1. 范围与证据边界

- 依据：`docs/v2-fpga-contract-2026-10-25.md`、`docs/superpowers/plans/2026-10-25-v2-fpga-full-pipeline-implementation.md`、`docs/superpowers/plans/2026-10-29-v2-timing-optimization.md`，并对照 system/voice/synth 设计说明。
- RTL 审查基准：**`338435cc59d12bb77e549b68006afc9e63d95b97`**。下文 `rtl/`、`sim/`、`scripts/` 行号针对该集成提交，不能以主工作区旧 RTL 代替。
- 集成工作区 `.worktrees/v2-integration` / `work/v2-integration`；审查时 HEAD `b0f6a40` 在上述提交上增加环境说明。历史实验归档在 `.worktrees/v2-integration-probe`。
- 后续复查时曾观察到 `rtl/mgc3130_input_latch.sv`、`rtl/mgc3130_v2_top.sv` 两处未提交的 `keep_hierarchy` 实验修改，本轮未干预。完成前再次复查，另一工作流已回退属性并提交诊断文档 **`e76ccde`**；其工作区干净，且 `git diff --quiet 338435c e76ccde -- rtl` 返回 0，RTL 基准未变。
- 本轮仅审查、验证和更新文档，未修改 RTL，未新跑耗时 Gowin P&R。另一工作流的 `nl0002_keep_1` 实验未消除两条警告，不能算修复；原 clean-baseline 仍是本报告的时序证据。

## 2. 已经完成到哪里

已核对的提交链：

```text
5abe390  H0 shared base
3d24f74  A: registered voice victim selection (from 38302a1)
95eac88  B: bound Potts event buffer
0a47678  B: H32 DP table in DPB lanes
3d6aac0  Potts registered event-stream read
338435c  cursor constant multiply shift-add
b0f6a40  clean integration environment documentation
e76ccde  concurrent NL0002 diagnosis documentation (RTL unchanged)
```

| 计划项 | 当前结论 | 剩余门槛 |
| --- | --- | --- |
| H0 共享 harness | 已实现、A/B 共用，并成功跑通 | verifier 需保留合法内联证据并继续阻断真实删除 |
| Task 1 受控 sweep | 有连续实验 | 统一脚本、归因表、版本化 variant/profile 未交付 |
| Task 2 / A voice | 专项仿真通过，进入联合 P&R | 当前 A 单独 voice P&R 归因仍缺；100 MHz gate 未过 |
| Task 3 / B Potts | 功能专项和资源优化有证据，A+B 可放入器件 | H32 全圈映射、写回、不中断播放未闭环 |
| Task 4 前端/控制优化 | ev_q、cursor 常量乘法优化已做 | 按正确数据流和最新关键路径继续 |
| Task 5 最终 P&R | 有干净提交的诊断 P&R，不能再写缺 clean rerun | 最终配置、功能可达、100 MHz、零 setup/hold |
| Task 6 板级验收 | 当前最终配置尚无验收证据 | UART/I2S/声音/延迟/故障恢复实测 |

B 独立分支曾为 24,391 logic / RP0006，不能继续用它否定已完成的联合资源结果；联合配置可放入器件也不证明完整功能闭环。原计划未勾选步骤不宜机械换算为完成百分比。

### 干净联合基线

目录：`.worktrees/v2-integration/impl/v2_top_fullpath_clean_baseline_1/`。
manifest：source `338435c`，`dirty_state=[]`，wrapper exit 0；UTC 2026-10-29 08:01:55 至 08:12:50。工具安装目录为 `C:/Gowin/Gowin_V1.9.12.04_x64`，但 `gw_sh_version=null`，版本证据仍需补足。

| 指标 | 原始报告值 |
| --- | ---: |
| 实际 Fmax | **68.013 MHz** |
| 目标 | 100 MHz / 10 ns |
| 最差 setup slack | **−4.703 ns** |
| setup 违规端点 / TNS | **3,125 / −7,704.703 ns** |
| hold 违规端点 | 0 |
| Logic | **12,787 / 23,040**（10,272 LUT + 2,515 ALU） |
| Registers | 7,839 |
| CLS | **9,752 / 11,520（85%）** |
| BSRAM | 36 / 56（35 DPB + 1 SDPB） |
| DSP 站点 | 16 / 28 |
| I/O | 10 / 86 |

配置为 reader=1、RAM=1、Potts=1/H32、FX=1/level1、preserve_loop=1、preserve_potts=1。E2/5 正确；`device.cfg` 的 CPU、SSPI 均为 `regular_io=true`，无 PR2017/PR2028。原始报告为 `impl/pnr/v2_top_fullpath_tr_content.html`、`impl/pnr/v2_top_fullpath.rpt.txt`。

诊断 `.fs` SHA-256：`698D1843D99580CD0135FD5C96883F9176A05769101ABC4E6A04F20D397E2887`。用于追溯，**不是最终验收的烧录推荐**。

## 3. 完整功能中的阻塞缺口

以下先列源码确定的连接/语义缺口；尚未做反例仿真的运行时问题明确标为风险。

### F1 — 音乐时间基准与全圈 H32 映射

契约第 10–12 行规定一圈 **128 ticks、4 ticks/beat、BPM 60–240、默认 120**。每轨 **32 个事件槽**是容量，不等于 32 个时间点。

- LIVE tick、recorder event_tick、scheduler loop_tick 仍使用 `sample_index` / `[6:0]`（`rtl/mgc3130_v2_top.sv:251,289,332`），没有音乐 tick 分频和 BPM 写入处理。128 个 48 kHz sample 约 **2.667 ms**，契约在 120 BPM 下应为 **16 s** 一圈。
- contour 按完整事件 tick 写 128 点（顶层 363–378 行），H32 Potts 仅计算前 32 点；没有 128→32 重采样和输出 tick/duration 逆映射。tick 32–127 的 contour 不在 H32 计算域内。
- scheduler 连续三遍扫描，缺音乐 tick 快照和每 tick 一次的门控（`rtl/v2_loop_scheduler.sv:22–81`）。重复派发/跨 tick 漏事件需对抗用例验证。

退出证据：BPM 60/120/240 圈长、边界、事件数量正确；每 tick 恰好一次；覆盖 tick 0/31/32/127 和跨圈 duration。H32 必须有经确认的全圈映射，否则恢复资源可承受的 H128。H32/H128 前 32 点对比不能替代此证明。

### F2 — Potts 没有写回 Loop，提交发布顺序不完整

- store 唯一写端是 recorder（顶层 315–327 行），没有 Potts→shadow table 通路。
- Potts 输出在非 LIVE/PLAY 模式下直接送 voice（399–402 行），不能证明随后 PLAY 使用精修结果。
- COMMIT 同时请求 store bank swap 和启动 Potts（746–760 行）；`potts_done` 不约束发布。
- store `busy=copy_active||commit_pending`，`!busy` 才服务 active read（`rtl/v2_loop_event_store_dpb.sv:48,66–75,159–161`）。pending/copy 会阻断播放读端；依赖读表产生边界存在相互等待风险。RECORD 模式下 scheduler 也不运行。
- 回归以 `force dut.loop_boundary` 完成提交，并以 `force sample_index=0` 检查 PLAY（`sim/tb_mgc3130_v2_top.sv:179,187`；Potts top 124 行也强制边界），没有证明自主边界和连续播放。

退出证据：`record → contour snapshot → Potts → shadow write/ready → validated completion → natural boundary swap → PLAY` scoreboard；精修事件确实出现在 PLAY；copy/busy/pending 期间旧 bank 连续播放；失败/STOP 保留原 active 数据并清理 pending。

### F3 — contour 只有稀疏 NOTE_ON 落点

顶层 363–378 行仅在 NOTE_ON 写一个 pitch；rest mask 复位后不再更新。未按 NOTE_OFF/duration 填持续音和休止，未在每次录音清空/快照，未隔离不同 track。更新也未检查 `record_write_ready`。

退出证据：持续音、休止、换音、无音、连续两次录音、六轨隔离和背压均与参考 contour 一致；Potts 使用稳定快照，不被后续录音改写。

### F4 — CSR 被接受，但副作用和读回不完整

顶层 read case（605–629 行）主要处理 STATUS/PATCH/WT，其它已被协议层认可的读取默认返回零。BPM、POSITION、FAULT、DIAG_INPUT/AUDIO/ROUTER 和多项 TLM 未接真实读回；PLAY/RESET 无顶层处理。OVERDUB copy 后停止 recorder，只有 PREPARE_RECORD/op5 完成路径会重启录音（661–664、727–733 行）。STOP 进入 IDLE/abort store，未向 voice 发 ALL_NOTES_OFF（752–758 行），存在持续声部风险。

退出证据：依据契约建立“CSR→权限→范围→副作用→读回→错误/重试”矩阵；PLAY/RECORD/OVERDUB/CLEAR/COMMIT/STOP/RESET 从 UART 自主完成；STOP 后声音与 pending APPLY 正确收尾。

### F5 — 参数和波表存储有了，音频消费者未接

`patch_active_value` 只用于 CSR 读回；顶层 487–489 行明确说明音频尚不消费上传波表。voice vibrato 两输入固定零（406 行），诊断输出未接。FX 已编译使能，但固定增益/cutoff，delay/feedback/reverb 为零（421–425 行），未消费运行期 patch。

WT band 顶层仅 1 bit（491、702 行），契约为 3 bits；bank/band/octave 元数据未进入 loader 地址和音频选表，WT_DATA 写后顶层 index 也没有按设计上传流程推进。部分写入/读回不能证明完整上传和声音切换。

退出证据：UART 上传/APPLY 后在 voice/FX/cursor 输出看到对应变化；覆盖每轨/global 范围、vibrato、波表切换、失败保留旧值。消费者接入会改变资源和时序，当前诊断预算不能直接当最终预算。

### F6 — UART 字节抢占可能交错完整帧

顶层 767–771 行每次 UART 空闲都优先 `v2_tx_valid`，没有用 `tlm_frame_last` 锁定帧所有权。ACK 在遥测中途就绪时可能插进 22-byte 遥测，再恢复剩余遥测。snapshot 原子捕获和逐字节背压不解决共享 TX 的帧交错。

TLM_CONTROL enable/period 也未实现；capture 使用 `sample_ce && audio_cursor_valid`，触发上界可能接近 48k/s，而 1 Mbaud、8N1 的 22-byte 帧理论上限约 **4,545 帧/s**，尚未扣 ACK。丢捕获计数未进入可用诊断。Z 直接取低 16 bits，不是契约的 `raw_Z−32768` 编码（781、789 行）。

退出证据：帧级 TX owner、帧间 ACK 优先；在每个遥测字节偏移注入命令，从物理 `uart_tx` 串行解码并校验 CRC/seq；覆盖两种 baud、period、drop 计数和坐标边界。

### F7 — APPLY 缺少双阶段生命周期

契约 51–55 行要求先 APPLY_ACCEPTED，再以同 seq 返回最终 APPLIED/error，涵盖边界等待、超时和重复请求。顶层 633–653 行给一拍后的单次 terminal ACK_ACCEPTED，未跟踪真实完成；STOP 未连接 patch/wavetable APPLY abort。

退出证据：pending/interim/terminal reply cache、同 seq 去重、CRC/version 错误、34 s 超时、STOP abort 与真实 active version 一致；终态在实际生效后产生。

### F8 — I2S 格式、样本对齐与外部时序未证明

- SDC 只有输入时钟与 UART RX false path，没有 BCLK/LRCK/DIN 外部时序模型。
- `rtl/i2s_pcm5102a_tx.sv` 在 bit_count 0/32 同时切 LRCK 和送该声道 MSB，存在与标准 I2S 一位延迟不符的高优先级风险。需串行解码及 PCM5102A 模式证据，本轮不宣称已动态复现。
- audio smoke 检查时钟/DIN 活动，没有逐样本解码。FX 按 sample_ce 更新，而 voice_sample_valid 晚于它，需证明输出和 sample ID 的延迟对应。
- 缺最终可用的 underrun 计数和 DIAG_AUDIO 读回。

退出证据：正负边界/ramp 的双声道串行解码、I2S 相位、帧采样数、无重复/漏样本、FX/voice 延迟 scoreboard；再补板上波形与延迟实测。

## 4. 时序和资源应优化什么

最新最差路径已改变，不能继续直接沿用早期 `seg_t → err_acc` 的结论：

```text
Potts wr_3_s0/Q
  → event_valid / event-data selection
  → voice note increment ROM / apply_delta carry chain
  → voice state DPB lane[8] / DIB[5]
```

原始报告：**18 级、data delay 14.773 ns**；cell 5.749 ns（38.913%）、route 8.680 ns（58.757%）、C2Q 0.344 ns。相近最差路径还有 Potts 状态到 bp_s/bp_d RAMREG CE。**布线和组合逻辑深度都需要处理**；“只是 CLS 拥塞，不是逻辑深度”不符合报告。

建议顺序：

1. 先修 F1–F3，重建正确生产数据流的 baseline。Potts 直接送 voice 会随写回修复改变，不宜先为错误路由做大规模流水改造。
2. 在真正保留的 voice 入口，对 event_valid、96-bit payload、note ROM 和 apply_delta 建寄存/ready-valid 边界；ev_q 只寄存 payload 不保证 valid/选择逻辑已断开。验证 pending note、steal、sample_ce 最坏延迟。
3. 分阶段产生 Potts backtrace RAM 地址、数据和 CE；检查 integer/比较/累加位宽、饱和与 tie-break，不凭估计缩窄。
4. 受控评估 cursor 乘法共享。cursor 尚有 6 个乘法块，整片为 16 个物理 DSP 站点，口径不同；原计划默认 cursor ≤4 DSP 仍缺验收证据。须维持逐帧位等价与吞吐。
5. 同时追踪 logic/FF/CLS/BSRAM/DSP/Fmax/slack/TNS/端点数。历史 contour-prefetch 增 1,040 logic、1,029 FF 且恶化 TNS，已被拒绝；不要无依据全面加寄存器。

12,787 logic 低于 22,000 预留线，但 CLS 已 85%；只能说明诊断配置有逻辑余量，不能承诺补全消费者后的布局余量。80 MHz fallback 需要单独评审，当前 68.013 MHz 也尚未达到 80 MHz。

## 5. Harness 和证据管理缺口

1. **verifier 解析已修正。** 它现在按 timing HTML 行的 Actual Fmax 列读取，clean baseline 复核值为 68.013 MHz，而不是约束列的 100 MHz。
2. Acceptance 应拒绝 dirty 源码、诊断 preserve profile、缺 device.cfg、缺失/未绑定哈希的位流，并覆盖完整 RTL/IP/约束依赖和真实工具版本。五个 harness-input hashes 不等于完整源码锁定；PR2017/PR2028 应查全套当次日志。
3. 当前共享 H0 锁死 H32/FX1；计划的 H128/H32、FX0/1 sweeps 需要主线统一扩展具名 profile/参数，不能让 A/B 私自分叉。
4. **touch decoder 层级被扫不等于 touch 功能被删。** clean `.vg` 仍有 reader touch_info/touch_valid/report_error 到 latch 的连接、归约 LUT、`calibrated_touch` 寄存器和 `u_live.calibrated_touch` 连接（约 20002、20142–20175、20752–20759、191630 行）。verifier 现已实现精确判定：仅在这些网表证据齐全时放行该一条 NL0002。
5. 其它 NL0002 仍严格阻断。clean baseline 中真实被删除的 `v2_test_mode` 仍会使 verifier 返回 BLOCKED；这不是允许清单，也不能靠 blanket allowlist 或 `keep_hierarchy` 伪造通过。
6. 本报告采用原始 **68.013 MHz**，纠正旧文档“touch 必然消失”“仅拥塞”“32 slots 等于 32 ticks”的推断；旧实验记录作为历史保留。并行新增的 `docs/parallel/nl0002-sweep-diagnosis-2026-10-29.md` 中“两模块都真删除”的总括也不能用于 touch：已发现的实际连接和 LUT 锥需要分别解释。单凭父层无 DPB 还不能替代功能等价/可达性证明。

计划交付物仍缺：`scripts/sweep_v2_fullpath_resources.ps1`、`docs/v2-fullpath-resource-baseline-2026-10-29.md`、`docs/v2-final-top-pnr-2026-10-29.md`、`scripts/measure_v2_latency.ps1`。文件存在也须绑定实际测量才能关闭 gate。

## 6. 本轮验证和局限

| 命令 / 位置 | exit / 结果 | 证明范围 |
| --- | --- | --- |
| `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_top.ps1`，integration-probe / 338435c | 0，PASS | 现有 smoke，不证明上述未覆盖语义 |
| `python -m unittest discover -s tools -p 'test_*.py'`，同上 | 0，175 tests OK | PC/参考模型单测，不替代真实 UART/FPGA/板测 |
| `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_v2_fullpath_run.ps1 -RunDir impl/v2_top_fullpath_clean_baseline_1 -Acceptance`，integration | **1，BLOCKED**：touch NL0002 放行，`v2_test_mode` 和 setup=3125 仍阻塞；实际 `fmax_mhz=68.013` | 合法内联不再误阻塞；真实删除和时序仍阻塞 |
| 同一 verifier 对 `impl/v2_top_fullpath_tm_serial_1` | **1，BLOCKED**：touch NL0002 放行，setup=2650，Fmax=71.342 | 证明单条合法内联可以放行，未降低时序门槛 |
| 原始 timing/P&R/device.cfg/manifest/网表检查 | 见第 2/4/5 节 | 保留 clean run 的 synthesis/timing/bitstream 证据，本轮无新 P&R |

当前没有 `board` 级证据关闭传感器物理链路、PC UI 真串口往返、1/8/32 voice、33rd steal、实际 I2S、无 underrun、fault recovery 和 trigger-to-waveform 延迟。离线 UI/模型通过不代表实机联调通过。

## 7. 建议的后续门槛

| 顺序 | 工作 | 退出条件 |
| --- | --- | --- |
| G0 | verifier、具名 profile、源码/工具/位流证据链、状态同步 | 原始值与自动值一致，缺失/错误证据不误过 |
| G1 | F1/F2/F3：音乐 tick、全圈 contour、Potts 写回/切换 | 自然边界完整 RECORD/COMMIT/PLAY，旧 bank 连续播放，不强制内部边界 |
| G2 | F4/F6/F7：控制、帧仲裁、APPLY、诊断 | CSR/seq/CRC/背压/STOP/timeout 串行端到端覆盖 |
| G3 | F5/F8：参数消费者、波表/vibrato/FX、I2S | 实际音频效果、逐样本解码、外部时序与延迟对应 |
| G4 | 确定的最终 top 收敛时序/资源 | 干净提交、全功能可达、100 MHz、零 setup/hold、完整日志和位流哈希 |
| G5 | 板级与 PC 实机联调 | 绑定位流的 UART/I2S/声音/延迟/故障恢复采集与验收报告 |

G0 和独立功能用例可交错推进；G1 数据流必须先稳定，再验收相关路径优化。此次不重开已经成立的 A/B 资源成果，也不把完整系统闭环降为可选优化。

Git 留存：审查前 root 分支比远端领先 22 个提交，A/B 与集成分支尚无同名远端分支。按用户此前“定期上传 git”的授权，已将 A=`38302a1`、B=`4b47514`、integration-probe=`338435c`、integration=`e76ccde` 上传各自 `work/v2-*` 分支；push exit 0，`git ls-remote` 确认四个 SHA 一致。审查文档检查点位于 `feat/loop-event-store`，其上传结果见本轮最终回复。未提交 RTL 与忽略的 `impl/` 不在 Git 上传内。
