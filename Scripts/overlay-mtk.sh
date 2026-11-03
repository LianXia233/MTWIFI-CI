#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
#
# overlay-mtk.sh —— MTWIFI-CI 移植层核心
#
# 任务：把 mt798x 闭源驱动生态叠加到 ImmortalWrt 主线快照（内核 6.18）之上。
#
#   [1] package/mtk 合并：mt_wifi7 全家桶（padavanonly）+ 旧版 mt_wifi（chasey）
#   [2] mtk_hnat 内核驱动源码 → files-6.18（取 chasey 6.12 版本，离目标最近）
#   [3] kmod-mediatek_hnat 包定义挂入 netdevices.mk
#   [4] 内核侧 HNAT 补丁系列（chasey 6.12 → 6.18）逐补丁 best-effort，失败入报告
#   [5] 本仓库 port/ 移植补丁（严格模式：失败即停，人工迭代点）
#   [6] 移植清单与失败报告（build-reports/overlay-manifest.txt）
#
# 设计原则：上游补丁只做搬运起点，6.18 断点一律收敛到 port/ 内的
# 本仓库自有补丁（严格模式），保证迭代方向明确、可回滚。

set -uo pipefail

WRT_DIR="$PWD"
SRC_DIR="$WRT_DIR/.mtk-port"
REPORT_DIR="${GITHUB_WORKSPACE:-$WRT_DIR}/build-reports"
mkdir -p "$SRC_DIR" "$REPORT_DIR"

MANIFEST="$REPORT_DIR/overlay-manifest.txt"
APPLIED=()
FAILED=()

log()  { printf '\n[overlay] %s\n' "$*" | tee -a "$MANIFEST"; }
note() { printf '[overlay]   %s\n' "$*" | tee -a "$MANIFEST"; }

# ---------------------------------------------------------------------------
# [0] 拉取闭源驱动源码树
# ---------------------------------------------------------------------------
CHASEY_REPO="https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git"
CHASEY_REF="${MTK_CHASEY_REF:-25.12}"
PDN_REPO="https://github.com/padavanonly/immortalwrt-mt798x-6.6.git"
PDN_REF="${MTK_PDN_REF:-mt798x-mt799x-6.6-mtwifi}"

log "克隆驱动源码树（chasey @ $CHASEY_REF / padavanonly @ $PDN_REF）"
git clone -q --depth=1 --branch "$CHASEY_REF" "$CHASEY_REPO" "$SRC_DIR/chasey" || {
	log "FATAL: chasey 源码树克隆失败"; exit 1;
}
git clone -q --depth=1 --branch "$PDN_REF" "$PDN_REPO" "$SRC_DIR/pdn" || {
	log "FATAL: padavanonly 源码树克隆失败"; exit 1;
}
CHASEY_COMMIT=$(git -C "$SRC_DIR/chasey" rev-parse --short HEAD)
PDN_COMMIT=$(git -C "$SRC_DIR/pdn" rev-parse --short HEAD)
note "chasey  commit: $CHASEY_COMMIT"
note "pdn     commit: $PDN_COMMIT"

KVER=$(sed -n 's/^KERNEL_PATCHVER:=//p' "$WRT_DIR/target/linux/mediatek/Makefile" | head -n1)
note "主线内核版本: $KVER"

# ---------------------------------------------------------------------------
# [1] package/mtk 合并
#     以 padavanonly 树为底座：mt_wifi7 + mt_wifi_cmn + mt_hwifi + conninfra
#     + warp + wifi-profile + 全套应用（datconf / mtwifi-cfg / turboacc-mtk …）
#     再叠加 chasey 独有内容：旧版 mt_wifi（MT7981 内置 WiFi）与独有应用
# ---------------------------------------------------------------------------
log "[1/6] 合并 package/mtk"
cp -a "$SRC_DIR/pdn/package/mtk" "$WRT_DIR/package/" || { log "FATAL: pdn package/mtk 复制失败"; exit 1; }

