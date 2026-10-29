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
