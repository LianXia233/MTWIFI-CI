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
#   [4] kmod-mediatek_hnat 包定义挂入 netdevices.mk
#   [5] 内核补丁装载：port/kernel（6.18 适配版，优先）→ patches-6.18/；
#       再补入 chasey 的 999-eth-91 / 999-hnat-* C 代码系列（同名不覆盖）；
#       port/repo → 当场应用（严格模式，作用 package/mtk、DTS 等 repo 侧文件）
#
# 注意：chasey 的 DTS 补丁（999-dts-*）不再搬运 —— 它们以上游 6.12 的
# mt7981/7986/7987/7988 dts、rfb 板级节点为上下文，与 6.18 的 DTS 结构
# 完全不同，必然 patch 失败并中断整个 target/linux 编译。HNAT 的 DTS 节点
# 改由 port/kernel/999-dts-mt7981-hnat.patch（SoC 侧）与 port/repo/00x-*
# （设备侧启用）直接维护。
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
# 两棵闭源树都按提交固定：分支 tip 会继续前进（chasey 25.12 的 tip 已比本轮验证的
# 提交多出 zzz-51xx 等 20 个补丁，它们以前置 chasey 6.12 eth 系列为前提），
# 而 mtk_hnat 源码、补丁集、port/ 的适配补丁必须同源，否则补丁上下文对不上。
# 需要跟随上游时，用 MTK_CHASEY_COMMIT / MTK_PDN_COMMIT 覆盖并在 port/README.md 记录验证结果。
CHASEY_PIN="${MTK_CHASEY_COMMIT:-9f397975c7b47ce6986a6e39529d2f72fd5c729d}"
PDN_PIN="${MTK_PDN_COMMIT:-30fbc1d6deba23c0e850185021e9ee42214925eb}"

# 按提交做单提交浅克隆；GitHub 允许按 SHA fetch。取不到固定提交时回退到分支 HEAD，
# 并在清单里留下 WARN，避免静默用一个未验证的源码树。
fetch_tree() {
	_repo=$1; _ref=$2; _pin=$3; _dest=$4
	rm -rf "$_dest"
	git init -q "$_dest" || return 1
	git -C "$_dest" remote add origin "$_repo" || return 1
	if [ -n "$_pin" ] && git -C "$_dest" fetch -q --depth=1 origin "$_pin"; then
		git -C "$_dest" checkout -q FETCH_HEAD || return 1
	elif git -C "$_dest" fetch -q --depth=1 origin "$_ref"; then
		[ -n "$_pin" ] && note "WARN: 取不到固定提交 $_pin，回退分支 $_ref（结果不可复现）"
		git -C "$_dest" checkout -q FETCH_HEAD || return 1
	else
		return 1
	fi
}

log "[1/6] 克隆驱动源码树（chasey @ ${CHASEY_PIN:-$CHASEY_REF} / pdn @ ${PDN_PIN:-$PDN_REF}）"
fetch_tree "$CHASEY_REPO" "$CHASEY_REF" "$CHASEY_PIN" "$SRC_DIR/chasey" || die "chasey 克隆失败"
fetch_tree "$PDN_REPO" "$PDN_REF" "$PDN_PIN" "$SRC_DIR/pdn"          || die "pdn 克隆失败"
CHASEY_COMMIT=$(git -C "$SRC_DIR/chasey" rev-parse HEAD)
PDN_COMMIT=$(git -C "$SRC_DIR/pdn" rev-parse HEAD)
note "chasey ${CHASEY_COMMIT:0:8} | pdn ${PDN_COMMIT:0:8}"

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

# HNAT 的 C 补丁在 net/core/skbuff.c 等处插入了 #include <net/ra_nat.h>。
# 该头文件随闭源 HNAT 栈分发，必须同样落进 files-$KVER，内核的 include 搜索
# 路径（内核树 + files-<KVER> 叠加层）才能命中；缺失时表现为编译期
# "fatal error: net/ra_nat.h: No such file or directory"。
RA_NAT_SRC="$SRC_DIR/chasey/target/linux/mediatek/files-6.12/include/net/ra_nat.h"
RA_NAT_DST="$WRT_DIR/target/linux/mediatek/files-$KVER/include/net/ra_nat.h"
[ -f "$RA_NAT_SRC" ] || die "chasey 缺 files-6.12/include/net/ra_nat.h"
mkdir -p "$(dirname "$RA_NAT_DST")"
cp -f "$RA_NAT_SRC" "$RA_NAT_DST" || die "ra_nat.h 复制失败"
note "ra_nat.h → files-$KVER/include/net/（$(wc -c < "$RA_NAT_DST") 字节）"

