# Loop 存储接口与验证

实现：`rtl/loop_event_store.sv`、`rtl/loop_event_ram.sv`。
全部使用同一个 `clk`。复位输入 `rst_n` 异步置位；集成时由顶层保证同步释放。
容量为两个 bank，每 bank 4 轨，每轨 16 个 64 位事件，逻辑容量 1024 字节。

## 所有权与写入

- 播放端只能读取 active bank，不暴露任意 bank 读写选择。
- 写入只针对 shadow bank，在 `write_valid && write_ready` 的上升沿生效。
- `write_slot` 必须等于该轨当前 `record_count`，因此只追加、不覆盖已有事件。
- `record_count[track*5 +: 5]` 是 shadow 轨道的 0–16 计数，也是有效槽位范围。
- 复制和待提交期间写入背压；请求方须保持 valid 和数据，直到握手或显式取消。
- 满轨写入被拒绝并锁存该轨 `overflow`。普通忙等待不产生 overflow。
- 重置、ABORT、准备录音/叠加、成功提交清除溢出；CLEAR_TRACK 仅清除对应轨标志。

## 控制请求

`ctrl_valid/ctrl_ready` 握手接受 `ctrl_op[2:0]` 和 `ctrl_track[1:0]`。
请求方在握手前保持请求稳定，握手后撤销 valid，避免重复请求。
`ctrl_done` 是同一时钟域内的完成通知，控制器必须每拍采样并锁存需要对外报告的结果。
控制请求优先于写入；被背压的写入不得计作已录入事件。

| op | 名称 | 行为 |
| --- | --- | --- |
| 0 | PREPARE_OVERDUB | 将 active 的 64 个槽复制到 shadow，复制结束时发布有效计数 |
| 1 | CLEAR_TRACK | 清空 shadow 中选定轨道的有效计数 |
| 2 | CLEAR_ALL | 清空 shadow 的所有有效计数 |
| 3 | COMMIT_REQUEST | 冻结编辑，等待后续 `loop_boundary` |
| 4 | ABORT | 取消复制/待提交，清空 shadow 元数据，保留 active |
| 5 | PREPARE_RECORD | 复制 active 后将选定轨道清空，其余三轨保留 |
| 6–7 | 保留 | 完成但不修改数据；上层命令解析器须拒绝对外未知命令 |

复制耗时 128 个时钟（50 MHz 下 2.56 微秒），完成才产生 `ctrl_done`。
COMMIT_REQUEST 的 `ctrl_done` 只表示提交已挂起，真正换 bank 由 `commit_ack` 表示。
`busy` 覆盖复制和待提交阶段。ABORT 控制命令在忙时仍可握手。

独立 `abort` 是恢复控制器的同域优先级取消信号，不需要等待 ready。
优先级：复位 > abort/ABORT > 挂起的边界提交 > 复制 > 普通控制 > 写入。
`abort` 为高时不接受新的控制或写入。取消不会终止 active 的播放读取。

## 提交与清除语义

只交换已挂起的请求。COMMIT_REQUEST 与边界同拍时，等待下一个边界。
交换时旧 active 成为新的空 shadow；`active_valid` 表示新 active 是否含有效事件。
空 bank 也允许提交，以支持清除最后一轨/CLEAR_ALL。
**空录音不提交**属于模式控制策略：控制器必须发送 ABORT，不能发送 COMMIT_REQUEST。

用户层 CLEAR_TRACK/CLEAR_ALL 仍只允许 IDLE；这些底层操作只编辑 shadow。
清除一轨的事务为复制 active → 清除目标 shadow 轨 → 提交。
清除全部为清空 shadow → 提交。IDLE 下控制器需要提供明确的安全提交边界，
不能等待已停止的节拍器自行产生边界。此控制器尚未集成。

## 同步读时序

在上升沿采样 `read_enable/read_index`，该沿之后输出 `read_valid`、
`read_slot_valid` 和 `read_data`，下游在下一上升沿使用；可每拍发起一次读取。
不存在输出背压，下游只在能够接收下一拍结果时发起请求。
空槽或未发起读取时返回 slot_valid=0、data=0。
换 bank 的上升沿取消该沿读取（read_valid=0）；调度器必须在提交后重新发起读取。
reset/abort/clear 不批量清 RAM，通过有效计数遮蔽旧内容。

## Gowin 实现选择

`USE_GOWIN_RAM=1`（默认）直接封装 GW5A `DPB` 硬宏；不是伪造的生成器 `.ipc`。
四个 16 位真双口 lane 提供一次读取完整 64 位事件，物理占用 4 块 BSRAM。
每 lane 物理深度 1024，仅使用前 128 字，优先保证双端口带宽和固定单拍读延迟。
`READ_MODE0/1=0`、`WRITE_MODE0/1=00`，写操作不改变读输出。
GW5A 的地址低两位是字节写使能，固定为 `11`；高十位是字地址。
同地址双读允许；同地址涉及写入的双端口冲突不允许，由 bank 所有权避免。

`USE_GOWIN_RAM=0` 提供同延迟 RTL 模型，内容未初始化，不依赖上电零值。
官方模型来自本机 Gowin `simlib/gw5a/prim_sim.v`，脚本支持路径参数，不复制厂商库。

## 验证与范围

```powershell
.\scripts\test_loop_store.ps1 -ModelSimBin 'C:\modeltech64_10.6d\win64'
& 'C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe' scripts/synth_loop_store.tcl
```

ModelSim 测试包含 RAM 128 地址与四个 lane、两端口读写、读输出保持，
以及存储四轨填满/拒绝、完整复制时播放、覆盖录音保留其他轨、边界提交、
取消复制/取消提交、空提交、清空、写入背压、控制仲裁和复位后屏蔽旧 RAM。
相同 store testbench 分别运行 RTL 模型和官方 DPB 模型。

独立综合使用 `impl/loop_store_synth/`，不修改已有音频顶层或板上位流。
首次独立综合资源：586 LUT（报告 Logic 栏）、61 寄存器、4/56 BSRAM、无 latch。
这是综合结果，尚不是集成后的布局布线时序结果。
模块已加入工程文件，但尚未实例化进演奏顶层；不表示四轨 Loop 已可上板演奏。
