---
name: gowin-plan-driven-rtl
description: >
  Run long, plan-driven RTL development on Gowin FPGAs with TCL scripts.
  Use when a project has a multi-task plan document and the work spans days:
  read one task, write a failing test first, implement, simulate in ModelSim,
  synthesise and place-and-route through gw_sh with a per-task TCL script,
  parse the report for real numbers, then commit with evidence. Covers the
  Gowin specific traps (implicit RAM inference, Q16.16 not mapping to DSP,
  PLL and SDC wiring) and the escalation order when timing does not close.
  Trigger: "按计划推进 RTL", "长流程 FPGA 开发", "gowin tcl 流程", "run the plan task".
---

# 按计划推进的高云 RTL 开发流程

这份 skill 描述**一个人或 agent 在数天内、按计划文档逐任务推进** RTL 的做法。
它不教 Verilog 语法，只规定流程、证据和失败处理。

## 1. 每次开工前

```text
1. 读计划文件，找到下一个未关闭的 Task
2. 读该 Task 的 Files / Interfaces / Steps / Stop gate
3. 读它的 As-built status，确认哪些已经做了
4. 确认当前工作区干净（或知道哪些改动是本任务的一部分）
```

**禁止**：跳过 Stop gate 直接做后面的任务；把估算当成证据。

## 2. 单个 Task 的固定循环

```text
① 先写会失败的测试（Python 参考或 SV testbench）
② 运行，确认失败原因与缺失实现对应
③ 写 RTL，最小可用
④ ModelSim 仿真，与 Python 参考逐帧比对
⑤ 独立综合（单模块 tcl），记录 LUT/FF/DSP/BSRAM
⑥ 接入顶层，跑 P&R，读报告
⑦ 更新 as-built 表与验证报告
⑧ 提交：一句 feat/fix + 证据摘要
```

**第 ① 步不可省**：没有失败测试就先写 RTL，等于没有验收标准。

## 3. TCL 脚本模板（每个 Task 一个）

放在 `scripts/synth_<module>_<date>.tcl`，内容固定四段：

```tcl
# 1. 工程与器件
set_device GW5A-LV25MG121NES
set_option -top_module <module>
add_file -verilog rtl/<module>.sv
add_file -verilog rtl/v2_contract_pkg.sv

# 2. 约束
add_file -sdc <constraint>.sdc

# 3. 综合与 P&R
run syn
run pnr

# 4. 输出
set_option -output_base <impl_dir>
```

调用方式（PowerShell，本机已验证）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
  -TclScript scripts/synth_<module>_<date>.tcl
```

**记录三项**：命令、tcl 路径、输出目录、退出码。

## 4. 报告必读字段

```text
Fmax（实际，不是约束值）
setup violated endpoints / hold violated endpoints
setup TNS / hold TNS
Logic / FF / DSP / BSRAM(DPB) 用量
PLL 使用数
```

**只报"约束 100 MHz"没有意义，必须报"实际 Fmax xx.x MHz"。**

## 5. 高云特有的四个坑

### 坑 1：变量索引数组不会被推断成 RAM

```verilog
logic [31:0] phase [0:31];  phase[slot] <= ...;   // 变量索引
```

若工具把数组放进寄存器：**BSRAM 用量为 0，FF 暴涨，Fmax 腰斩**（本项目实测 58 MHz vs 100 MHz）。

**解法**：显式实例化 `DPB`（双口块 RAM）或 `SDPB`，地址接线，同步读 1 拍。
参考工具安装目录下的 `prim_syn.v` 与 UG285。

### 坑 2：Q16.16 定点不映射 DSP

Gowin 的 DSP 是 18×18 整数乘法器，**不认定点小数**，会用 LUT 拼出长进位链。

**解法**：改写成整数乘 + 后移位；或显式用 DSP 原语。

### 坑 3：SDPB 与 DPB 行为不同

```text
DPB  ：双口，读写可同时；16 位端口，宽数据要拆 lane
SDPB ：单口，写后需等一拍才能读
```

选错会导致"仿真对、上板错"。

### 坑 4：PLL 与跨时钟

```text
50 MHz 板载 → PLL ×20/10 → 100 MHz
48 kHz 不是整数分频 → 必须用分数累加器产生 sample_ce
```

**不要用第二个自由运行的音频时钟**（会引入 CDC）。前端慢逻辑改用多周期 FSM。

## 6. 时序不收敛时的标准顺序

**严格按此顺序**，不要跳步：

```text
1. 切流水（把一个组合块拆成两级寄存器）        ← 收益最大
2. 降位宽（24 位够就不用 32 位）
3. 改多周期 FSM（慢路径允许 2–8 拍完成）
4. 显式 RAM（替换变量索引数组）
5. 减并行（DSP/加法器数量）
6. 最后才降频（并重算每样本拍数预算）
```

**降频是最后手段**：它会让每样本拍数变少，可能需要减少声部或砍 FX。

## 7. 证据要求

| 结论 | 需要的证据 |
| --- | --- |
| "模块功能正确" | ModelSim 日志 + 逐帧比对通过 |
| "时序收敛" | P&R 报告的 Fmax 与 slack，且违例数为 0 |
| "资源够用" | 综合报告的 LUT/FF/DSP/BSRAM 实际值 |
| "延迟达标" | 板级测量（示波器或 GPIO 打点） |
| "可交付" | bitstream 文件 + SHA-256 |

**没有证据的结论只能写"估算"，不能写"已实现"。**

## 8. 提交纪律

```text
· 每个 Task 一次提交，信息里带证据摘要（Fmax、测试数、bitstream 哈希）
· 文档与 RTL 同一次提交（避免代码与说明脱节）
· 不提交仿真产物、modelsim 目录、临时探针脚本（加 .gitignore）
· 保留最终版探针脚本，删除 timed1..N 的中间版本
```

## 9. 与其他 skill 的关系

```text
superpowers:executing-plans      提供任务循环的通用框架
gowin-plan-driven-rtl（本 skill）提供高云工具链、报告字段、坑与时序升级顺序
```

两者叠加使用：外层按计划推进，内层按本文的循环与证据要求执行。

## 10. 本项目已有的可复用脚本

```text
scripts/run_gowin_cli.ps1        CLI 入口（license、工作目录、退出码）
scripts/gw.sh                    Git Bash 包装
scripts/synth_v2_top.tcl         顶层综合模板
scripts/test_v2_contract.ps1     Python/SV 双端契约校验
```