# ---------------------------------------------------------------------------
# [4] kmod-mediatek_hnat 包定义挂入 netdevices.mk
#     eth-91 的 Kconfig 补丁会引入 MEDIATEK_NETSYS_V2/V3 与 NET_MEDIATEK_HNAT
#     三个新符号；内核 .config 里没有它们时 syncconfig 会以 (NEW) 交互提问，
#     非交互环境直接失败（历史报错：MediaTek Ethernet NETSYS V2 support (NEW)）。
#     这里按平台把对应的 NETSYS 代际写进 KCONFIG，由 OpenWrt 合并进内核 .config。
# ---------------------------------------------------------------------------
log "[4/6] 挂载 kmod-mediatek_hnat 包定义"
NETDEVICES="$WRT_DIR/package/kernel/linux/modules/netdevices.mk"
[ -f "$NETDEVICES" ] || die "netdevices.mk 不存在"
# MT7987（H5000M，wifi7 栈）属 NETSYS V3（XGMAC/USXGMII）
# MT7981（AP3000M，legacy 栈）属 NETSYS V2
# 两个符号都必须显式给值：只给本代 =y 时，另一代仍是 Kconfig 里带提示、无默认值的
# 新符号，内核 syncconfig 会以 "(NEW)" 追问（非交互环境 Error 1），
# 历史报错即 MediaTek Ethernet NETSYS V2 support (NEW)。做法与 chasey 自己的
# target/linux/mediatek/filogic/config-6.12 一致：本代 =y，另一代 not set。
if [ "$MTK_STACK" = legacy ]; then
	NETSYS_KCONFIG='CONFIG_MEDIATEK_NETSYS_V2=y'
	NETSYS_OTHER='CONFIG_MEDIATEK_NETSYS_V3=n'
else
	NETSYS_KCONFIG='CONFIG_MEDIATEK_NETSYS_V3=y'
	NETSYS_OTHER='CONFIG_MEDIATEK_NETSYS_V2=n'
fi
note "NETSYS 代际: $NETSYS_KCONFIG / $NETSYS_OTHER"
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
	CONFIG_NET_MEDIATEK_HNAT \
	CONFIG_MEDIATEK_NETSYS_STACK=y \
	CONFIG_MEDIATEK_NETSYS_OTHER=n
  FILES:= \
	$(LINUX_DIR)/drivers/net/ethernet/mediatek/mtk_hnat/mtkhnat.ko
endef

define KernelPackage/mediatek_hnat/description
  MediaTek Hardware NAT offloading driver, ported from the mt798x SDK tree
  onto the mainline kernel. Hooked into netfilter flow offload.
endef

$(eval $(call KernelPackage,mediatek_hnat))
EOF
	# 占位符替换（heredoc 用 <<'EOF' 保证 $(LINUX_DIR) 不被 shell 展开）
	sed -i "s|CONFIG_MEDIATEK_NETSYS_STACK=y|$NETSYS_KCONFIG|" "$NETDEVICES" \
		|| die "NETSYS KCONFIG 替换失败"
	sed -i "s|CONFIG_MEDIATEK_NETSYS_OTHER=n|$NETSYS_OTHER|" "$NETDEVICES" \
		|| die "NETSYS 另一代 KCONFIG 替换失败"
	note "kmod-mediatek_hnat → netdevices.mk（$NETSYS_KCONFIG / $NETSYS_OTHER）"
fi

# ---------------------------------------------------------------------------
# [5] 内核补丁 → patches-$KVER/（构建期 quilt 应用到解压后的内核）
#     port/kernel 优先（6.18 适配版，同名覆盖），再从 chasey 补入 C 代码系列。
#     chasey 的 DTS 系列一律不搬：其上下文（wdma/ap2woccif/rfb 节点）在
#     6.18 的 dts、dtsi 中已不存在，搬运只会制造必然失败的补丁。
# ---------------------------------------------------------------------------
log "[5/6] 装载内核补丁到 patches-$KVER/"
KPDIR="$WRT_DIR/target/linux/mediatek/patches-$KVER"
mkdir -p "$KPDIR"

