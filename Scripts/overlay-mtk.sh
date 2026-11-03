#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
#
# overlay-mtk.sh v2 —— MTWIFI-CI 移植层核心
# 由 build-core.yml 在 wrt/（immortalwrt 基线树）内调用。
#
#   [0] 环境硬守卫（cwd、基线树、内核版本）
#   [1] package/mtk 合并：mt_wifi7 全家桶（pdn）+ 旧版 mt_wifi 与独有应用（chasey）
#   [2] mtk_hnat / wifi_utility 内核源码 → files-6.18
#   [3] kmod-mediatek_hnat 包定义挂入 netdevices.mk
#   [4] chasey 内核 HNAT 补丁系列 → 拷贝进 patches-6.18/（构建期由 quilt 应用）
#   [5] 本仓库移植补丁：port/kernel → 拷贝进 patches-6.18/；
#       port/repo → 当场应用（严格模式，作用 package/mtk、DTS 等 repo 侧文件）
#   [6] 移植清单与失败报告
#
# 关键认知：immortalwrt checkout 内没有内核源码树 —— 内核补丁一律进
# patches-<KVER>/，由 OpenWrt 构建系统在内核准备阶段应用；checkout 侧
# 文件（package/mtk、target DTS）才能当场 patch。

set -uo pipefail

WRT_DIR="$PWD"
SRC_DIR="$WRT_DIR/.mtk-port"
REPORT_DIR="${GITHUB_WORKSPACE:-$WRT_DIR}/build-reports"
mkdir -p "$SRC_DIR" "$REPORT_DIR"

MANIFEST="$REPORT_DIR/overlay-manifest.txt"
REPO_APPLIED=0
REPO_FAILED=()

log()  { printf '\n[overlay] %s\n' "$*" | tee -a "$MANIFEST"; }
note() { printf '[overlay]   %s\n' "$*" | tee -a "$MANIFEST"; }
die()  { log "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# [0] 环境硬守卫
# ---------------------------------------------------------------------------
log "[0/6] 环境守卫"
[ -f "$WRT_DIR/rules.mk" ]                            || die "cwd 不是 OpenWrt 树（缺 rules.mk）: $WRT_DIR"
[ -f "$WRT_DIR/target/linux/mediatek/Makefile" ]      || die "缺 target/linux/mediatek/Makefile"
KVER=$(sed -n 's/^KERNEL_PATCHVER:=//p' "$WRT_DIR/target/linux/mediatek/Makefile" | head -n1 | tr -d ' \t')
[ -n "$KVER" ]                                        || die "无法解析 KERNEL_PATCHVER"
note "基线内核: $KVER | cwd: $WRT_DIR"

# 驱动栈判定：两平台独立适配（任务书要求），不允许混装两代闭源无线栈
#   H5000M* → wifi7  栈：pdn 树（mt_wifi7 + mt_wifi_cmn + mt_hwifi + warp + wifi-profile）
#   AP3000M* → legacy 栈：chasey 树（mt_wifi 7.6x + conninfra + warp + wifi-profile）
case "${WRT_CONFIG:-${MTK_STACK:-}}" in
	H5000M*)  MTK_STACK=wifi7 ;;
	AP3000M*) MTK_STACK=legacy ;;
	*) MTK_STACK="${MTK_STACK:-}" ;;
esac
[ -n "$MTK_STACK" ] || die "无法从 WRT_CONFIG='$WRT_CONFIG' 判定驱动栈（H5000M*/AP3000M*）"
note "驱动栈: $MTK_STACK"

# ---------------------------------------------------------------------------
# [1] 拉取闭源驱动源码树
# ---------------------------------------------------------------------------
CHASEY_REPO="https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git"
CHASEY_REF="${MTK_CHASEY_REF:-25.12}"
PDN_REPO="https://github.com/padavanonly/immortalwrt-mt798x-6.6.git"
PDN_REF="${MTK_PDN_REF:-mt798x-mt799x-6.6-mtwifi}"

