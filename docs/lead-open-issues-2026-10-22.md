# Lead 开放问题记录（2026-10-22）

版本：2026-10-22  
状态：问题已记录，归因实验进行中。  
关联：[Lead 实现状态基线](lead-implementation-status.md)、[XYZ 去耦合与抗抖设计](pc-host-only-xyz-filtering-design-2026-10-21.md)。

本文只记录**已观察到的现象、已有证据和待验证假设**，不预先给出结论。每条问题在关闭时必须写清：根因、改动、验证方式、对应的 git 提交。

## 问题 1：中心不在物理中心 + 绘制时间越长越卡、掉帧

### 1.1 现象

- MGC3130 报告的坐标原点不在用户认定的物理工作区中心，整体偏左。
- 录制时间越长，界面越卡，掉帧越明显；无法判断是传感器、链路还是软件。

### 1.2 已有证据

对仓库内两次独立采集（`tools/capture_fast_01.csv`、`capture_fast_02.csv`，由采集工具直接写盘，不经过 UI）：

| 指标 | fast_01 | fast_02 |
| --- | --- | --- |
| 帧数 / 跨度 | 968 / 29.39 s | 933 / 29.86 s |
| 有效帧率 | 32.9 Hz | 31.2 Hz |
| 帧间隔 p50 / p95 | 31.0 / 47.0 ms | 31.0 / 47.0 ms |
| 最大停顿 | 1141 ms | 1734 ms |
| >250 ms 的停顿次数 | 3 | 5 |
| 原始日志吞吐 | 3.98 KB/s | 3.98 KB/s |

推论：

1. UART 链路未饱和。`115200 8N1` 上限约 11.5 KB/s，实测 3.98 KB/s（约 35%）。FPGA 发出的是 14 字节二进制帧（[mgc_uart_report_tx.sv](../rtl/mgc_uart_report_tx.sv)），理论上限约 820 帧/s，而实测 32 帧/s。限速点在 UART 上游（I²C 轮询周期、传感器输出率或 USB 串口驱动）。
2. 秒级停顿比稳态帧率危害更大。100 BPM 下一个 16 分音符为 150 ms，1734 ms ≈ 11 个 16 分音符无数据，会被编译成整段 rest。
3. 这批数据由独立采集工具产生，**不经过 UI**，因此"掉帧"至少有一部分不是界面造成的。

UI 侧两个确定的放大器（不是已证实的根因）：

- [synthwave_ui.py](../pc_receiver/synthwave_ui.py) `_poll_inbox` 把 `_draw_canvas()` 写在逐条取记录的循环内，一次轮询积压 N 条记录就整幅重绘 N 次，而每次重绘成本随历史点数线性增长。
- 实测单次全重绘成本：500 点 0.37 ms、2000 点 0.56 ms、8000 点 2.10 ms、16000 点 4.21 ms。40 ms 轮询预算下，积压 8 条 × 8000 点即约 17 ms，随录制时长逼近并超过预算，形成"越画越卡 → 积压更多 → 更卡"的正反馈。
- `create_line(..., smooth=True)` 在数千点规模上没有收益，只增加 CPU。

中心偏移的具体影响：起笔门控把左边缘硬编码为原始 `4096/65535`（[synthwave_loop.py](../tools/synthwave_loop.py) `LEAD_LEFT_EDGE_MAX`），假设原始 x≈0 即物理可达左沿。若工作区整体偏移导致手够不到该值，门控可能打不开或只在极端姿势下打开。

### 1.3 待验证假设

| 编号 | 假设 | 验证方式 |
| --- | --- | --- |
| H1 | 掉帧发生在 UI 之前（传感器/链路/SDK） | 实验 A：绕过 UI 单独运行接收器 |
| H2 | 掉帧发生在 UI 消费端（重绘积压） | 实验 C：对比 UI 运行时与单独运行的到达间隔 |
| H3 | 稳态 32 Hz 由 FPGA 轮询或传感器输出率决定 | 实验 B：读取 FPGA 的 report_count 增量 |
| H4 | 中心偏移可由 neutral 采集量化并写入 profile | neutral capture：静止 5 s 看 x/y 中位数相对 32768 的偏差 |

### 1.4 实验 A：绕过 UI

```powershell
pc_receiver\Static-Release\mgc3130_receiver.exe --seconds 20 --output solo.jsonl
python tools\analyze_frame_timing.py solo.jsonl
```

判读：

- 若仍有 31 ms 主峰、秒级停顿或 `SDK skipped > 0` → 结论偏向 H1，UI 不是根因。
- 若帧间隔稳定在 5–10 ms 且无长停顿 → 结论偏向 H2，问题在 UI 消费端。

