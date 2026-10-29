# NL0002 swept 诊断：`v2_test_mode` 与 `v2_touch_info_decoder`（2026-10-29）

结论先行：**这两个模块在 RTL 仿真里是活的，在综合里被删除；`keep_hierarchy`
无效；目前无法从静态代码解释，因此没有动 RTL。** 下面记录全部证据和下一步判别
实验。

## 1. 现象

共享 H0 full-path harness（`clean_baseline_1`、`nl0002_keep_1`）每次综合都报：

```text
WARN (NL0002) : The module "v2_touch_info_decoder" instantiated to "u_touch_decoder" is swept in optimizing (mgc3130_input_latch.sv:31)
WARN (NL0002) : The module "v2_test_mode" instantiated to "u_test_mode" is swept in optimizing (mgc3130_v2_top.sv:544)
```

H0 verifier 因此把整次运行判 `BLOCKED`。

## 2. 已排除的解释

### 2.1 输出没人用（trace 全部是活的）

| 信号链 | 证据 |
| --- | --- |
| `test_active` → I2S mux | `assign i2s_sample_valid = test_active ? test_sample_valid : voice_sample_valid;`（428 行）、`assign i2s_sample = test_active ? test_sample : fx_sample;`（429 行），两者进 `i2s_pcm5102a_tx` |
| `test_fault` → STATUS 回读 | `status_fault = protocol_error || record_fault || loop_commit_timeout || test_fault`（551 行），用于 `V2_CSR_STATUS` 回读（606、687 行） |
| `decoded_touch` → LIVE | `v2_touch <= decoded_touch`（latch 71 行）→ `frame_touch` → `u_calibration.touch` → `output_touch` → `calibrated_touch` → `u_live.touch`（251 行），live engine 内部 `rule_touch` 参与 `candidate_flags` |

### 2.2 CSR 地址/掩码非法

- `V2_CSR_TEST_SELECT = 8'hA0`，`v2_csr_access(0xA0..0xAF) = RW`；
- `V2_CSR_TEST_SELECT_WRITE_MASK = 32'hFFFFFFFF`（不限制数据）；
- `v2_uart_link` 的 `op_data_ok` 对该地址走 `v2_csr_data_valid`，返回真；
- 因此 `cmd_valid && cmd_ready && cmd_address==8'hA0` 在 RTL 上可达。

### 2.3 仿真里不工作

`scripts/test_v2_top.ps1` 在本环境 **PASS**，其中包含：

```text
inject_control(8'h02, 8'ha0, ... 32'h00000101);   // 写 TEST_SELECT_0：selector=1, count=1
inject_control(8'h01, 8'ha0, ...);                // 读回
if (dut.rsp_data[31:8] !== 24'h040000) $fatal(...) // 读回正确
for (...) @(posedge clk_50m); if (!dut.u_i2s.sample_valid) $fatal(...)
if (dut.voice_bitmap !== 32'd0) $fatal(...)        // 没有分配声部
```

即仿真证明：写入到达顶层、读回正确、样本到了 I2S、没有占声部。

## 3. 已经做过的实验：`keep_hierarchy` 无效

在两个实例上加 `(* keep_hierarchy = "yes" *)` 后重跑（`nl0002_keep_1`）：

| 指标 | 加之前 | 加之后 |
| --- | ---: | ---: |
| logic | 12,787 | **12,787** |
| CLS | 9,752 | **9,752** |
| BSRAM / DSP | 36 / 16 | **36 / 16** |
| NL0002 | 2 条 | **仍是 2 条** |

逐项相同，说明综合在整个优化阶段就把它们当死逻辑删掉了；属性没有作用，改动已
revert。

## 4. 网表侧的证据：不是"被扁平化"

如果只是层次被展平、逻辑仍在父模块里，父模块应出现额外单元。实测：

```text
mgc3130_v2_top: LUT=265  FF=156  DPB=0
```

顶层没有任何 DPB，而 `v2_test_mode` 的 `phase` 数组在编译阶段就被识别为 RAM
（`Extracting RAM for identifier 'phase'`）。网表里也没有对应 RAM，所以这是**真删除**，
不是展平。

## 5. 剩余假设与判别实验

