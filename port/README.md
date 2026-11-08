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

## HNAT 增强功能（原上游 51xx 系列）

上游 6.12 的 HNAT 增强补丁按功能拆成三组，本仓库全部按 6.18 的接口重新落位，
不再以"缺少前置补丁"为由跳过：

| 补丁 | 功能 | 6.18 处理 |
|---|---|---|
| `999-hnat-26` | PPE 表项数量按代际切换 | 原样命中，未改上下文 |
| `999-hnat-27` ~ `999-hnat-29` | debugfs：hook 开关读取、绑定速率字段、统计摘要 | 原样命中 |
| `999-hnat-30` / `31` | debugfs：PPD 属性集、wan/lan 属性集 | 原样命中 |
| `999-hnat-32` | rx ppd（接收侧直通设备） | 原样命中，依赖 `999-hnat-40` 提供的 `g_rx_ppdev` |
| `999-hnat-33` / `34` | 外接设备 ingress 钩子、网卡名前缀匹配 | 原样命中 |
| `999-hnat-35` | 非 L2 桥报文跳过 FDB 检查 | 原样命中 |
| `999-hnat-36` | 绕过 GE 口的 PPD 载波检查 | 原样命中 |
| `999-hnat-37` | 内核依赖改为通用 nf nat | 原样命中 |
| `999-hnat-38` | NETSYS_V2 上启用 wifi hook 的 tx hqos | 原样命中 |
| `999-hnat-39` | 外接设备报文固定从 PSE 第三口转发 | 重写：6.18 的 `mtk_tx_map_info()` 统一写描述符，把 `skb` 传进去并在 `mtk_tx_set_dma_desc()` 之后覆盖 fport 位段（两个调用点都改） |
| `999-hnat-40` | 收回报文交还 rx ppd 设备 | 重写：6.18 的 `mtk_poll_rx()` 按 sport 选 netdev，QDMA_TX/WDMA 口在 switch 里置位，netdev 选择处直接取 `g_rx_ppdev` |
| `999-hnat-41` | HNAT 侧 QDMA 队列数 | 新写：6.18 用 `struct mtk_soc_data::num_tx_queues` 描述队列总数，`MTK_QDMA_NUM_QUEUES` 已移除；选队列、建调试节点、校验 qid 三处改读真实值，未初始化时回退页内队列数 |
| `999-hnat-24` | 组播表项按代际写 NPU 落点 | 新写：`tport_id`/`tops_entry` 只在 V3 表项布局存在，按 `CONFIG_MEDIATEK_NETSYS_V3` 分支，并以 `hnat_data->mcast` 能力位拒绝 V2 的卸载请求 |
| `999-hnat-25` | 802.1Q tag proto 判定 | 新写：外接交换机 tagger 的 proto 收进其 Kconfig 条件，未编入 tagger 时判定退化为纯 8021Q |

一条不再按"未落地"处理，一条仍有明确边界：

- **QDMA 64 TXQ**：6.18 基线已经把队列数改成按 SoC 描述
  （`struct mtk_soc_data::num_tx_queues`），并用 `MTK_QTX_PER_PAGE` 分页访问
  QDMA 寄存器窗口。MT7987 的队列总数是 32，不是 64；所谓"64 队列"是别的
  SoC 的上限，硬把它写成全局 64 会让超出总页数的队列落到同一组寄存器。
  正确做法是让驱动读 SoC 描述值，已由 `999-hnat-41` 落地。
- **V2 关闭 tnl 出口字段**：该改动保护的是 TX 描述符里的 tport/tops_entry/cdrt
  位段，这三个位段由上游 eth 系列的 crypto-tx / tnl-offload 补丁写入；6.18 的
  `mtk_tx_set_dma_desc_v2()` 根本没有这几个字段（`txd7`/`txd8` 恒为 0），
  没有需要按代际关闭的写入路径。

## 6.18 适配记录