### 1.5 实验 B：区分传感器出帧率与串口发出率

```powershell
python tools\probe_loop_uart.py --port COM9      # 识别哪一路带 LOOP UART READY
python tools\loop_control_uart.py --port COM9 diag
```

取两次 diag 的 `report_count` 差值 ÷ 间隔秒数：

- 若 ≈ 200 Hz 而串口只有 32 Hz → FPGA 侧在丢帧/降频（检查 `mgc3130_reader` 轮询与 TX 背压）。
- 若 ≈ 32 Hz → 传感器或 I²C 轮询本身就是 32 Hz，链路无辜。

### 1.6 实验 C：UI 消费端

在 UI 的接收线程里记录每行的本地到达时间戳（`time.monotonic()`），与记录中的传感器 `timestamp_ms` 对比。若到达时间成簇而传感器时间均匀 → 消费端积压。

### 1.7 实验结果（2026-10-22，第一轮）

> **勘误（同日）**：下面 COM9/COM10 的测量来自 FPGA 板链路，而当前实际使用的是 **MGC3130 SDK 直连 USB**，不经过 FPGA。该组数据与本文问题无关，仅保留为旁证。真正的归因见 §1.9。

**实验 A（单独运行接收器）**：设备在线（`gestic_open` 成功），但 20 秒内 **0 条 position 记录**。原因是无手在场时 SDK 几乎不发帧；偶发空闲帧的签名是 `x=y=32767, z=65535`。结论：

- 该流是**存在感应门控**的，空闲帧率不能当作基线，实验 A 必须在有人做手势时进行。
- `z=65535` 是"无手/空闲"的值，恰好等于 Z 轴最大值。任何按 Z 调度横向增益的实现都必须先区分"无手"与"高 Z 姿态"，否则会把 rest 当成最高深度。

**实验 B（FPGA 链路）**：

| 端口 | 结果 |
| --- | --- |
| COM9 | 存在但打不开（打开超时），当前不可用 |
| COM10 | 可打开，二进制帧（`FE FF` 同步），10.14 s 收到 5874 字节 / 245 帧 |

COM10 测量值：

```text
吞吐      579 B/s     （115200 8N1 上限约 11520 B/s，占用 5%）
帧率      24.2 帧/s
消息 ID   0x16 × 244、0x10 × 1
```

判读：

1. 链路占用仅 5%，**传输不是瓶颈**，不存在"串口发不完"导致的丢帧。
2. [mgc3130_reader.sv](../rtl/mgc3130_reader.sv) 没有轮询分频器，它在 `ST_WAIT_TS` 等传感器的 data-ready 后立即读 I²C（100 kHz），因此 **24 帧/s 的节拍来自传感器，而不是 FPGA 定时器**。
3. `probe_loop_uart` 对 COM10 没有收到 ACK，说明当前板上不是 loop 控制固件，**CSR 的 `report_count` 实验 B 暂不可用**；需要先烧 loop 位流。
4. 之前 CSV 里的 31 ms 主峰（32 Hz）与本次线上 24.2 帧/s 同量级，互相印证"稳态帧率由传感器决定"。

仍未解释的部分：CSV 中 1.1–1.7 s 的停顿。它既可能来自传感器/驱动，也可能来自采集端的 USB 缓冲，必须在有人做手势的情况下重测才能定位。

### 1.8 下一轮实验（需要人在场）

```powershell
# 1. 出现 READY 后立即把手放在传感器上方，持续做横向+纵向移动 20 秒
pc_receiver\Static-Release\mgc3130_receiver.exe --seconds 20 --output "$env:TEMP\solo_hand.jsonl"
python tools\analyze_frame_timing.py "$env:TEMP\solo_hand.jsonl"
```

判读标准：

| 观察 | 结论 |
| --- | --- |
| 仍有 31 ms 主峰与秒级停顿 | H1：传感器/驱动侧，UI 不是根因 |
| 帧间隔稳定在 5–10 ms、无长停顿 | H2：问题在 UI 消费端 |
| `SDK skipped > 0` | 帧在 SDK 内部被丢弃，需检查 USB 缓冲与 `Sleep(5)` 主循环 |

若要在同一轮里对比 UI，再运行一次带 UI 的录制，比较两次的帧间隔分布。


### 1.9 勘误：真实链路与两个新发现

**链路更正**：当前是 `MGC3130 → USB HID → gestic_api.dll → mgc3130_receiver.exe → stdout 管道 → Python UI`。全程没有 UART，因此 §1.7 的 FPGA/COM 测量不适用；"链路带宽不是瓶颈"这一结论在 USB HID 上仍需重新验证，但至少 UART 那部分可以排除。

