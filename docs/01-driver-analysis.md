# 01 · MTWIFI 闭源驱动原始分析（H5000M 参考样本）

> 数据来源：H5000M 原厂风格固件（发行版标识 Mwrt @Manper-5.1.1150-24，基线
> ImmortalWrt-mt798x-24.10-SNAPSHOT，内核 **6.6.94**，mediatek/filogic）中
> 实际随附的闭源内核模块二进制。分析工具：modinfo / nm。
> 本文所有结论可复核（模块文件保留在分析环境，方法见附录 A）。

## 1. 模块清单与依赖图

| 模块 | 体积 | License | depends | 未解析符号数 |
|---|---|---|---|---|
| `mt_wifi.ko` | 13.4 MB | **Proprietary** | `mt_wifi_cmn, mtkhnat` | 186 |
| `mt_wifi_cmn.ko` | 17 KB | Dual BSD/GPL | — | 39 |
| `mtkhnat.ko` | 206 KB | **GPL v2** | — | 107 |
| `mtk_warp.ko` | 287 KB | Dual BSD/GPL | `mtkhnat` | 78 |
| `mtk_wed.ko` | 18 KB | Dual BSD/GPL | `mtk_warp, mtk_hwifi` | 37 |

```
            ┌──────────────┐
            │   mt_wifi    │  无线主驱动（全部芯片代码，Proprietary）
            └──┬───────┬───┘
               │       │
      ┌────────▼─┐   ┌─▼─────────┐
      │mt_wifi_cmn│  │  mtkhnat  │  硬件 NAT（GPL v2，netfilter hook）
      └──────────┘   └─┬───────┬─┘
                       │       │（warp 依赖 hnat）
              ┌────────▼─┐  ┌──▼─────┐
              │ mtk_warp │  │(netfilter/netdev notifier)
              │ (WED 引擎)│  └────────┘
              └────┬─────┘
              ┌────▼─────┐
              │ mtk_wed  │  WED 总线 glue（warp_* 私有接口）
              └──────────┘
```

**关键事实（影响移植策略）：**

1. **vermagic = `6.6.94 SMP mod_unload aarch64`，无 modversions** ——
   原厂构建未开启符号 CRC 校验，模块按符号名链接。
2. **mt_wifi 无 cfg80211/mac80211 依赖（引用数 = 0）** —— 闭源驱动完全
   绕开无线子系统，使用自建 netdev + 私有 ioctl，用户态由 mtwifi-cfg /
   datconf 交互。→ 任务书"无线子系统接口适配"一项实际面为零，
   兼容性收敛在 netdev/skb/dma/pci 等核心 API 与 MTK 私有 glue。
3. **mt_wifi 硬依赖 mtkhnat** —— 无线驱动与硬件 NAT 在原厂体系里就是
   耦合交付，HNAT 移植是整条链的前置条件，优先级最高。
4. **闭源 mtk_wed.ko 与主线内建 mtk_wed 无符号冲突**：其全部外部符号走
   `warp_*`（mtk_warp）+ `mtk_bus_driver_*` / `fmac_hif_txd_*`（mtk_hwifi
   硬件抽象层），不引用主线 `mtk_wed_device_*` 面。
5. mtk_wed.ko 依赖 `mtk_hwifi` —— mt_wifi7 体系（WiFi7 独立芯片）
   相比旧栈多一层硬件抽象（HWIFI_SUPPORT）。

## 2. 内核 API 依赖面（按子系统分布）

### mt_wifi.ko（186 符号）

| 子系统 | 数量 | 代表符号 |
|---|---|---|
| netdev/netif/napi | 13 | `alloc_etherdev_mqs` `register_netdev` `napi_gro_receive` `netif_rx` `netif_carrier_on/off` |
| skb | 12 | `__netdev_alloc_skb` `skb_copy_bits` `pskb_expand_head` `skb_vlan_untag` |
| timer/workqueue | 9 | `timer_setup` `del_timer` `schedule_work` 系 |
| pci | 7 | `pci_iomap` `pci_enable_device` `pci_request_regions` 系 |
| dma | 4 | `dma_alloc_attrs` `dma_free_attrs` `dma_set_mask_and_coherent` |
| cfg80211 / nf_ / usb | **0** | — |

### mtkhnat.ko（107 符号）