PORT_COPIED=0
shopt -s nullglob
for patch in "$GITHUB_WORKSPACE"/port/kernel/*.patch; do
	pname=$(basename "$patch")
	cp -f "$patch" "$KPDIR/" || die "port/kernel/$pname 装载失败"
	PORT_COPIED=$((PORT_COPIED + 1))
	note "COPY port/kernel/$pname（6.18 适配，优先）"
done
shopt -u nullglob

	UP_COPIED=0
	CHASEY_PDIR="$SRC_DIR/chasey/target/linux/mediatek/patches-6.12"
	if [ -d "$CHASEY_PDIR" ]; then
		# 白名单 = 与 6.18 主线符号面已经对得上的 C 功能系列：
		#   eth-91 + hnat-02..15
		# hnat-02/07/09 由 port/kernel 权威版本覆盖（同名跳过）；
		# 全部 999-dts-* 不装载（6.12 DTS 结构在 6.18 不存在，设备 hnat 节点
		# 由 port/repo/00x 直接维护）。
		# zzz-51xx 不再从上游装载：其中 13 条按 6.18 上下文可直接命中的已固化为
		# port/kernel/999-hnat-26..38；改动 mtk_eth_soc.c/.h 的 5101/5110 已按
		# 6.18 的 mtk_tx_map()/mtk_poll_rx() 结构重写为 999-hnat-39/40；
		# 5106/5113 在 6.18 没有对应实现对象，理由与证据见 port/README.md。
		# 这里只补上游原始补丁，避免同一改动被装载两次。
		for patch in $(cd "$CHASEY_PDIR" && ls | grep -E '^999-(eth-91-|hnat-(02|03|04|05|06|07|08|09|12|14|15)-)'); do
			if [ -f "$KPDIR/$patch" ]; then
				note "SKIP $patch（port/kernel 已提供 6.18 版本）"
				continue
			fi
			cp "$CHASEY_PDIR/$patch" "$KPDIR/" || die "补丁装载失败: $patch"
			UP_COPIED=$((UP_COPIED + 1))
			note "COPY $patch"
		done
		note "chasey 999-dts-* 已按策略跳过（6.12 的 DTS 结构在 6.18 不存在）"
	else
		note "WARN: chasey 无 patches-6.12 目录"
	fi

# port/repo：repo 侧文件（package/mtk 驱动源码、target DTS 等）当场应用，严格模式
# 补丁头可用 `# port-stack: wifi7|legacy` 声明适用栈；与当前栈不符则跳过，
# 避免 wifi7 专用补丁在 legacy 栈（chasey 驱动层，无 mt_wifi7 目录）上误报失败。
shopt -s nullglob
for patch in "$GITHUB_WORKSPACE"/port/repo/*.patch; do
	pname="port/repo/$(basename "$patch")"
	stack_req=$(sed -n 's/^#[[:space:]]*port-stack:[[:space:]]*//p' "$patch" | head -n1 | tr -d ' \t')
	if [ -n "$stack_req" ] && [ "$stack_req" != "$MTK_STACK" ]; then
		note "SKIP $pname（仅适用 $stack_req 栈，当前 $MTK_STACK）"
		continue
	fi
	if patch -p1 --forward --no-backup-if-mismatch -i "$patch" >> "$MANIFEST" 2>&1; then
		REPO_APPLIED=$((REPO_APPLIED + 1))
		note "OK    $pname"
	else
		patch -p1 -R --no-backup-if-mismatch -i "$patch" >/dev/null 2>&1 || true
		REPO_FAILED+=("$pname")
		note "FAIL  $pname"
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
	echo "基线内核: $KVER | chasey: ${CHASEY_COMMIT:0:8} | pdn: ${PDN_COMMIT:0:8}"
	echo "patches-$KVER 中 999-* 补丁: $(ls "$KPDIR" | grep -c '^999-') 个"
	echo "  port/kernel（本仓库，6.18 适配）: $PORT_COPIED"
	echo "  chasey 上游 C 系列: $UP_COPIED"
	echo "port/repo 当场应用成功: $REPO_APPLIED / 失败: ${#REPO_FAILED[@]}"
	[ ${#REPO_FAILED[@]} -gt 0 ] && printf '  - %s\n' "${REPO_FAILED[@]}"
	echo "=========================================="
} | tee -a "$MANIFEST"

# 内核补丁的 quilt 应用成败在构建期日志里看（staging_dir/target-*/linux-*/quilt*）。
[ ${#REPO_FAILED[@]} -eq 0 ] || exit 1
exit 0