**发现 1：仓库里的 exe 是旧二进制。** `pc_receiver/Static-Release/mgc3130_receiver.exe` 构建于 2026-10-19 17:25，而 `mgc3130_receiver.cpp` 最后修改于 2026-10-21 21:25。旧 exe 输出的是旧 schema（`frame`，没有 `sequence_gap` / `position_valid`），与源码不一致。已于 2026-10-22 用 MSBuild `Static-Release / Win32` 重建，新输出包含：

```json
{"type":"position","timestamp_ms":...,"sequence":...,"sequence_gap":...,
 "x":...,"y":...,"z":...,"position_valid":null,...}
```

影响：`sequence_gap` 就是 `gestic_data_stream_update()` 返回的 `skipped`，即 **SDK 内部丢帧计数**，是本次归因最关键的指标，而旧二进制根本不输出它。

**发现 2：接收器主循环的节奏与背压。** `mgc3130_receiver.cpp` 的实现是：

```cpp
do { result = gestic_data_stream_update(&gestic, &skipped); ... } while (result == GESTIC_NO_ERROR);
Sleep(5);
```

每轮先排空 SDK 队列，再固定睡 5 ms。单看这不丢帧，但它把"排出速度"交给了 stdout 写入：每行 `std::cout << line; flush;` 是**同步阻塞写**。UI 以子进程管道读取，一旦 UI 变慢、管道缓冲填满，接收器就阻塞在 `write()` 上，期间不再调用 `gestic_data_stream_update()`，SDK 环形缓冲溢出 → `skipped` 增长 → 表现为"越画越卡、掉帧越多"。

这条机制与"随绘制时间增加而卡顿"高度吻合，也是当前最值得验证的假设。

### 1.10 修正后的归因实验（SDK 直连）

准备：已重建 exe（含 `sequence_gap`）。

```powershell
cd "C:\weizijian\documents\gowin fpga\mgc3130_uart"

# A. 只有接收器，无 UI。出现 ready 后立刻把手放在传感器上方持续移动 20 秒
pc_receiver\Static-Release\mgc3130_receiver.exe --seconds 20 --output "$env:TEMP\sdk_solo.jsonl"
python tools\analyze_frame_timing.py "$env:TEMP\sdk_solo.jsonl"

# B. 打开 UI 录制同样的手势，然后对 UI 的录制做同样统计
#    （UI 在录制期间把 receiver 的输出也写进 current_capture，可直接导出比较）
```

判读：

| A 的结果 | B 的结果 | 结论 |
| --- | --- | --- |
| 干净（p50≈5–10 ms，无长停顿，skipped=0） | 出现长停顿/skipped>0 | UI 消费端背压，问题在软件 |
| 已经不干净 | 与 A 相同 | SDK/USB/传感器侧，与 UI 无关 |
| 两者都不干净但 B 更差 | — | UI 放大了一个上游问题 |

若确认是 UI 背压，修复顺序固定为：重绘移出逐条循环 → 固定 30 Hz 节流 → 画布点数降采样 → 接收线程改为"入有界队列、丢最旧"而不是阻塞管道。


## 问题 2：Z 方向移动伴随 XY 漂移，且随 Z 升高而增大

### 2.1 现象

手的深度（Z）移动会同时带来 X/Y 位移；Z 越高，XY 漂移越大。

### 2.2 已有证据

对 `capture_fast_01/02` 做 11 帧高通（去除慢速移动）后，按 Z 分箱统计横向残余抖动（单位：原始坐标，满量程 65535）：

| Z 区间 | 样本数 | 横向抖动中位数 |
| --- | --- | --- |
| 0–8000 | 759 | 106 |
| 8000–16000 | 70 | 397 |
| 16000–24000 | 38 | 523 |
| 24000–32000 | 26 | 668 |
| 32000–48000 | 44 | 641 |
| 48000–66000 | 31 | 5965 |

`corr(z, 横向抖动) = +0.614`（fast_01）、`+0.624`（fast_02）。低 Z 约为满量程的 0.16%，中高 Z 约 1%，最高段接近 9%。

限制：这两次采集是横向扫掠，不是"固定 XY 只动 Z"，因此**只能证明噪声随 Z 增大，不能用来拟合 `g_x(z)` / `g_y(z)` 系统性偏移**。后者需要按 10-21 文档 §3.4 做 depth-only 采集。

### 2.3 候选方案（尚未实现）

