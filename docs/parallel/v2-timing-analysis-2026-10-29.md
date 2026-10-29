# V2 时序违规分布分析（2026-10-29）

当前基线：`work/v2-integration` @ `b938fbd`（提交 `fec4008` 含串行化测试模式）。
本文件回答"2,650 条违规都在哪"，并记录一次被否掉的优化尝试。

## 1. 方法

`scripts/synth_v2_top_fullpath_20261029.tcl` 的副本加
`set_option -num_critical_paths 200` 后跑完整 P&R（RunId `paths200`，诊断 tcl 在
`impl/ms_h1/`，不入库）。

结果：**工具仍然只列 25 条 setup 路径**（`set_option` 未扩大 3.1.1 表），所以只能
按最差 25 条看分布，其余用 TNS/端点数推断。

## 2. 最差 25 条 setup 路径的归属

| 起点模块 | 条数 | 终点模块 | 条数 |
| --- | ---: | --- | ---: |
| `potts.u_potts` | **20** | `potts.u_potts` | **19** |
| `voice` | 4 | `voice` | 5 |
| `cursor` | 1 | `telemetry` | 1 |

最差 slack −4.017 ns，全部来自 Potts 内部；次差是 voice 内部（−3.993 ns）与
cursor→telemetry（−3.990 ns）。

## 3. 整体量级：又宽又浅

| 指标 | 值 |
| --- | ---: |
| setup 违规端点 | 2,650 / 28,150 |
| setup TNS | −5,223.2 ns |
| **平均每条违规** | **≈ −1.97 ns** |
| 最差 | −4.02 ns |

TNS ÷ 违规数 ≈ −1.97 ns，说明绝大多数违规只差 2 ns 左右，而不是几条灾难路径。
配合 CLS 使用率 **89%**（10,250/11,520）可以判断：**当前瓶颈是布局拥塞，不是单条
逻辑链深度**（最差路径只有 16 级）。

## 4. 一次被否掉的尝试：Potts 计数器窄化

把 `integer e,s,d,seg_t,trace_*` 改成 8 bit / 3 bit（语义不变，回放通过）：

| 指标 | 窄化前（`fec4008`） | 窄化后 | 变化 |
| --- | ---: | ---: | ---: |
| logic | 15,302（67%） | 14,759（65%） | −543 |
| Register | 8,996 | 8,575 | −421 |
| CLS | 10,250（89%） | 10,120（88%） | −130 |
| **实际 Fmax** | **71.342 MHz** | 69.379 MHz | **−1.96 MHz** |
| setup 违规 | 2,650 | 2,628 | −22 |
| TNS | −5,223.2 ns | −5,416.7 ns | **−193 ns** |

面积降了、时序反而略差，且差异接近布局随机波动量级。**按"不为面积牺牲时序"的原则
已 revert**，当前 RTL 仍是 `fec4008` 状态。

## 5. 结论与建议

1. 最差 25 条里 Potts 占 20 条，是唯一明确的单点热点；但它最差也只有 −4.0 ns，
   全局平均 −2.0 ns，所以**修好 Potts 也到不了 100 MHz**。
2. CLS 89% 说明真正要动的是**总面积/寄存器量**与布局拥塞。当前大户：

   | 模块 | logic | FF |
   | --- | ---: | ---: |
   | `v2_cursor_filter_timed` | 3,464 | 2,213 |
   | `v2_voice_engine_banked` | 3,688 | 1,955 |
   | `v2_potts_commit_fsm` | ~1,800 | ~1,290 |
   | `mgc3130_reader` | 1,156 | 748 |
   | `v2_telemetry_snapshot` | 534 | 308 |

3. 下一步优先级建议：
   - **P1** Potts 段累加流水化（把 `contour mux → 减法 → 乘法 → 累加` 拆两拍），
     预期把 20/25 的热点拉平，代价约 +33 拍/帧；
   - **P2** cursor 的 2,213 个寄存器（占全设计 26%）是最大 FF 块，降它最能缓解 CLS；
   - **P3** voice 写回路径（4 条）留给 A stream 第二轮。
4. 若上述做完仍在 70–80 MHz 区间，按计划 Task 5 的条款，需要走"记录时钟降级 +
   重新计算每样本预算"的决策，而不是继续堆流水。

## 6. 复现

```powershell
# 分布报告（诊断 tcl，200 条路径设置）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
  -TclScript (Resolve-Path impl/ms_h1/diag_paths200.tcl).Path `
  -LicenseServer '106.55.34.119:10559' -RunId paths200

# 门禁校验（新 verifier 已含 touch decoder 精确例外）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify_v2_fullpath_run.ps1 `
  -RunDir impl/v2_top_fullpath_tm_serial_1
# → V2_FULLPATH_VERIFY_STATUS=PASS
```
