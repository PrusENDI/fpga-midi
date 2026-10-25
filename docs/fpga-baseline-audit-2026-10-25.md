# FPGA 基线审计与 PC 先行计划（2026-10-25）

范围：`mgc3130_uart-synth-plugin/rtl` 的 40 个模块，对照本次 7 天目标（整条链路下板、PC 只做参数与显示）。  
结论先说：**下板不是从零开始**，输入、事件、调度、混音、I2S 都已存在；缺的是"我们的映射规则"和"规模化"。

## 1. 已有能力（按数据流）

| 阶段 | 模块 | 现状 |
| --- | --- | --- |
| 传感 | `mgc3130_reader` + Gowin I2C IP | ✅ 实机验证，输出 `report_valid/x/y/z/gesture` |
| 锁存 | `mgc3130_input_latch` | ✅ 单周期锁存完整报告 |
| 映射（旧） | `mgc3130_pattern_input` | ✅ X=时间格、Y=音高、Z=力度（早期方案） |
| 映射（LIVE） | `live_xyz_mapper` | ✅ X=音符区、Z=滞回门控（与我们的语义不同） |
| 事件格式 | `performance_event_pkg` | ✅ 64-bit：type/track/tick/duration/note/velocity/pitch/amp/timbre/flags |
| 事件入口 | `performance_event_ingress` | ✅ LIVE / RECORD / MODULATION 三通道队列 |
| 路由 | `performance_event_router` + `voice_bridge` | ✅ 有序事件 → 混音器 |
| 循环 | `loop_scheduler`（128 分音符）+ `loop_event_store`（2 bank × 4 轨 × 16 槽）+ `loop_event_ram` | ✅ 已有循环骨架 |
| 控制 | `loop_control_plane` + `control_csr` + `command_mailbox` + `control_protocol_pkg` | ✅ 字节级命令、原子 CSR、ACK |
| 音频 | `mgc3130_voice_mixer` | ✅ **双振荡器 LIVE/Loop 声部，带连续 DDS 滑音** |
| 输出 | `i2s_pcm5102a_tx`（PCM5102A 引脚已在 `.cst`）+ `mgc3130_audio_uart_tx`（48 kHz PCM over 921600，调试用） | ✅ |
| 辅助 | UART rx/tx/fifo/serializer/banner/heartbeat | ✅ |

即：**"传感器 → 事件 → 声部 → I2S" 的主干是通的**，且已有双振荡器滑音声部与 128 tick 循环调度。

## 2. 与目标的差距

| 缺口 | 现状 | 需要 |
| --- | --- | --- |
| 光标模型 | `live_xyz_mapper` 用 X 选区、Z 滞回 | 换成我们的**绝对光标**：Z→alpha、触控冻结、每帧限速 0.02、回滚 |
| 出音规则 | 电平/区域制 | LIVE：电平穿越 + 滞回 + 最小间隔；LOOP：Potts DP（4096 状态） |
| 门控 | 无触控门控 | touch 触发 + 时值 = 接触时长 |
| 声部数 | 单混音器（双振荡器） | 32 声部（或 16 声部降级） |
| 反向遥测 | 无 | 200 Hz 光标/音符回传，供 PC 显示 |
| 参数下行 | 部分 CSR | 新增 gate/rule/cursor/scale/z_range |
| FX | 无 | delay/reverb/chorus |
| 可视化 | 无 | LED/频谱 |

## 3. 为什么先做 PC：三件事必须先定死

1. **定点格式**：DDS 相位 32-bit、包络 16-bit、混音 24-bit、alpha 用 Q8 还是 Q12。PC 参考实现若与 RTL 不一致，移植后听感就会变。
2. **出音规则的边界条件**：滞回、最小间隔、触控时值截断。这些在 PC 上改一行就能试，在 RTL 上要一轮综合（约 6 分钟）。
3. **参数映射**：密度滑块 ↔ λ ↔ 最小段长 ↔ 最大音符数。这套关系只有在 PC 上跑够样本才能定。

## 4. PC 侧要完成的完整流程（M1–M4）

| 里程碑 | 内容 | 验收 |
| --- | --- | --- |
| **M1** | `synth_reference.py`：双振荡器 DDS + ADSR + 滑音 + 混音（与 `mgc3130_voice_mixer` 对齐） | 单测：相位/包络/混音的定点数值；正弦频点误差 < 1 Hz |
| **M2** | 事件 → 声部调度（32 声部、按 track 分配、note_off 释放、抢占策略） | 复音测试：32 音同时，无爆音、无泄漏 |
| **M3** | 整链路：捕获 → 光标 → 出音（LIVE/LOOP）→ 声部 → 混音 → WAV/实时播放 | 与现有 `render_loop` 对比听感；逐样本容差 |
| **M4** | 参数面板 + 遥测仿真（PC 模拟 FPGA 回传），先把 UI 打通 | UI 可拖动参数并实时听到变化 |

M1–M3 不需要硬件；M4 之后才有必要动 RTL。

## 5. 移植时可直接复用的判断

- `performance_event_pkg` 的 64-bit 字段足够表达我们的事件表，**不必新造协议**；
- `i2s_pcm5102a_tx` 与 `.cst` 引脚可直接用；
- `loop_scheduler` 的 128 tick 与我们的 `loop_ticks` 一致（8 小节 × 16）；
- `mgc3130_voice_mixer` 的双振荡器结构正是"32 声部"的单元，扩数量即可，不必重设计。

## 6. 风险

| 风险 | 缓解 |
| --- | --- |
| PC 参考实现与 RTL 定点不一致 | M1 就用定点（整数）实现，不用浮点；每步有单测 |
| 32 声部资源不足（25K） | 先做 8 声部，保留参数化声部数 |
| DP 在 FPGA 上时序紧 | 40 µs 预算，可分多周期流水；LOOP 模式才用 |
| 7 天内 PC 流程收尾不够 | M1–M3 是硬线，M4 可退化为"参数改动后重新渲染" |
