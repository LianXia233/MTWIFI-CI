# port/ —— 6.18 适配迭代区

闭源驱动从 6.6/6.12 搬到主线 6.18，无法一次到位。这里的迭代闭环是：

```
Actions 构建（overlay-mtk.sh 打上游补丁，失败的进报告）
        │
        ▼
下载 reports-* artifact → 看 overlay-manifest.txt 的 FAIL 列表
        │
        ▼
在 port/kernel/（内核侧）或 port/mtk/（驱动源码侧）写正式适配补丁
        │
        ▼
提交 → 下一次构建 overlay-mtk.sh 以严格模式应用 port/ 补丁
```

## 目录约定

| 目录 | 作用对象 | 应用方式 | 失败行为 |
|---|---|---|---|
| `port/kernel/*.patch` | 内核源码（`drivers/...`、DTS） | overlay 阶段 `-p1` | **严格**：构建立即停止 |
| `port/mtk/*.patch` | `package/mtk/` 驱动源码 | overlay 阶段 `-p1 -d <wrt>` | **严格**：构建立即停止 |

上游（chasey 6.12）补丁只做搬运起点，在 overlay-mtk.sh 里以 best-effort
应用并逐个记录成败；**凡是收敛通过的修复都应固化为 port/ 内的本仓库
补丁**，保证基线快照升级时适配关系始终可回溯。

## 已知断点清单（首轮构建重点观察）

1. `mtk_hnat`：`struct mtk_mac`/`hw_lro` 接口在 6.18 已变；chasey 的
   `999-eth-91-*`（Kconfig/Makefile 挂载）与 `999-hnat-02..15`（nf_flow_table
   卸载路径）需要按 6.18 的 flowtable API 重排。
2. `mt_wifi`（7.6x）：os_glue 的 timer/workqueue/netlink 在 6.13+ 的
   API 变更；`conninfra`/`warp` 随动。
3. `mt_wifi7`（7.9x）：统一命令接口与 `mt_hwifi` 抽象层同样有内核
   API 断点；WED glue 与主线 `mtk_wed` 的符号面需要核对。
4. DTS：hnat/wed 节点绑定随内核 dtschema 收紧。

## 打补丁规范

- 命名：`NNNN-<子系统>-<一句话>.patch`，编号按主题分段
  （01xx 内核核心、02xx eth/hnat、03xx wifi 驱动、04xx DTS）。
- 一个逻辑修一个补丁，便于上游语义 review 与回滚。
- 补丁头必须写明针对的上游断点（如 `net: flow: 6.18 移除 xxx API`）。
