# CHANGELOG

## [Unreleased]

### Added

- 新增独立的 `mainline/` 构建路线，固定 ImmortalWrt `73bc086a62f951d96e5d7404f04c4d73e141cad2` 与 mt76 `0936617dc529ff9da0385221d3fa6de732231177`。
- 新增 H5000M MT7992 variant 23 固件配置，以及 AP3000M MT7976 DBDC/MT7981 WO 固件配置。
- 新增自写 `mt7996` TX-only WED 补丁：保留 TX WED/AMSDU，无 WO 时恢复 CPU RX reorder，并修正 RRO 启动、复位恢复和 RX 统计分支。
- 新增模块参数与防火墙硬件流表默认配置：`mt7996e wed_enable=1 wed_rro=0`，`mt7915e wed_enable=1`。
- 新增 `mtwifi-offload-status`，输出 WED、PPE、conntrack、flowtable 与 USB netdev checksum/TSO/GSO/GRO 状态。
- 新增跨 Windows/WSL 与 Linux 的构建入口和静态校验脚本。
- 新增独立的 `mainline-mt76.yml`，支持手动编译 H5000M、AP3000M 或全部设备，并校验模块、固件、模块参数和 profile 约束。
- 两台 profile 显式关闭无关的 `bridger`，避免连带构建 LLVM/BPF 工具链。

### Verification

- [x] 全部新增文件保持 LF。
- [x] profile、包内容、模块参数、补丁文本与 shell/JavaScript 语法检查通过。
- [x] 自写补丁已对固定 mt76 源文件执行真实 `git apply --check`。
- [x] H5000M 重新生成 defconfig 后，`bridger`、`NEED_BPF_TOOLCHAIN`、`USE_LLVM_BUILD` 均未选中。
- [ ] `mainline-mt76.yml` 手动触发并完成真实构建。
- [ ] H5000M mt76 模块真实编译完成。
- [ ] H5000M 与 AP3000M 完整镜像构建及产物检查完成。
- [ ] AP3000M 真实 defconfig 与完整 WED/WO RRO 实机计数器验证完成。
- [ ] H5000M TX WED/PPE 与 USB 设备级 offload 实机验证完成。

### Boundaries

- `mainline/` 是固定版本主线 GPL mt76 驱动加自写集成补丁，不是从零逐行重写驱动。
- 该路线使用独立 CI workflow，不修改现有闭源驱动 workflow。
- MT7987 没有可验证的 WO 固件与设备树资源，H5000M WiFi RX 不宣称硬件卸载。
- 当前主线 PPE 不支持普通 USB netdev 绕过 CPU 的硬件 NAT；USB 侧只验证设备自身 offload 能力与软件流表。