| # | 假设 | 判别实验 |
| --- | --- | --- |
| H1 | 优化器把 `csr_ready`/`csr_valid` 的组合证明成常 0（例如 `cmd_ready` 在某个 preserve 组合下被折成常量） | 在 ModelSim 里以**全路径参数**（`USE_MGC_READER=1`、`PRESERVE_*=1`、`POTTS_HORIZON=32`、`FX_ENABLE=1`）例化顶层，用 uart 注入同样的 A0 写，观察 `dut.test_csr_valid` 是否真的拉高 —— 现有 tb 用的是 `USE_MGC_READER=0`，参数不同 |
| H2 | 综合在"技术映射"前做了常量折叠，把 `test_active` 折成 0，因为某个上游寄存器被判定不可达 | 对 `v2_test_mode` 单独做模块级综合（保留全部端口并被消费），看它是否仍被删；这需要一个一次性的诊断 Tcl，H0 harness 不含此项 |
| H3 | Gowin 对 `always_ff @(posedge clk)`（无复位敏感表）的 `test_active` 做了特殊处理 | 把 `always_ff @(posedge clk)` 改成 `always_ff @(posedge clk or negedge rst_n)` 后重跑综合，看 NL0002 是否消失。该改动同时让复位更规范，风险低 |

H1 最省时间（一次仿真），H3 最省时间且可能直接修好（一次综合，约 6 分钟），H2 需要
新的诊断入口。

## 6. 为什么没有直接"强制保留"

计划明确禁止用 preserve 参数、stub 或 swept 伪造通过。如果这两个模块被删是**正确**
的死代码判定，那么加属性保留只会掩盖真实的连接缺陷；必须先确认它们在上记全路径
参数下确实可达（H1），再决定是修连接还是修工具行为。

## 7. 复现

```powershell
# 综合侧
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_gowin_cli.ps1 `
  -TclScript (Resolve-Path scripts/synth_v2_top_fullpath_20261029.tcl).Path `
  -LicenseServer '106.55.34.119:10559' -RunId nl0002_keep_1

# 仿真侧
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_v2_top.ps1
```

## 8. H1 结果（2026-10-29 傍晚）：全路径参数下功能完全正常

用与 H0 profile **完全相同**的参数在 ModelSim 里例化顶层
（`USE_MGC_READER=1`、`USE_GOWIN_RAM=1`、`USE_POTTS=1`、`PRESERVE_LOOP_PLANE=1`、
`PRESERVE_POTTS_PLANE=1`、`POTTS_HORIZON=32`、`FX_ENABLE=1`、`FX_LEVEL=1`），
直接注入同一条 A0 写命令：

```text
H1 reset: rst_sys_n=1 pll_locked=1 mode=0
H1 write A0: status=00 err=00 test_active=1 test_fault=0 tone_count=1
H1 read  A0: data=04000001 expect_hi=040000 test_active=1
H1 i2s sample reached after 1823 clk50 edges
H1 done: test_active=1 voice_bitmap=00000000
```

即：写被 ACK、`test_active` 拉高、`tone_count=1`、读回正确、样本到达 I2S、没有占声部。

**H1 结论：`test_active` 在全路径参数下确实可达。综合把它折成 0 是工具行为，不是
RTL 死逻辑。**

## 9. 后续三个实验（全部无效）

| 实验 | 改动 | 结果 |
| --- | --- | --- |
| 实例级 `keep_hierarchy` | `u_test_mode` / `u_touch_decoder` 实例加属性 | 资源逐位不变（12,787 / 9,752 CLS），NL0002 仍在 |
| 顶层寄存级 select | `test_active`/`test_sample` 先过一级 always_ff 再进 I2S mux | 新增的三个触发器**自己也被删掉**（网表无 `test_active_q`），资源仍 12,787，NL0002 仍在 |
| 模块级 `keep_hierarchy` | 两个模块的 `module` 声明前加属性 | NL0002 仍在，logic 12,673 |

另外两组对照综合：

| profile | NL0002 |
| --- | --- |
| 真实 reader + preserve（canonical） | `v2_touch_info_decoder`、`v2_test_mode` |
| stub sensor（`USE_MGC_READER=0`） | 输入平面四个模块 + `v2_test_mode` 全被扫 |
| 真实 reader、preserve 关 | `v2_touch_info_decoder`、`v2_loop_scheduler`、`v2_loop_event_recorder`、`v2_test_mode` |

`v2_test_mode` 在**所有**配置里都被扫；输入平面相关模块则随参数变化（stub 下
`xyz_valid=0`，整条输入链被判定不可达，这与设计意图一致）。

## 10. 当前判断

