# 文档索引

本目录的文档分四类。**发生冲突时的优先级**：主规范 > 实现状态基线 > 分析报告 > 历史讨论。

## 1. 主规范（设计意图，权威）

| 文档 | 内容 |
| --- | --- |
| [v2-fpga-contract-2026-10-25.md](v2-fpga-contract-2026-10-25.md) | V2 FPGA 模式、事件、控制/遥测包和统一 CSR 地址空间冻结契约 |

| [mgc3130-melodic-synthwave-system-design-2026-10-19.md](mgc3130-melodic-synthwave-system-design-2026-10-19.md) | 唯一的产品与算法主规范：六轨语义、风格冻结、EventTable 契约 |
| [pc-lead-intent-purification-design-2026-10-19.md](pc-lead-intent-purification-design-2026-10-19.md) | Lead 曲线 → 旋律的完整设计，含固定 PitchSpace 契约 |
| [mgc3130-coordinate-calibration-spec.md](mgc3130-coordinate-calibration-spec.md) | 三层坐标语义、生命周期、验收不变量 |
| [pc-host-only-xyz-filtering-design-2026-10-21.md](pc-host-only-xyz-filtering-design-2026-10-21.md) | 无 SDK 硬件校准时的主机侧去耦合与抗抖 |
| [mgc3130-z-coupling-clutch-rebase-realtime-design-2026-10-22.md](mgc3130-z-coupling-clutch-rebase-realtime-design-2026-10-22.md) | Z 的表达语义、相对/绝对光标、实时时间模型的取舍；§11 是本轮最终参数 |

## 2. 实现状态与分析（as-built）

| 文档 | 内容 |
| --- | --- |
| [lead-implementation-status.md](lead-implementation-status.md) | Lead 链路**当前真实行为**、有效参数、与设计文档的偏差；改动 Lead 必须同步更新 |
| [pc-ui-spec-2026-10-22.md](pc-ui-spec-2026-10-22.md) | 界面逐元素规格：布局、控件绑定、画布图元、哪些控件未接线 |
| [lead-mapping-report-2026-10-22.md](lead-mapping-report-2026-10-22.md) | 曲线 → 音高 → 音符的量化分析：为什么直线只出 2 个音、抬手断点的成因 |
| [curve-to-melody-algorithms-2026-10-22.md](curve-to-melody-algorithms-2026-10-22.md) | 高级算法评估、三层架构（表达 → 风格拟合 → 渲染）、自由度边界 |
| [curve-to-melody-variational-2026-10-24.md](curve-to-melody-variational-2026-10-24.md) | 一维化 + Potts 变分分段：把旋律定义为音级格上的最优分段常值逼近 |
| [fpga-baseline-audit-2026-10-25.md](fpga-baseline-audit-2026-10-25.md) | FPGA 现有 40 个模块的能力盘点、与目标的差距、PC 先行里程碑 |
| [voice-engine-design-2026-10-25.md](voice-engine-design-2026-10-25.md) | 128 算子时分复用引擎：时序预算、RAM 映射、流水级、验证方案 |
| [synth-backend-design-2026-10-25.md](synth-backend-design-2026-10-25.md) | PC→FPGA 合成器后端接口：64-bit 事件帧、CSR 控制帧、32 声部微架构、7 天计划 |
| [lead-articulation-and-leaps-2026-10-24.md](lead-articulation-and-leaps-2026-10-24.md) | 用 X 轴做"运弓"实现同音重复，用速度规则实现大跳；三通道演奏语言 |
| [superpowers/plans/2026-10-25-v2-fpga-full-pipeline-implementation.md](superpowers/plans/2026-10-25-v2-fpga-full-pipeline-implementation.md) | 针对当前 RTL/协议/时钟缺口的 V2 全链路执行计划 |

## 3. 问题跟踪与采集

| 文档 | 内容 |
| --- | --- |
| [lead-open-issues-2026-10-22.md](lead-open-issues-2026-10-22.md) | 掉帧、中心偏移、Z 漂移三个问题的证据与实验记录 |
| [z-coupling-capture-protocol-2026-10-22.md](z-coupling-capture-protocol-2026-10-22.md) | 八段校准采集协议与判读方法 |
| [mgc3130-calibration-summary-2026-10-18.md](mgc3130-calibration-summary-2026-10-18.md) | 早期校准数据与传感器边缘行为 |

## 4. FPGA 接口

| 文档 | 内容 |
| --- | --- |
| [input-event-adapter-interface.md](input-event-adapter-interface.md) | 输入事件适配器 |
| [loop-control-plane-interface.md](loop-control-plane-interface.md) | Loop 控制层与 UART 协议 |
| [loop-event-store-interface.md](loop-event-store-interface.md) | 事件存储与提交语义 |
| [loop-scheduler-interface.md](loop-scheduler-interface.md) | 调度器与扫描时序 |
| [loop-audio-integration-interface.md](loop-audio-integration-interface.md) | 音频接线边界 |

## Gowin CLI 入口

Windows 上的 Gowin 命令行程序名是 `gw_sh.exe`，不是 `gw.sh`。推荐从仓库根目录
使用 `scripts/gw.sh`（Git Bash）或 `scripts/run_gowin_cli.ps1`（PowerShell）：

```bash
./scripts/gw.sh scripts/synth_v2_voice_engine.tcl
```

两个入口都会从 `C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gwlicense.ini`
读取许可配置，并把 CLI 的工作目录固定到 Gowin `IDE\bin`。服务器变化时可设置
`GW_LICENSE_SERVER=host:port`，或在 PowerShell 中传 `-LicenseServer host:port`。

## 5. 历史与讨论（不作为依据）

`ambient-*.md`、`mgc3130-pre-audio-feedback-discussion-2026-10-19.md`、`development-log-2026-10-18.md`、`toolchain-verification-2026-10-16.md`、`superpowers/` 下的计划与规格。这些记录了当时的取舍过程，结论已被上面的主规范取代。

## 维护规则

1. 改动 Lead 的**数据流、阈值、事件字段或渲染**时，必须同步更新 `lead-implementation-status.md` 并单独提交。
2. 改动**界面元素**时，同步更新 `pc-ui-spec-2026-10-22.md`。
3. 改动**设计意图**（不变量、音域、网格、坐标语义）时，先改主规范，再改实现，并在提交信息里写明原因。
4. 新增文档请按上面的分类放进本索引，并在文件名里带日期。

## 当前实现同步说明（2026-10-25）

下列历史章节仍保留当时的实验过程，但阅读时应以当前代码和最近提交为准：

- PC UI 当前使用 **XY 俯视图 + Z 颜色** 的二维画布，不再使用早期的三维等距投影。
- UI 的默认 `compile_loop` 路径使用 `pitch_source="cursor"` 和绝对数位板式光标；`RelativeCursor` 只保留为 A/B 实验实现。
- 在非 `host_profile` 的 cursor 路径中，乐句从第一帧有效接合开始；旧的左沿起笔门控仍适用于 absolute/HostProfile 路径，但不是当前 UI 默认路径。
- 当前 Z 阈值为 `z_release=36000`、`z_engage=30000`；早期 `20000/16000` 参数已经废弃。
- CLUTCH/REBASE 是设计分析和后续实时策略的历史方案；当前 PC UI 使用光标增益、抬手断开和重新接合标记来避免跳变。
- `HostCalibrationProfile`、Z→XY 去耦合和回放工具已经存在，但 GUI/CLI 默认不自动加载 profile；显式 profile 回放与普通 cursor 路径必须区分。
