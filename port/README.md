# port/ —— 6.18 适配迭代区

闭源驱动从 6.6/6.12 搬到主线 6.18，无法一次到位。先分清两类文件所处的
"树"，决定了补丁的应用时机：

```
immortalwrt checkout（本仓库 overlay 时可见）
├── package/mtk/...                 ← 驱动源码在 checkout 里，可当场 patch
├── target/linux/mediatek/dts/...   ← 设备 DTS（OpenWrt 侧）同理
│   （mt7987.dtsi / mt7987a-hiveton-h5000m.dts 都在这里，可当场 patch）
└── target/linux/mediatek/patches-6.18/   ← 内核补丁只"装载"，构建期 quilt 应用
        └──（构建时）→ 解压的内核源码 staging_dir/target-*/linux-*/
```

## 目录约定

| 目录 | 作用对象 | overlay 时行为 | 失败表现 |
|---|---|---|---|
| `port/kernel/*.patch` | 解压后的内核树（drivers/、arch/ 等） | **拷贝**进 `patches-6.18/`，**优先于上游同名补丁** | 构建期 quilt 打不上 → `内核准备` 步骤失败，日志有 `.rej` |
| `port/repo/*.patch` | checkout 侧文件（package/mtk、target DTS） | **当场应用**（严格模式），支持 `# port-stack: wifi7\|legacy` 声明 | overlay 步骤立即失败并指名补丁；栈不符的补丁跳过 |

栈声明用于两类平台的差异补丁：`H5000M*` 走 `wifi7`（pdn 的 `mt_wifi7`），
`AP3000M*` 走 `legacy`（chasey 的 `mt_wifi`，整个 `drivers/` 被替换）。
例如 `port/repo/0001-mtwifi7-config-in-*` 只对 `mt_wifi7/config.in` 生效，
在 legacy 栈下该路径不存在，必须跳过而不是判失败。

同名覆盖是刻意设计：`port/kernel/999-eth-91-*`、`999-hnat-02-*`、`999-hnat-07-*`
与 chasey 上游文件同名，overlay 先拷本仓库版本，再补入上游其余文件时自动跳过，
因此这三处 6.18 适配不需要另起编号。

## 上游补丁的搬运边界

overlay 只搬 chasey 的两类补丁：

- `999-eth-91-*`（`mtk_eth_soc` 挂载 mtkhnat 的钩子，含 Kconfig/Makefile）
- `999-hnat-*`（nf_flow_table / 8021q / bridge / pppoe / dsa / macvlan 卸载路径）

**`999-dts-*` 一律不搬。** 它们以上游 6.12 的 `mt7981b.dtsi`（含 `wdma@15104800`、
`ap2woccif@151a5000`）、`mt7986/7987/7988` 的 rfb 板级节点为上下文；6.18 的
DTS 里这些节点已不存在或被重构，搬运只会得到必然失败的补丁，并让整个
`target/linux` 编译在第一个 DTS 补丁处中断（历史运行即卡在
`999-dts-mt7981-rfb-05-...-mtkhnat-driver-support.patch`）。

HNAT 的 DTS 节点改由本目录直接维护：

| 补丁 | 作用 |
|---|---|
| `port/kernel/999-dts-mt7981-hnat.patch` | 6.18 的 `mt7981b.dtsi`（经 `117-complete-mt7981b-dtsi` 补全后）在 `ethsys` 之后挂 `hnat: hnat@15000000`（`mtk-hnat_v4`，默认 disabled） |
| `port/repo/002-mt7981-ap3000m-enable-hnat.patch` | AP3000M 启用：wan=`eth1`、lan 前缀 `lan`、max-gmac=2 |
| `port/repo/003-mt7987-hnat-node.patch` | `mt7987.dtsi`（仓库内文件）挂 `hnat: hnat@15000000`（`mtk-hnat_v5`，默认 disabled） |
| `port/repo/004-mt7987-h5000m-enable-hnat.patch` | H5000M 启用：wan=`eth1`、lan 前缀 `lan`、max-gmac=2、ppe-num=2 |

> 端口绑定（`mtketh-wan` / `mtketh-lan`）取自 mtkhnat 在 MTK 参考板上的取值，
> **尚未实机复核**。若 H5000M / AP3000M 的 WAN 口实际不是 `eth1`，HNAT 会把
> 方向判错（表现为加速不生效或统计异常），需要按实机 `ip link` 结果改
> `mtketh-wan`。

