## Task 2：闭合 100 MHz 时钟和 48 kHz 音频时序

**Files**
- Create: rtl/v2_clock_gen.sv、rtl/v2_sample_scheduler.sv、sim/tb_v2_sample_scheduler.sv、scripts/synth_v2_clock.tcl、mgc3130_v2.sdc。

**Interfaces**
- v2_clock_gen(clk_in,rst_n,clk_sys_100m,pll_locked)。
- v2_sample_scheduler(clk_sys,rst_n,sample_ce,sample_index)。
- scheduler 用 32 bit 相位累加器，加入 48,000、与 100,000,000 比较并减回，产生 2083/2084 周期交替，长期平均精确 48 kHz。
- sample_ce 是唯一音频速率使能，禁止第二个自由运行 audio clock。

**Steps**
- [ ] Testbench 统计一秒内 48,000 个 sample_ce、校验总周期和 2083/2084 间隔。
- [ ] 先运行 scripts/test_v2_sample_scheduler.ps1 使测试失败，再实现。
- [ ] PLL 使用 Gowin 原语，V2_SIM 下旁路；实现 scheduler。
- [ ] 独立综合并记录 PLL lock、Fmax、时钟名。
- [ ] 增加 100 MHz、I2S/BCLK 约束，运行 git diff --check。
- I2S/BCLK 端口尚未出现在 V2 top：Task 2 只约束现有 50/100 MHz 时钟；I2S 同步输出时序约束必须在 Task 12 端口生成后验证，不能以异步虚拟时钟假装完成。
- [ ] 提交 feat: add verified v2 clock and sample scheduler。

**Stop gate:** 没有综合报告和 scheduler 仿真通过，不能声称 48 kHz 或计算声部预算。

---