log "[1/6] 克隆驱动源码树（chasey @ $CHASEY_REF / pdn @ $PDN_REF）"
git clone -q --depth=1 --branch "$CHASEY_REF" "$CHASEY_REPO" "$SRC_DIR/chasey" || die "chasey 克隆失败"
git clone -q --depth=1 --branch "$PDN_REF" "$PDN_REPO" "$SRC_DIR/pdn"          || die "pdn 克隆失败"
CHASEY_COMMIT=$(git -C "$SRC_DIR/chasey" rev-parse --short HEAD)
PDN_COMMIT=$(git -C "$SRC_DIR/pdn" rev-parse --short HEAD)
note "chasey $CHASEY_COMMIT | pdn $PDN_COMMIT"

# ---------------------------------------------------------------------------
# [2] package/mtk 合并：应用层取并集（pdn 优先），驱动层按栈整体取用
# ---------------------------------------------------------------------------
log "[2/6] 合并 package/mtk（栈: $MTK_STACK）"
[ -d "$SRC_DIR/pdn/package/mtk" ] || die "pdn 树缺 package/mtk"
cp -a "$SRC_DIR/pdn/package/mtk" "$WRT_DIR/package/" || die "pdn package/mtk 复制失败"

if [ "$MTK_STACK" = legacy ]; then
	# 旧栈整体来自 chasey（mt_wifi + conninfra + warp + wifi-profile），替换 pdn 驱动层
	rm -rf "$WRT_DIR/package/mtk/drivers"
	cp -a "$SRC_DIR/chasey/package/mtk/drivers" "$WRT_DIR/package/mtk/drivers" \
		|| die "chasey 驱动层复制失败"
	note "驱动层 = chasey 全套（旧版 mt_wifi + conninfra + warp）"
else
	note "驱动层 = pdn 全套（mt_wifi7 + mt_wifi_cmn + mt_hwifi + warp + wifi-profile）"
fi

while IFS= read -r -d '' app; do
	name=$(basename "$app")
	if [ -e "$WRT_DIR/package/mtk/applications/$name" ]; then
		note "应用 $name：pdn 已提供，跳过 chasey 版本"
	else
		cp -a "$app" "$WRT_DIR/package/mtk/applications/" \
			|| die "chasey 应用 $name 复制失败"
		note "应用 $name：自 chasey 追加"
	fi