| 补丁 | 断点 | 处理 |
|---|---|---|
| `999-eth-91-*` | 错误路径在 6.18 已重构：`free_netdev(eth->dummy_dev)` / `mtk_napi_del()` / `mtk_release_all_muxes()` 均不存在，hunk 8 整体失败 | 改用最小上下文锚定 `err_deinit_ppe`，只保留 HNAT 接管 PPE 生命周期的条件编译 |
| `999-hnat-02-*` | 6.18 的 `mtk_eth_soc.h` 没有 `MTK_FE_INT_STATUS2 0x28`（原 hunk 的锚点） | 挂到 `MTK_FE_INT_ENABLE` 之后，并用 `#ifndef` 保护，避免与上游重复定义 |
| `999-hnat-07-*` | `dsa_user_netdev_ops` 在 6.18 新增 `ndo_hwtstamp_get/set`，原 hunk 以 `};` 紧跟 `ndo_fill_forward_path` 为上下文 | 以 hwtstamp 字段为后置上下文插入 `ndo_flow_offload_check` |
| `999-hnat-09-*` | 6.18 没有 `ndo_ip6_tnl_flow_offload`，`ip6_tnl_netdev_ops` / `ipip6_netdev_ops` 的成员表也与 6.12 不同；且 6.18 的 `tnl->dev` 指向隧道设备自身 | 回调改挂 `ndo_flow_offload_check`；只置 `DEV_PATH_DSLITE`/`DEV_PATH_6RD` 类型位并记下 `virt_dev`，不再用自指的 `path->dev` |
| Kconfig（非补丁） | `999-eth-91` 引入 `MEDIATEK_NETSYS_V2/V3`、`NET_MEDIATEK_HNAT` 三个新符号，内核 `.config` 无默认值 → `syncconfig` 以 `(NEW)` 交互提问，非交互环境 Error 1 | `kmod-mediatek_hnat` 的 KCONFIG 按栈补 NETSYS 代际（wifi7→V3 / legacy→V2）；`CONFIG_NET_MEDIATEK_HNAT` 显式写 `=m`（裸符号不会进覆盖项，且必须是模块才产出 `mtkhnat.ko`） |
| `999-hnat-03/04/05/06/08/12/14/15` | 无（offset/fuzz 内可直接应用） | 原样搬运 |
| `999-hnat-11-*` | 基线 `pending-6.18` 已把 `DEV_PATH_IEEE80211` 追加在 `DEV_PATH_MTK_WDMA` 之后 | 三个新成员追加在枚举末尾，既有成员取值不变（路径类型同时是 `flags` 的位号） |
| `999-hnat-16-*` | 6.18 已去掉全局 `MTK_QDMA_NUM_QUEUES`，改为 `MTK_QTX_PER_PAGE` 分页 | 只补 `MTK_QDMA_QUEUE_MASK`，取值按页内队列数（`MTK_QTX_PER_PAGE - 1`），`#ifndef` 保护 |
| `999-hnat-17-*` | 6.18 没有 `drivers/net/ethernet/mediatek/mtk_eth_dbg.h` | 只删 `hnat_debugfs.c` 里对该头文件的引用；`hnat_nf_hook.c` 需要的 `mtk_eth_reset.h` 由 `999-hnat-23` 提供 |
| `999-hnat-21-*` | `ppp_channel_ops` 在 6.18 没有 `flow_offload_check`（由 `999-hnat-06` 引入）；`session->tunnel` 可能为 NULL | 回调按真实成员表落位；取 tunnel 前先 `READ_ONCE` 快照并判空 |
| `999-hnat-23-*` | 6.18 的 `mtk_pending_work()` 在 `mtk_hw_init(eth, true)` 之后立即重开设备 | 在两者之间广播 `MTK_FE_RESET_NAT_DONE`，事件号放进新建的 `mtk_eth_reset.h` 供两侧共用 |
| `999-hnat-24/25/39/40` | 见上节表格 | 按 6.18 结构新写 |

验证方式：必须按 quilt 的真实顺序重建目录——先铺 `files/`、`files-6.18`
（`Kernel/Patch/Default` 是"先覆盖文件，再打补丁"），再依次应用
`generic/backport-6.18`、`generic/pending-6.18`、`generic/hack-6.18`、
`mediatek/patches-6.18`，最后按编号 `patch -p1 --fuzz=0` 我方 41 条，全部命中。
只在"纯 6.18.55"上验证会漏掉基线补丁对这些文件的改写（例如 `netdevice.h`
的 `DEV_PATH` 枚举、`mtk_eth_soc.c` 的 TX 写描述符路径），补丁在实树里必然失败。
随后用 aarch64 交叉工具链对 17 个关键对象逐个 `make <obj>.o`，全部通过
（`mtk_eth_soc.o`、6 个 `mtk_hnat/*.o`、`skbuff.o`、`vlan_dev.o`、`sit.o`、
`ip6_tunnel.o`、`ip_gre.o`、`vxlan_core.o`、`l2tp_core.o`、`l2tp_ppp.o`、
`pptp.o`、`ppp_generic.o`）。CI 侧仍以 `kernel-prepare.log` 为准。

## 编译期约束：NETSYS 代际符号必须是 bool

`CONFIG_MEDIATEK_NETSYS_V2/V3` 若定义成 tristate，在 `CONFIG_NET_MEDIATEK_SOC=m`
的配置下会被 kconfig 钳制为 `m`，`autoconf.h` 里只剩 `CONFIG_MEDIATEK_NETSYS_V2_MODULE`；
而闭源 HNAT 源码通篇用 `#if defined(CONFIG_MEDIATEK_NETSYS_V2)` 选表项布局，结果
是"编译通过、寄存器布局按 V1 解读"。因此两个符号在 `999-eth-91` 里是 `bool`，
`Scripts/verify-port.sh` 与 `.github/scripts/verify-artifacts.sh` 都按 `=y` 断言。

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

1. `mtk_hnat` 编译：本机 6.18.55 交叉编译已 17/17 通过；CI 侧仍需看
   `kernel-prepare.log`，差异预计集中在 immortalwrt 额外带的 `mtk_eth` 补丁上。
2. DTS 端口绑定：见上表"尚未实机复核"。
3. `mt_wifi`（7.6x）/ `mt_wifi7`（7.9x）：os_glue 的 timer/workqueue/netlink
   在 6.13+ 的 API 变更；`conninfra`/`warp` 随动 → `port/repo/`。
4. WED：mt_wifi7 的 whnat 与主线 `mtk_wed` 的符号面需要核对。
5. 外接交换机（802.1Q tag 判定）：6.18 未移植其 tagger 与驱动，判定按
   `CONFIG_NET_DSA_TAG_MXL862_8021Q` 条件编译；要支持该芯片需整组移植。 

## 打补丁规范

- 命名：`NNNN-<子系统>-<一句话>.patch`，编号分段：
  `01xx` 内核核心、`02xx` eth/hnat、`03xx` wifi 驱动、`04xx` DTS。
  覆盖上游同名补丁的三处（`999-eth-91`、`999-hnat-02`、`999-hnat-07`）保留原名。
- 一个逻辑修一个补丁，补丁头写明上游断点（如 `net: flow: 6.18 移除 xxx API`）。
- `port/kernel/` 的补丁在 `staging_dir/target-*/linux-*/` 内核树上验证过再提交
  （本地可在 `make target/linux/{clean,prepare} V=s` 后于 quilt 环境迭代）。
