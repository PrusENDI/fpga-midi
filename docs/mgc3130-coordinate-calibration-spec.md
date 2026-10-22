# MGC3130 坐标与校准规范

状态：设计冻结，供 PC 参考实现、FPGA 移植和 UI 共同引用。本文只定义传感器坐标、应用坐标和动作参考点，不定义音符生成或音色。

## 1. 三层语义

| 层 | 责任 | 允许的更新方式 |
| --- | --- | --- |
| SDK/硬件校准 | 消除电极基线、环境和 DSP 工作点漂移 | 按 GestIC SDK 的自动/强制校准流程，在稳定条件下执行 |
| 应用坐标校准 | 轴向、缩放、neutral 区、dead zone 和音乐坐标映射 | 由应用保存的 profile 显式更新 |
| 动作相对起点 | 把 PLAY 手势或 Lead 路径形状解释为局部变化 | 进入模式时可锁存 `x0/y0/z0`；不能作为 Lead 固定音高空间的零点 |

Microchip GestIC SDK 提供 `gestic_set_auto_calibration`、`gestic_force_calibration` 和 `gestic_get_calibration`，但没有通用的“把当前 XYZ 设为应用原点”或“每次手势从中心点开始”的 API。`gestic_touch_center` 与 `gestic_tap_center` 是中心电极事件，不是 XYZ 坐标中心。

## 2. 应用坐标流程

1. 确认 SDK 的 `PositionValid`、Presence 和 Hand Inside 状态。
2. 在没有主动动作时采集一小段稳定报告，估计 neutral 的中位数和噪声尺度。
3. 使用应用 profile 的轴向符号、范围和缩放，把传感器 XYZ 转为固定应用空间 `q_app = S·R·(XYZ-offset)`。Lead 的音高轴、工作区边界和固定参考点 `q_ref` 来自 pitch/calibration profile；不能使用本次曲线的 min/max 或起点重建音域。
4. 进入 Lead RECORD 或 PLAY 时等待 neutral 稳定若干帧。PLAY 可以锁存 `x0/y0/z0` 作为局部调制参考；Lead 只在需要识别开放路径形状时保存 `q0`，不得把它作为固定音高零点。
5. 运行时可以计算 `dx=x-x0`、`dy=y-y0`、`dz=z-z0` 供 PLAY 包络/调制和路径形状诊断使用；Lead 固定音高必须使用 `q_app-q_ref` 投影到固定 pitch axis。两者都执行 dead zone、低通和 slew 限制。

相对动作参考点在一次模式会话内保持不变。固定 `q_ref` 和 pitch grid 由应用 profile 保持不变；不能每帧重算，也不能在手已经运动时调用 `gestic_force_calibration()`。neutral 的小幅漂移只能作为固定 offset 补偿并写入 CaptureSession，大幅漂移必须提示重新校准。

## 3. PC 主机侧去耦合、抖动和失效处理

当前阶段无法通过 SDK/Aurea 完成电极权重、E-field 线性化、XY sensing area 和 Z 范围校准，因此 PC 版本增加一层固定的 `HostCalibrationProfile`。完整算法见[PC 上位机 XYZ 去耦合与抗抖设计](pc-host-only-xyz-filtering-design-2026-10-21.md)。

- 先按 `PositionValid/xyz_valid/report_error`、饱和边界和 sequence gap 做质量遮罩；
- 从固定 XY、只改变 Z 的真实采集拟合 `g_x(z)`、`g_y(z)`，计算 `xy_decoupled = xy_raw - coupling_xy(z)`；
- 对去耦合后的三轴信号做短窗口中值、一阶低通和 slew 限制；
- 只有旋律轴变化超过 dead zone 并持续 80–120 ms，才允许改变 Lead 音高；
- 纯 Z 运动、短时抖动和无效区不能产生新的音符；Z 仍可作用于音色和空间表达；
- 固定 `pitch_axis`、`b_min/b_max`、`q_ref` 和 PitchSpace 不能从单次录制重建。

- 位置低通使用短窗口中值/一阶 IIR；Lead 轨迹另做弧长重采样、单调约束和 Savitzky–Golay 平滑。
- 小于 dead zone 的变化视为静止；超过 slew 限制的跳变只按受限斜率输出。
- `PositionValid=false` 连续超过 100 ms 时停止追加当前采集，标记 `capture_degraded`，不凭空补点。
- 手离开时，Lead 结束当前段的释放；Touch/Tap 轨道结束当前事件，不生成重复事件。
- 设备断线时当前轨道进入 `FAILED`，不提交 shadow bank；active Loop 继续保留。恢复后必须显式 Resume。
- 校准、坐标变换、滤波参数和参考点都写入 CaptureSession 元数据，便于回放复现。

音频生成阶段只对 cutoff、包络、delay/reverb send、声像和有限 pitch bend 做 20–50 ms 的连续平滑；它不负责修复已经生成的错误音高。音高去耦合和抗抖必须发生在 EventTable 之前。

## 4. 生命周期

```text
IDLE
  -> WAIT_NEUTRAL
  -> LOCK_REFERENCE(x0,y0,z0)  # PLAY/形状参考；Lead 音高仍用固定 q_ref
  -> RECORD 或 PLAY
  -> RELEASE_REFERENCE
```

`STOP`、退出模式或用户执行“重新校准”会释放参考点。硬件校准只在设备稳定且没有正在录制的动作时执行。

## 5. 固定旋律空间约束

Lead 的固定旋律空间由引用文档 `pc-lead-intent-purification-design-2026-10-19.md` 的 `Fixed PitchSpace` 契约定义。坐标规范只负责提供稳定的 `q_app`、`q_ref`、固定轴方向和工作区边界；它不得通过锁存 `x0/y0/z0` 改变 Lead 的音高网格。

默认模式下，同一应用空间高度必须对应同一音级和注册区。Lead 的相对起点坐标只能用于路径形状、回撤、PLAY 包络、音色和调制。超出固定工作区时应饱和并产生诊断，不得自动取模换八度。

## 6. 验收要求

- 同一 raw capture 在相同 profile 下必须得到相同的局部坐标和诊断结果。
- 同一 raw XYZ、calibration profile 和 pitch profile 必须得到相同的 Lead 音级序列；改变录制起点不能静默重建音高网格。
- Lead 的 Z/深度变化不能导致注册区或八度自动跃迁。
- 校准动作不能改变 active event bank。
- 中心电极 Touch/Tap 不得被误报为坐标归零。
- 校准失败或位置失效必须可见、可回放、可诊断，而不是静默生成音符。

## 7. 相对光标模式（2026-10-22 增补）

演奏侧引入"相对光标"模式后，本规范第 5、6 节中**依赖绝对物理位置的音高不变量在该模式下不适用**：

- 音高不再由绝对 `q_app` 决定，而由光标位置决定：`cursor += gain(z) · Δq`，音高取 `cursor.y`。
- 因此「同一物理高度 → 同一音名」替换为「**同一光标高度 → 同一音名**」；同一物理高度的重复不再保证同一音名，但屏幕上看到的光标位置仍然决定结果，闭环不破。
- 抬高手臂（`z > 20000`）视为**抬起**，期间增量被丢弃、光标冻结；降到 `z < 16000` 重新接合。这与鼠标抬起换位同构，因此不需要"重基准"。
- 未进入相对模式的调用方仍适用原有不变量，两种模式必须在 session manifest 中显式区分，不能混用验收结果。

绝对模式与相对模式的完整对照见 [Z 耦合、相对光标与实时时间模型](mgc3130-z-coupling-clutch-rebase-realtime-design-2026-10-22.md) §9。