done < <(find "$SRC_DIR/chasey/package/mtk/applications" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

# ---------------------------------------------------------------------------
# [3] mtk_hnat / wifi_utility 内核源码 → files-6.18（files/ 在构建期覆盖内核树）
# ---------------------------------------------------------------------------
log "[3/6] 叠加内核驱动源码到 files-$KVER"
HNAT_SRC="$SRC_DIR/chasey/target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek/mtk_hnat"
HNAT_DST="$WRT_DIR/target/linux/mediatek/files-$KVER/drivers/net/ethernet/mediatek/mtk_hnat"
[ -d "$HNAT_SRC" ] || die "chasey 缺 mtk_hnat 源码目录"
mkdir -p "$(dirname "$HNAT_DST")"
cp -a "$HNAT_SRC" "$HNAT_DST" || die "mtk_hnat 复制失败"
note "mtk_hnat → files-$KVER/（$(find "$HNAT_DST" -name '*.c' | wc -l) 个 C 文件）"

WIFI_UTILITY_SRC="$SRC_DIR/pdn/target/linux/mediatek/files-6.6/drivers/net/wireless/wifi_utility"
if [ -d "$WIFI_UTILITY_SRC" ]; then
	WIFI_UTILITY_DST="$WRT_DIR/target/linux/mediatek/files-$KVER/drivers/net/wireless/wifi_utility"
	mkdir -p "$(dirname "$WIFI_UTILITY_DST")"
	cp -a "$WIFI_UTILITY_SRC" "$WIFI_UTILITY_DST" || die "wifi_utility 复制失败"
	note "wifi_utility → files-$KVER/"
fi

# ---------------------------------------------------------------------------
# [4] kmod-mediatek_hnat 包定义挂入 netdevices.mk
# ---------------------------------------------------------------------------
log "[4/6] 挂载 kmod-mediatek_hnat 包定义"
NETDEVICES="$WRT_DIR/package/kernel/linux/modules/netdevices.mk"
[ -f "$NETDEVICES" ] || die "netdevices.mk 不存在"
if grep -q 'KernelPackage/mediatek_hnat$' "$NETDEVICES"; then
	note "已存在，跳过"
else
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
# [5] 内核补丁 → patches-$KVER/（构建期 quilt 应用到解压后的内核）
#     上游（chasey 6.12）系列 + 本仓库 port/kernel，全部只做搬运，
#     6.12→6.18 的漂移在构建日志中以 quilt .rej 形式暴露，再进 port/ 收敛。
# ---------------------------------------------------------------------------
log "[5/6] 装载内核补丁到 patches-$KVER/"
KPDIR="$WRT_DIR/target/linux/mediatek/patches-$KVER"
mkdir -p "$KPDIR"

KP_COPIED=0
if [ -d "$SRC_DIR/chasey/target/linux/mediatek/patches-6.12" ]; then
	for patch in $(cd "$SRC_DIR/chasey/target/linux/mediatek/patches-6.12" && ls | grep -E '^999-(eth-91-|hnat-|zzz-5|dts-.*mtkhnat)'); do
		if [ -f "$KPDIR/$patch" ]; then
			note "SKIP $patch（已存在）"
			continue
		fi
		cp "$SRC_DIR/chasey/target/linux/mediatek/patches-6.12/$patch" "$KPDIR/" || die "补丁装载失败: $patch"
		KP_COPIED=$((KP_COPIED + 1))
		note "COPY $patch"
	done
else
	note "WARN: chasey 无 patches-6.12 目录"
fi

shopt -s nullglob
for patch in "$GITHUB_WORKSPACE"/port/kernel/*.patch; do
	pname=$(basename "$patch")
	if [ -f "$KPDIR/$pname" ]; then
		note "SKIP port/kernel/$pname（已存在）"
		continue
	fi
	cp "$patch" "$KPDIR/" || die "port/kernel/$pname 装载失败"
	note "COPY port/kernel/$pname"
done

# port/repo：repo 侧文件（package/mtk 驱动源码、target DTS 等）当场应用，严格模式
for patch in "$GITHUB_WORKSPACE"/port/repo/*.patch; do
	if patch -p1 --forward --no-backup-if-mismatch -i "$patch" >> "$MANIFEST" 2>&1; then
		REPO_APPLIED=$((REPO_APPLIED + 1))
		note "OK    port/repo/$(basename "$patch")"
	else
		patch -p1 -R --no-backup-if-mismatch -i "$patch" >/dev/null 2>&1 || true
		REPO_FAILED+=("port/repo/$(basename "$patch")")
		note "FAIL  port/repo/$(basename "$patch")"
	fi
done
shopt -u nullglob

# ---------------------------------------------------------------------------
# [6] 收尾
# ---------------------------------------------------------------------------
log "[6/6] 移植摘要"
rm -rf "$SRC_DIR"
{
	echo ""
	echo "================ 移植摘要 ================"
	echo "基线内核: $KVER | chasey: $CHASEY_COMMIT | pdn: $PDN_COMMIT"
	echo "内核补丁装载（构建期由 quilt 应用）: $(ls "$KPDIR" | grep -c '^999-') 个 999-* 系 + 本仓库 port/kernel"
	echo "上游搬运本轮新增: $KP_COPIED"
	echo "port/repo 当场应用成功: $REPO_APPLIED / 失败: ${#REPO_FAILED[@]}"
	[ ${#REPO_FAILED[@]} -gt 0 ] && printf '  - %s\n' "${REPO_FAILED[@]}"
	echo "=========================================="
} | tee -a "$MANIFEST"

# 内核补丁的 quilt 应用成败在构建期日志里看（staging_dir/target-*/linux-*/quilt*）。
[ ${#REPO_FAILED[@]} -eq 0 ] || exit 1
exit 0
