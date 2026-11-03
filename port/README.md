# port/ —— 6.18 适配迭代区

闭源驱动从 6.6/6.12 搬到主线 6.18，无法一次到位。先分清两类文件所处的
"树"，决定了补丁的应用时机：

```
immortalwrt checkout（本仓库 overlay 时可见）
├── package/mtk/...                 ← 驱动源码在 checkout 里，可当场 patch
├── target/linux/mediatek/dts/...   ← 设备 DTS（OpenWrt 侧）同理
└── target/linux/mediatek/patches-6.18/   ← 内核补丁只"装载"，构建期 quilt 应用
        └──（构建时）→ 解压的内核源码 staging_dir/target-*/linux-*/
```

## 目录约定

| 目录 | 作用对象 | overlay 时行为 | 失败表现 |
|---|---|---|---|
| `port/kernel/*.patch` | 解压后的内核树（drivers/、arch/ 等） | **拷贝**进 `patches-6.18/` | 构建期 quilt 打不上 → 内核 Prepare 阶段失败，日志有 `.rej` |
| `port/repo/*.patch` | checkout 侧文件（package/mtk、target DTS） | **当场应用**（严格模式） | overlay 步骤立即失败并指名补丁 |

上游（chasey 6.12）内核补丁系列由 overlay-mtk.sh 搬运进 `patches-6.18/`，
6.12→6.18 的漂移同样在构建期暴露；收敛通过的修复固化到 `port/`。

## 迭代闭环

```
Actions 构建
   ├─ overlay 步骤：port/repo 应用失败 → 立即修（本目录补丁写错目标）
   └─ 内核 Prepare / 编译失败 → 下载 reports-* 看 serial.log.errors.txt
        │                             （quilt .rej 位于构建日志的内核段）
        ▼
在 port/kernel/ 或 port/repo/ 写正式适配补丁 → 提交 → 下一轮
```

## 已知断点清单（首轮构建重点观察）

1. `mtk_hnat`：`struct mtk_mac`/`hw_lro` 接口在 6.18 已变；chasey 的
   `999-eth-91-*`（Kconfig/Makefile 挂载）与 `999-hnat-02..15`（nf_flow_table
   卸载路径）需要按 6.18 的 flowtable API 重排。
2. DTS：主线 `hiveton_h5000m` / `airpi_ap3000m` 的 DTS 没有 mtkhnat 节点
   （上游不知道 HNAT）——需要 `port/repo/` 补丁加节点，参考 chasey
   `999-dts-*-mtkhnat-*` 系列。
3. `mt_wifi`（7.6x）/ `mt_wifi7`（7.9x）：os_glue 的 timer/workqueue/netlink
   在 6.13+ 的 API 变更；`conninfra`/`warp` 随动 → `port/repo/`。
4. WED：mt_wifi7 的 whnat 与主线 `mtk_wed` 的符号面需要核对。

## 打补丁规范

- 命名：`NNNN-<子系统>-<一句话>.patch`，编号分段：
  `01xx` 内核核心、`02xx` eth/hnat、`03xx` wifi 驱动、`04xx` DTS。
- 一个逻辑修一个补丁，补丁头写明上游断点（如 `net: flow: 6.18 移除 xxx API`）。
- `port/kernel/` 的补丁在 `staging_dir/target-*/linux-*/` 内核树上验证过再提交
  （本地可在 `make target/linux/{clean,prepare} V=s` 后于 quilt 环境迭代）。