if [ -d "$SRC_DIR/chasey/package/mtk/drivers/mt_wifi" ]; then
	cp -a "$SRC_DIR/chasey/package/mtk/drivers/mt_wifi" "$WRT_DIR/package/mtk/drivers/"
	note "追加旧版 mt_wifi（MT7981 用）"
else
	note "WARN: chasey 无 mt_wifi 驱动目录，AP3000M 将缺失旧版闭源驱动"
fi

# chasey 独有应用（-n 不覆盖 pdn 同名包，避免新.flags被旧版回退）
if [ -d "$SRC_DIR/chasey/package/mtk/applications" ]; then
	while IFS= read -r -d '' app; do
		name=$(basename "$app")
		if [ -e "$WRT_DIR/package/mtk/applications/$name" ]; then
			note "应用 $name：pdn 已提供，跳过 chasey 版本"
		else
			cp -a "$app" "$WRT_DIR/package/mtk/applications/"
			note "应用 $name：自 chasey 追加"
		fi
	done < <(find "$SRC_DIR/chasey/package/mtk/applications" -mindepth 1 -maxdepth 1 -type d -print0)
fi

# ---------------------------------------------------------------------------
# [2] mtk_hnat 内核驱动 → files-6.18
# ---------------------------------------------------------------------------
log "[2/6] 叠加 mtk_hnat 内核驱动到 files-$KVER"
HNAT_SRC="$SRC_DIR/chasey/target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek/mtk_hnat"
HNAT_DST="$WRT_DIR/target/linux/mediatek/files-$KVER/drivers/net/ethernet/mediatek/mtk_hnat"
if [ -d "$HNAT_SRC" ]; then
	mkdir -p "$(dirname "$HNAT_DST")"
	cp -a "$HNAT_SRC" "$HNAT_DST"
	note "mtk_hnat 源码 → target/linux/mediatek/files-$KVER/（$(find "$HNAT_DST" -name '*.c' | wc -l) 个 C 文件）"
else
	log "FATAL: chasey 树缺少 mtk_hnat 源码目录"; exit 1
fi

# mtk 无线调试工具（mt_wifi 生态应用依赖；存在才叠加）
WIFI_UTILITY_SRC="$SRC_DIR/pdn/target/linux/mediatek/files-6.6/drivers/net/wireless/wifi_utility"
if [ -d "$WIFI_UTILITY_SRC" ]; then
	WIFI_UTILITY_DST="$WRT_DIR/target/linux/mediatek/files-$KVER/drivers/net/wireless/wifi_utility"
	mkdir -p "$(dirname "$WIFI_UTILITY_DST")"
	cp -a "$WIFI_UTILITY_SRC" "$WIFI_UTILITY_DST"
	note "wifi_utility 调试工具 → files-$KVER"
fi

# ---------------------------------------------------------------------------
# [3] kmod-mediatek_hnat 包定义挂入 netdevices.mk
# ---------------------------------------------------------------------------
log "[3/6] 挂载 kmod-mediatek_hnat 包定义"
NETDEVICES="$WRT_DIR/package/kernel/linux/modules/netdevices.mk"
if grep -q 'KernelPackage/mediatek_hnat$' "$NETDEVICES" 2>/dev/null; then
	note "已存在，跳过"
else
	# 依赖标记：主线 mtk_eth_soc 已内建 PPE，HNAT 作为独立模块挂接 netfilter
	cat >> "$NETDEVICES" <<'EOF'

define KernelPackage/mediatek_hnat
  SUBMENU:=$(NETWORK_DEVICES_MENU)
  TITLE:=MediaTek HW NAT offloading (mt798x SDK, ported)
  DEPENDS:=@TARGET_mediatek +kmod-nf-conntrack
  KCONFIG:= \
	CONFIG_BRIDGE_NETFILTER=y \
	CONFIG_NETFILTER_FAMILY_BRIDGE=y \
	CONFIG_NET_MEDIATEK_HNAT
  FILES:= \
	$(LINUX_DIR)/drivers/net/ethernet/mediatek/mtk_hnat/mtkhnat.ko
endef