| 子系统 | 数量 | 代表符号 |
|---|---|---|
| of | 6 | 设备树解析（PPE/WDMA 节点绑定） |
| netdev 侧 | 5 | `register_netdevice_notifier` `dsa_port_from_netdev` `netdev_lower_get_next` |
| skb | 11 | `skb_pull_rcsum` `skb_vlan_untag` `skb_copy` |
| nf | 3 | `nf_register_net_hooks` `__nf_ct_ext_find` |
| platform/devm | 5 | `platform_get_resource` `devm_ioremap_resource` 系 |
| timer/其他 | — | `dev_kfree_skb_any_reason` `pskb_expand_head` |

**结论**：两栈的通用内核 API 面全部落在 6.6 → 6.18 之间**基本稳定或
有等价替换**的接口上；真正的高风险面是：
- `mtkhnat` 对 `mtk_eth_soc` 内部状态的绑定方式（经内核侧补丁，
  见 chasey `999-eth-91` / `999-hnat-02..15` 系列）；
- `mt_wifi`/`mt_wifi7` 对 conninfra / warp 私有接口与时钟/复位
  （conninfra 属 of/platform 面）；
- 6.13+ 的 timer/workqueue 细则变更与 6.18 的 flowtable 卸载 API。

## 3. 对任务书各条的映射

| 任务书条目 | 本分析结论 |
|---|---|
| ELF 架构 / ABI | aarch64，GPL 模块按名链接，无 modversions |
| 原始内核版本 / 工具链 | 6.6.94（vermagic 实证） |
| 符号表 / 重定位 / 依赖 | 四模块依赖图如上；mt_wifi 硬依赖 hnat |
| 无线子系统 | **不依赖 cfg80211/mac80211**（0 引用，实测） |
| WED / WDMA 数据路径 | warp（引擎）+ mtk_wed（bus glue）+ mtk_hwifi（抽象层）三层 |
| EEPROM / 校准 | 由 mt_wifi 的 EEPROM_FLASH / e2p init 脚本面承载（待源码级详查） |
| 用户态交互 | mtwifi-cfg / datconf / wifi-dats / turboacc-mtk（私有 ioctl + dat 文件） |

## 附录 A · 复核方法

```bash
# 固件 rootfs 解包后（squashfs）：
modinfo rootfs/lib/modules/6.6.94/mt_wifi.ko          # vermagic/license/depends
nm -u rootfs/lib/modules/6.6.94/mtkhnat.ko | sort -u  # 未解析符号 = 内核 API 面
```

## 附录 B · 待补分析（阶段0 未完成项）

- [x] mt_wifi7（WiFi7 栈）符号面独立取证 → 322MB 源码（含 warp_driver、
      wlan_hwifi），81 个不同 linux 头文件，高风险 API 仅 13 处
- [x] 旧版 mt_wifi（AP3000M 栈）源码定位 → chasey 构建期拉取
      `mt79xx_20250408-705eb4.tar.xz`（7.6.7.3，REPO_URL 指向 hanwckf
      immortalwrt-mt798x openwrt-21.02/dl 镜像，来源可溯），已获取并解包
- [ ] 6.18.55 上逐符号可用性核对（结合 immortalwrt master 内核配置）
- [ ] mtk_eth_soc 挂钩点：chasey 内核补丁系列逐 hunk 分析
- [ ] USB→PPE ext-device 路径：chasey `999-zzz-5111/5112` 补丁精读

## 附录 C · 双栈高风险 API 清点（源码级 grep 实测）

| API | mt_wifi7（H5000M 栈） | mt_wifi 7.6.7.3（AP3000M 栈） | 6.18 状态 |
|---|---|---|---|
| `pci_enable_msi` | 2 | 3 | **6.11 已删除** → `pci_alloc_irq_vectors` |
| `proc_create` | 6 | 5 | 存在，proc_ops 语义沿用 |
| `platform_get_resource` | 2 | 3 | 标记 deprecated，仍可用 |
| `register_netdevice` | 5 | 5 | 稳定 |
| `timer_setup`/`del_timer` | 3 | 4 | `del_timer`→`timer_delete`（6.15+ 改名） |
| `netif_napi_add` | 2 | 1 | 签名收敛，稳定 |
| `nf_register_net_hook` | 0 | 0 | hnat 侧持有 |
| `of_get_named_gpio` | 0 | 0 | — |

**结论：双栈高风险面合计约 34 处调用点，全部有机械替换方案**——
即 `mediatek-port/common/compatibility` 兼容层的覆盖范围。真正的
深度工作在 mtkhnat 的 eth/flowtable 内核补丁系列与 conninfra/warp
的平台胶水，见后续 02 号文档。