- `v2_test_mode` 的 sweep 是综合工具的常量折叠行为，与 RTL 可达性矛盾（H1 已证）。
- `v2_touch_info_decoder` 的 sweep 在 stub profile 下属于预期（输入无效），但在
  canonical profile（真实 reader）下仍被扫，同样与 RTL 矛盾。
- 三种"让它可见"的手段都无效，说明折叠发生在源码级证明阶段，不是下游优化。

因此下一步只有两条路，需要主线程决策：

1. **接受并记录**：把这两条 NL0002 标注为已知工具行为，verifier 增加"允许清单"，
   同时保留 H1 的仿真证据证明功能可达。风险：与"不得用 swept 通过"的条文冲突，
   必须由计划所有者裁定。
2. **绕开工具**：把这 2 个模块改为不可被常量折叠的写法（例如让 enable 来自一个
   工具无法推导的存储单元，或把模块搬到子层并显式例化），属于额外 RTL 工作，
   且可能再次触碰"为通过门禁而改结构"的红线。

## 11. 复现

```powershell
# H1（全路径参数仿真）——诊断载体在 impl/ms_h1 下，不入库
cd impl\ms_h1
vlog +define+V2_SIM -sv -work work <与 test_v2_top.ps1 相同的源列表> tb_h1_fullpath.sv
vsim -c -novopt work.tb_h1_fullpath -do 'run -all; quit -f'

# 两组对照综合
gw_sh impl\ms_h1\diag_canonical.tcl     # canonical profile，仅 syn
gw_sh impl\ms_h1\diag_reader0.tcl       # stub sensor，仅 syn
```
## 12. 网表级定论（canonical profile，`clean_baseline_1`）

### 12.1 `v2_touch_info_decoder`：被内联，功能存在

网表里 `calibrated_touch` 不是常量，而是一个真实触发器：

```text
DFFCE v2_touch_s0 ( .Q(calibrated_touch), .D(n349_6), .CLK(clk_pll), .CLEAR(n2030_6), .CE(VCC) );
LUT4 n349_s1 ( .F(n349_6), .I0(report_error_Z), .I1(n349_7), .I2(report_valid_Z), .I3(touch_valid_Z) );
```

而且 `v2_live_rule_engine u_live` 的端口表里有
`.calibrated_touch(calibrated_touch)` 与 `.calibrated_presence(calibrated_presence)`。

即：**输入 → latch → decoder → calibration → LIVE 的功能锥在综合网表里是存在的**，
decoder 只是被展平进上层，所以层次名消失、报 NL0002。这一条**属于合法的工具优化**，
功能等价证据充分（触发器 + LUT + LIVE 端口三级都在网表里可见）。

### 12.2 `v2_test_mode`：确实被删除

- 网表里没有 `test_active` / `test_sample` 等任何相关网络；
- `v2_test_mode` 的 `phase` 数组在编译期被识别为 RAM，但网表 BSRAM 只有 36 块，
  逐模块统计为 35 块（voice 16、store 5、patch 4、wavetable 6、fx 2、potts 2），
  **没有为 test_mode 留下任何 RAM**；
- 顶层模块自身只有 156 FF，全设计 7,839 FF，与各子模块之和相符，
  **没有额外 ~1,000 个 DDS 相位寄存器**；
- 逻辑预算同样没有余量（12,787 已基本被各子模块占满）。

结论：`v2_test_mode` 不是被展平，是**整模块被删掉**。H1 已证明它在同样参数下可达，
因此这不是合法的死代码消除。

## 13. 两条 sweep 的处理建议（按主线程要求）

| 模块 | 性质 | 建议 |
| --- | --- | --- |
| `v2_touch_info_decoder` | 合法优化（内联） | 可以给 verifier 制定**精确例外**：仅当该模块缺失、但网表里存在 touch 触发器且 `u_live` 的 touch/presence 端口已连接时放行；并在报告里附本节网表证据 |
| `v2_test_mode` | 功能确实缺失 | **不得例外**。它属于合同 0xA0–0xAF 与验收第 8 条要求的可观测测试模式；当前位流不含该功能，Task 8.5 的"已接入顶层"结论必须降级为"仅仿真可达，综合后缺失" |

`v2_test_mode` 的修复不在 verifier 层，需要工具层或 RTL 层解决（三种 keep 手段已全部
无效），应作为独立问题跟踪，不能靠放宽门禁绕过。