## 6.18 适配记录

| 补丁 | 断点 | 处理 |
|---|---|---|
| `999-eth-91-*` | 错误路径在 6.18 已重构：`free_netdev(eth->dummy_dev)` / `mtk_napi_del()` / `mtk_release_all_muxes()` 均不存在，hunk 8 整体失败 | 改用最小上下文锚定 `err_deinit_ppe`，只保留 HNAT 接管 PPE 生命周期的条件编译 |
| `999-hnat-02-*` | 6.18 的 `mtk_eth_soc.h` 没有 `MTK_FE_INT_STATUS2 0x28`（原 hunk 的锚点） | 挂到 `MTK_FE_INT_ENABLE` 之后，并用 `#ifndef` 保护，避免与上游重复定义 |
| `999-hnat-07-*` | `dsa_user_netdev_ops` 在 6.18 新增 `ndo_hwtstamp_get/set`，原 hunk 以 `};` 紧跟 `ndo_fill_forward_path` 为上下文 | 以 hwtstamp 字段为后置上下文插入 `ndo_flow_offload_check` |
| `999-hnat-09-*` | `ip6_tnl_netdev_ops` 的成员表在 immortalwrt 6.18 里与 6.12 不同，`net/ipv6/ip6_tunnel.c` 的 hunk 3 整体失败 | hunk 3 改为 `ndo_get_iflink` 单行前置上下文 + 结构收尾，其余 hunk 原样 |
| Kconfig（非补丁） | `999-eth-91` 引入 `MEDIATEK_NETSYS_V2/V3`、`NET_MEDIATEK_HNAT` 三个新符号，内核 `.config` 无默认值 → `syncconfig` 以 `(NEW)` 交互提问，非交互环境 Error 1 | `kmod-mediatek_hnat` 的 KCONFIG 按栈补 NETSYS 代际（wifi7→V3 / legacy→V2）；`CONFIG_NET_MEDIATEK_HNAT` 保持不带值（=m，产出 `mtkhnat.ko`） |
| `999-hnat-03/04/05/06/08/12/14/15` | 无（offset/fuzz 内可直接应用） | 原样搬运 |

以上适配在 upstream v6.18 源码上以 `patch -p1` 逐个验证过（含 hunk 级）；与
immortalwrt 6.18 树的差异主要落在 `mtk_eth_soc.c/.h`，仍以 CI 的
`kernel-prepare.log` 为准。

## 迭代闭环

```
Actions 构建
   ├─ overlay 步骤：port/repo 应用失败 → 立即修（本目录补丁写错目标）
   └─ 编译失败 → 下载 reports-* 看 parallel.log / serial.log（含 quilt .rej）
        ▼
在 port/kernel/ 或 port/repo/ 写正式适配补丁 → 提交 → 下一轮
```

> 试过在 world 之前单跑 `make target/linux/prepare` 做补丁预检，想把它当成
> "数分钟暴露断点"的捷径；实测首次运行（缓存未命中）在 `tools/install` 上就
> 跑了 79 分钟，反而比它要省的 40 分钟更久，已回退。

## 已知断点清单（后续重点观察）

1. `mtk_hnat` 编译：`999-eth-91-*` 已能在 6.18 应用，但 `struct mtk_mac` /
   `hw_lro` 等符号面是否与 6.18 的 `mtk_eth_soc` 对齐，要看编译日志。
2. DTS 端口绑定：见上表"尚未实机复核"。
3. `mt_wifi`（7.6x）/ `mt_wifi7`（7.9x）：os_glue 的 timer/workqueue/netlink
   在 6.13+ 的 API 变更；`conninfra`/`warp` 随动 → `port/repo/`。
4. WED：mt_wifi7 的 whnat 与主线 `mtk_wed` 的符号面需要核对。

## 打补丁规范

- 命名：`NNNN-<子系统>-<一句话>.patch`，编号分段：
  `01xx` 内核核心、`02xx` eth/hnat、`03xx` wifi 驱动、`04xx` DTS。
  覆盖上游同名补丁的三处（`999-eth-91`、`999-hnat-02`、`999-hnat-07`）保留原名。
- 一个逻辑修一个补丁，补丁头写明上游断点（如 `net: flow: 6.18 移除 xxx API`）。
- `port/kernel/` 的补丁在 `staging_dir/target-*/linux-*/` 内核树上验证过再提交
  （本地可在 `make target/linux/{clean,prepare} V=s` 后于 quilt 环境迭代）。
