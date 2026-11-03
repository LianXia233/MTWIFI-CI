<div align="center">

# MTWIFI-CI

**ImmortalWrt 主线快照（内核 6.18）× 闭源 MTK 驱动移植层**

mtwifi / mt_wifi7 无线驱动 · HNAT 硬件加速 · WED/WHNAT 无线卸载 · USB 蜂窝模组加速

</div>

---

## 这是什么

在 **ImmortalWrt 主线快照**（固定基线 `fd622ba`，内核 **6.18.55**，LuCI Master）之上，
通过一个可迭代的**移植层（overlay）**，把 mt798x 闭源驱动生态的
**无线驱动（mtwifi / mt_wifi7）与硬件加速（mtk_hnat + WED/WARP）**
搬到最新主线上，产出两台设备的专属固件：

| 配置 | 设备 | SoC / WiFi | 闭源驱动 | 加速 |
|---|---|---|---|---|
| `H5000M-MT7-MT5700` | Hiveton H5000M | MT7987A + MT7992（BE6500） | **mt_wifi7** + conninfra/warp/mt_hwifi | HNAT + WED + USB 卸载 |
| `H5000M-MT7-MT5700M` | Hiveton H5000M | 同上 | 同上 | 同上 |
| `AP3000M-MT` | AirPi AP3000M | MT7981B（AX3000，IPA+ILNA） | **mt_wifi**（7.6x）+ conninfra/warp | HNAT + WARP v2 + USB 卸载 |

两份 H5000M 配置对应两套互斥的 MT5700M 模组管理插件（AT 串口独占）：
`MT5700` = [LianXia233/luci-app-mt5700](https://github.com/LianXia233/luci-app-mt5700)（Rust/Tokio），
`MT5700M` = [FAN789/luci-app-mt5700m](https://github.com/FAN789/luci-app-mt5700m)（经典 C）。**严禁跨固件混装。**

## 流水线架构

```
mtwifi.yml（调度：每周一 05:00 CST 自动 / 手动 dispatch）
   └── build-core.yml（可复用构建核心）
         ① 固定基线：immortalwrt/immortalwrt @ fd622ba（可 dispatch 覆盖 pin）
         ② Scripts/overlay-mtk.sh   ★ 移植层核心
              [1] package/mtk 合并（mt_wifi7 底座 + 旧版 mt_wifi + 独有应用）
              [2] mtk_hnat 内核源码 → files-6.18
              [3] kmod-mediatek_hnat → netdevices.mk
              [4] 上游内核补丁系列 best-effort（逐补丁记录成败）
              [5] port/ 本仓库适配补丁（严格模式）
              [6] 移植清单 + 失败报告 → Artifacts
         ③ feeds → 插件注入 → 个性化 → defconfig
         ④ Scripts/verify-config.sh 强校验（设备/驱动栈/双栈冲突，提前拦截）
         ⑤ 编译（失败自动串行 V=s 采集断点）→ 报告 → 缓存 → Release
```

闭源驱动数据源（overlay 输入，可用环境变量覆盖引用）：

| 来源 | 引用 | 提供内容 |
|---|---|---|
| [padavanonly/immortalwrt-mt798x-6.6](https://github.com/padavanonly/immortalwrt-mt798x-6.6) | `mt798x-mt799x-6.6-mtwifi` | mt_wifi7 / mt_wifi_cmn / mt_hwifi / conninfra / warp / wifi-profile / datconf / mtwifi-cfg / turboacc-mtk |
| [chasey-dev/immortalwrt-mt798x-rebase](https://github.com/chasey-dev/immortalwrt-mt798x-rebase) | `25.12` | 旧版 mt_wifi（MT7981）/ mtk_hnat 源码 / 内核 HNAT 补丁系列 |

流水线与工具链引导方式借鉴 [VIKINGYFY/CloseWRT-CI](https://github.com/VIKINGYFY/CloseWRT-CI)，在此致谢；
本仓库全部脚本为移植场景重写，不是上游 fork。

## 6.18 移植：进行时

闭源驱动发布基线是 6.6/6.12 内核，6.18 的 API 断点靠
**报告驱动的迭代**收敛，详见 [port/README.md](port/README.md)：

1. 手动触发 `mtwifi`（可先勾选 TEST 只合成配置）；
2. 构建结束后下载 `reports-*` Artifact，看 `overlay-manifest.txt`
   的 FAIL 补丁列表与 `serial.log.errors.txt` 的编译断点；
3. 在 `port/kernel/`、`port/mtk/` 写正式适配补丁并提交；
4. 下一轮构建自动以严格模式应用——收敛一个固化一个。

> 已知重点断点：mtk_hnat 对 `mtk_eth_soc` 结构体的依赖、nf_flow_table
> 卸载 API 变化、mt_wifi/mt_wifi7 的 os_glue 与 conninfra/warp 内核接口、
> WED 与主线 `mtk_wed` 的符号面、DTS hnat/wed 绑定收紧。

## 使用

1. Fork / 使用本仓库，**Settings → Actions → General → Workflow permissions**
   勾选 **Read and write permissions**（否则无法发 Release）；
2. Actions → `mtwifi` → Run workflow：
   - `pin`：留空 = 内置快照；也可填任意 immortalwrt commit 跟进主线；
   - `packages`：临时追加 `CONFIG_PACKAGE_xxx=y`；
   - `test`：勾选后仅合成 `.config` 并上传 Artifact，不编译；
3. 固件在 Releases 按配置名归档：`*-sysupgrade.bin`（H5000M）/ `*-sysupgrade.bin`（AP3000M）。

出厂默认：后台 `192.168.10.1`（root / 无密码），WiFi `OWRT` / `12345678`，时区上海。

## 已知限制

- **USB/WWAN 的 HNAT 卸载与机型相关**：闭源 HNAT 对 USB 网卡的加速并非全机型可用，
  AP3000M/H5000M 需上机实测；不生效时走软件分载，不影响功能。
- **IPv6 + UDP 场景**：闭源 HNAT 在部分机型存在 IPv6/UDP 性能异常的历史问题
  （WireGuard/IPSec 变慢时优先关闭硬件加速对照）。
- **双栈互斥**：固件内已显式排除主线 mt76 内置 WiFi 栈（`kmod-mt7915e` 等），
  无线由闭源驱动独占接管。
- AP3000M 的 WiFi EEPROM 出厂为空，首启由 hotplug 脚本从模板初始化
  （见 [AP3000M-EEPROM/](AP3000M-EEPROM/)，自带板级守卫，不会误伤其他机型）。

## 鸣谢

驱动与生态：hanwckf、padavanonly（237）、chasey-dev、MediaTek SDK 团队；
流水线思想：VIKINGYFY（CloseWRT-CI）、p3terx（Actions 模板）；
设备插件：本账号下 luci-app-mt5700 / airpi3000m-fancontrol / h5000m 套件。

## License

MIT —— 详见 [LICENSE](LICENSE)。