define KernelPackage/mediatek_hnat/description
  MediaTek Hardware NAT offloading driver, ported from the mt798x SDK tree
  onto the mainline kernel. Hooked into netfilter flow offload.
endef

$(eval $(call KernelPackage,mediatek_hnat))
EOF
	note "kmod-mediatek_hnat → netdevices.mk"
fi

# ---------------------------------------------------------------------------
# [4] 内核侧 HNAT 补丁系列（chasey 6.12 → 6.18，逐补丁 best-effort）
#     覆盖：eth-91 挂载点 / hnat-02..15 内核核心适配 / zzz-5xxx 驱动修复
#           / dts mtkhnat 节点。失败补丁全部记录，收敛后再下沉到 port/。
# ---------------------------------------------------------------------------
log "[4/6] 应用内核侧 HNAT 补丁系列（best-effort）"
CHASEY_PATCHES="$SRC_DIR/chasey/target/linux/mediatek/patches-6.12"
if [ -d "$CHASEY_PATCHES" ]; then
	for patch in $(cd "$CHASEY_PATCHES" && ls | grep -E '^999-(eth-91-|hnat-|zzz-5|dts-.*mtkhnat)'); do
		if patch -p1 --forward --no-backup-if-mismatch \
			-i "$CHASEY_PATCHES/$patch" >> "$MANIFEST" 2>&1; then
			APPLIED+=("$patch")
			note "OK    $patch"
		else
			# 回滚半套用的 hunk，保持内核树干净，留给 port/ 精修
			patch -p1 -R --no-backup-if-mismatch -i "$CHASEY_PATCHES/$patch" >/dev/null 2>&1 || true
			FAILED+=("$patch")
			note "FAIL  $patch （待 port/ 迭代）"
		fi
	done
else
	log "FATAL: chasey 补丁目录不存在"; exit 1
fi

# ---------------------------------------------------------------------------
# [5] 本仓库移植补丁（port/）—— 严格模式
#     port/kernel/*.patch  → 内核源码（files-$KVER 或 patches-$KVER 语义）
#     port/mtk/*.patch     → package/mtk 驱动源码
#     放进这里的就是人工确认过的 6.18 适配，失败必须停止构建。
# ---------------------------------------------------------------------------
log "[5/6] 应用本仓库移植补丁（严格模式）"
shopt -s nullglob
for patch in "$GITHUB_WORKSPACE"/port/kernel/*.patch; do
	if patch -p1 --forward --no-backup-if-mismatch -i "$patch" >> "$MANIFEST" 2>&1; then
		note "OK    port/kernel/$(basename "$patch")"
	else
		log "FATAL: port/kernel/$(basename "$patch") 应用失败 —— 6.18 适配待修正"
		exit 1
	fi
done
for patch in "$GITHUB_WORKSPACE"/port/mtk/*.patch; do
	if patch -p1 --forward --no-backup-if-mismatch -d "$WRT_DIR" -i "$patch" >> "$MANIFEST" 2>&1; then
		note "OK    port/mtk/$(basename "$patch")"
	else
		log "FATAL: port/mtk/$(basename "$patch") 应用失败 —— 驱动源码适配待修正"
		exit 1
	fi
done
shopt -u nullglob

# ---------------------------------------------------------------------------
# [6] 收尾：清理临时树，输出移植摘要
# ---------------------------------------------------------------------------
log "[6/6] 移植摘要"
rm -rf "$SRC_DIR"
{
	echo ""
	echo "================ 移植摘要 ================"
	echo "内核: $KVER | chasey: $CHASEY_COMMIT | pdn: $PDN_COMMIT"
	echo "上游补丁成功: ${#APPLIED[@]}"
	echo "上游补丁失败: ${#FAILED[@]}"
	[ ${#FAILED[@]} -gt 0 ] && printf '  - %s\n' "${FAILED[@]}"
	echo "port/ 严格补丁: 全部通过"
	echo "=========================================="
} | tee -a "$MANIFEST"

# 失败补丁清单 > 0 不是错误：这就是移植迭代的输入。
exit 0