按 Z 调度横向增益与门限，而不是直接限速度：

```text
z_norm = (z - workspace_min_z) / (workspace_max_z - workspace_min_z)
lateral_gain(z) = clamp(1 - (z_norm - 0.25) / (0.70 - 0.25), min_gain, 1.0)
q_track += lateral_gain * (q_target - q_track)
dead_zone(z) = base_dead_zone * (1 + 3 * z_norm)
z_norm > hold_threshold → 显式 HOLD 状态
```

已知风险：

- 硬冻结会在离开高 Z 区时产生位置跳变，被锚点编译器读成 `TURN`/`APEX`，凭空生成音符。
- 限速度会改变曲线时间形状，与 128 tick 重采样和 4 tick 最小锚点间隔冲突；因此选择调增益与门限。

### 2.4 待决策

高 Z 是"纯长音区"（`min_gain ≈ 0.05`，完全失去音高控制）还是"迟钝但可控"（`min_gain ≈ 0.15–0.25`，仍会缓慢漂移）。该选择决定 `min_gain` 与 `hold_threshold`。

## 问题 3：能否用关联 XYZ 二次计算曲线，而不只是滤波

### 3.1 问题

曲线数据是否可以不直接取自单帧传感器 XYZ，而是用其他关联的 XYZ 经二次计算（状态估计）得到？三维定位领域是否有先例？

### 3.2 先例与适用范围

| 方法 | 先例 | 对 MGC3130 的适用性 |
| --- | --- | --- |
| 卡尔曼/UKF，常速度模型，观测噪声随 Z 调整 | AR/VR 手柄与手部跟踪 | 可用，且天然实现"高 Z 更平滑" |
| IMM（静止/慢速/快速多模型） | 雷达跟踪、手势识别 | 可用，适合区分抖动与有意运动 |
| 交叉轴灵敏度矩阵 | MEMS IMU 六面标定 | 可用，`g_x(z)`/`g_y(z)` 是一阶特例 |
| 工作点相关的偏置查表 / LOWESS 残差 | 磁跟踪畸变校正、数位板标定 | 可用，10-21 文档已规定 |
| 高斯过程 / 小型网络拟合残差 | 触摸笔校准、EIT 重建 | 谨慎：破坏可解释与可复现，只允许离线 profile |
| 阻抗断层成像（EIT）反演真实手位 | 电容/电场传感阵列 | 不可用：MGC3130 只输出已解算 XYZ |
| 增加 IMU / ToF / 超声测距做融合 | 多传感器融合 | 唯一能真正提升三维精度的路径，需要改硬件 |

### 3.3 当前判断

- 可行且有收益：一阶去耦 + Z 相关噪声模型的卡尔曼平滑 + Z 增益调度。三者叠加可把中高 Z 的抖动从约 1% 压到 0.2% 量级，且全程可解释、可回放。
- 不可行：仅凭单颗 4 电极电场传感器的 XYZ 输出重建真实三维位置。信息量不足，复杂模型只会拟合噪声。
- 换硬件是唯一根治路径；软件只能提高可用性。

### 3.4 待决策

是否接受"离线 batch 估计"（可复现、可审计）作为默认，实时路径只保留有界的一阶滤波；还是允许实时运行卡尔曼（需要记录状态初值与协方差以保证确定性）。

## 下一步顺序

1. 实验 A（绕过 UI）与实验 B（report_count）→ 关闭问题 1 的归因。
2. 修 UI 重绘缺陷（纯软件，不改变音乐结果）。
3. neutral capture → 量化中心偏移 → 门控阈值改为相对 workspace。
4. 等 2.4 的决策后实现 Z 增益调度。
5. 卡尔曼平滑作为 4 之后的精修。

## 变更记录

### 2026-10-22

- 建立本文，记录三个问题、已有证据与实验计划。
- 新增 [tools/analyze_frame_timing.py](../tools/analyze_frame_timing.py)，用于统计帧率、帧间隔分布、长停顿与 SDK 丢帧。
- 第一轮实验：单独运行接收器 20 秒得到 0 条 position 记录，确认位置流受"手在场"门控，空闲帧为 `x=y=32767, z=65535`。
- 勘误：实际链路为 SDK 直连 USB，不经过 FPGA；COM9/COM10 的测量不适用于当前问题。
- 发现接收器 exe 早于源码（10-19 vs 10-21），输出旧 schema 且缺少 `sequence_gap`；已重建并确认新 schema。
- 补充 SDK 直连下的背压机制（stdout 阻塞写使接收器停止排空 SDK 队列）与修正后的归因实验（§1.9、§1.10）。
