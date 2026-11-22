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

# 内核 WEXT：基座 generic/config-$KVER 关闭了 WIRELESS_EXT/WEXT_PRIV，但两套
# 闭源栈的 wireless_handlers / private ioctl 路径都依赖它们（mtwifi-cfg 通过
# SIOCGIWPRIV 配置）。vanilla 6.18 的这两个符号是无提示 bool，.config 里的 =y
# 会被 oldconfig 丢弃，因此配合 port/kernel/999-wireless-ext-kconfig.patch 补提示。
WEXT_CFG="$WRT_DIR/target/linux/mediatek/filogic/config-$KVER"
if [ -f "$WEXT_CFG" ]; then
	for sym in CONFIG_WIRELESS_EXT CONFIG_WEXT_PRIV; do
		grep -q "^$sym=y" "$WEXT_CFG" || echo "$sym=y" >> "$WEXT_CFG"
	done
	note "kernel WEXT: WIRELESS_EXT / WEXT_PRIV = y（filogic/config-$KVER）"
else
	note "WARN: 缺 $WEXT_CFG，跳过 kernel WEXT 配置"
fi

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

# 驱动层根目录在后续所有步骤共用；必须在这里定义（脚本 set -u，
# 放在 [2b] 段里会导致前面的 build_dep 引用未定义变量直接退出）。
MTK_DRV="$WRT_DIR/package/mtk/drivers"

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

# datconf：pdn 版本没有 PKG_SOURCE_URL/PKG_HASH，`make download` 拉不到源码
# （build 期 bzcat dl/datconf-*.tar.bz2 直接失败）；chasey 版本同源同版本，
# 且多出 ucode-mod-datconf（AP 配置需要）。两栈统一改用 chasey 版本。
if [ -d "$SRC_DIR/chasey/package/mtk/applications/datconf" ]; then
	rm -rf "$WRT_DIR/package/mtk/applications/datconf"
	cp -a "$SRC_DIR/chasey/package/mtk/applications/datconf" \
		"$WRT_DIR/package/mtk/applications/" || die "datconf 覆盖失败"
	grep -q '^PKG_SOURCE_URL:=' "$WRT_DIR/package/mtk/applications/datconf/Makefile" \
		|| die "datconf 仍缺 PKG_SOURCE_URL"
	note "datconf：使用 chasey 版本（PKG_SOURCE_URL/HASH + ucode-mod-datconf）"
fi

# 跨源码包的符号依赖：kmod 的 DEPENDS 只保证运行时顺序，编译期 symvers
# 需要 PKG_BUILD_DEPENDS 才会生成正确的 build 依赖边。parallel 构建里
# 否则会出现“先编调用方、后编符号提供者” → modpost undefined。
build_dep() {
	local mk="$1" deps="$2" cur d
	[ -f "$mk" ] || return 0
	if grep -q '^PKG_BUILD_DEPENDS' "$mk"; then
		cur=$(sed -n 's/^PKG_BUILD_DEPENDS:=//p' "$mk" | head -n1)
		for d in $deps; do
			case " $cur " in *" $d "*) ;; *) cur="$cur $d" ;; esac
		done
		sed -i "s/^PKG_BUILD_DEPENDS:=.*$/PKG_BUILD_DEPENDS:=$cur/" "$mk"
	else
		awk -v deps="$deps" 'BEGIN{done=0}
			/^include \$\(INCLUDE_DIR\)\/package\.mk[[:space:]]*$/ {
				if (!done) { print "PKG_BUILD_DEPENDS:=" deps; done=1 }
			}
			{ print }' "$mk" > "$mk.tmp" && mv "$mk.tmp" "$mk"
	fi
	note "PKG_BUILD_DEPENDS += $deps: ${mk#"$WRT_DIR"/}"
}
build_dep "$MTK_DRV/mt_wifi/Makefile"  "warp conninfra"
build_dep "$MTK_DRV/mt_wifi7/Makefile" "mt_wifi_cmn"
build_dep "$MTK_DRV/mt_hwifi/Makefile" "mt_wifi7 mt_wifi_cmn warp"

# legacy mt_wifi 是 tarball 源码，overlay 的源码归一化碰不到；以包补丁形式
# 补在 chasey patches-7673（001..041）之后：trace.h 时间 API + 关闭 -Werror。
MW_PATCHES="$MTK_DRV/mt_wifi/patches-7673"
if [ -d "$MW_PATCHES" ]; then
	cp -f "$GITHUB_WORKSPACE/port/mtwifipatches/050-6.18-api.patch" "$MW_PATCHES/" \
		|| die "mt_wifi 050 补丁装载失败"
	note "mt_wifi：装载 patches-7673/050-6.18-api.patch"
fi

# legacy warp 同样是 tarball 源码（warp_20250408），且 V2/V3 会编译
# warp_bm_v2.c 与 mcu/warp_wo.c；6.18 的 page_frag_cache 去掉 .va/pagecnt_bias
# 字段后必然编译失败。补丁编号 100，排在 chasey 的 001..099 之后应用。
WARP_PATCHES="$MTK_DRV/warp/patches"
if [ "$MTK_STACK" = legacy ] && [ -d "$WARP_PATCHES" ]; then
	cp -f "$GITHUB_WORKSPACE/port/warp-patches/100-page-frag-6.18.patch" "$WARP_PATCHES/" \
		|| die "warp 100 补丁装载失败"
	note "warp：装载 patches/100-page-frag-6.18.patch"
fi

# apk 的版本校验比 opkg 严格：6.18.55.TEST-r1 / 空版本会被 apk mkpkg 拒绝
# （ERROR: info field 'version' has invalid value）。pdn 的几个 kmod 包用
# PKG_VERSION:=TEST 或留空，KernelPackage 会拼出非法版本；统一改为 1.0。
for mk in "$MTK_DRV/mt_wifi7/Makefile" "$MTK_DRV/mt_hwifi/Makefile" \
	"$MTK_DRV/mt_wifi_cmn/Makefile" "$MTK_DRV/warp/Makefile"; do
	[ -f "$mk" ] || continue
	sed -i -E 's/^PKG_VERSION:=(TEST)?$/PKG_VERSION:=1.0/' "$mk"
	grep -qE '^PKG_VERSION:=(TEST)?$' "$mk" \
		&& die "非法 PKG_VERSION 未修正: ${mk#"$WRT_DIR"/}"
done
note "pdn kmod PKG_VERSION → 1.0（apk 版本校验）"

# ---------------------------------------------------------------------------
# [2b] 6.18 内核 API 机械归一化（只做语义等价替换，不动控制流）
#
# pdn 的 wifi7/hwifi 树来自 6.6，仍在使用 6.8+ 已移除的符号。这些调用点的
# 返回值都被丢弃，逐个写补丁不如在 overlay 阶段统一归一化：
#   strlcpy()       6.8 移除 → strscpy()（签名/语义等价，返回值一致丢弃）
#   rtc_time_to_tm() 移除 → rtc_time64_to_tm()（参数由 unsigned long 放宽到 time64_t）
#   netif_rx_ni()   6.9 移除 → netif_rx()（同样可在进程上下文调用）
#   trace.h         的 struct timeval + do_gettimeofday() → timespec64 + ktime_get_real_ts64()
# chasey 的 legacy 树已是 6.12 基线，这些符号本就不存在，替换为无操作。
# ---------------------------------------------------------------------------
log "[2b/6] 6.18 内核 API 机械归一化"
if [ -d "$MTK_DRV" ]; then
	SLC=$(grep -rl 'strlcpy(' "$MTK_DRV" --include='*.c' --include='*.h' 2>/dev/null | wc -l)
	NLA=$(grep -rl 'nla_strlcpy(' "$MTK_DRV" --include='*.c' --include='*.h' 2>/dev/null | wc -l)
	RTM=$(grep -rl 'rtc_time_to_tm(' "$MTK_DRV" --include='*.c' --include='*.h' 2>/dev/null | wc -l)
	NRN=$(grep -rl 'netif_rx_ni(' "$MTK_DRV" --include='*.c' --include='*.h' 2>/dev/null | wc -l)
	PDM=$(grep -rl 'pci_set_dma_mask(\|pci_set_consistent_dma_mask(' "$MTK_DRV" --include='*.c' --include='*.h' 2>/dev/null | wc -l)
	grep -rl 'strlcpy(\|nla_strlcpy(\|rtc_time_to_tm(\|netif_rx_ni(\|pci_set_dma_mask(\|pci_set_consistent_dma_mask(' "$MTK_DRV" \
		--include='*.c' --include='*.h' 2>/dev/null |
		xargs -r sed -i \
			-e 's/\bstrlcpy(/strscpy(/g' \
			-e 's/\bnla_strlcpy(/nla_strscpy(/g' \
			-e 's/\brtc_time_to_tm(/rtc_time64_to_tm(/g' \
			-e 's/\bnetif_rx_ni(/netif_rx(/g' \
			-e 's/pci_set_dma_mask(pdev, /dma_set_mask(\&pdev->dev, /g' \
			-e 's/pci_set_consistent_dma_mask(pdev, /dma_set_coherent_mask(\&pdev->dev, /g'
	note "strlcpy→strscpy: $SLC | nla_strlcpy→nla_strscpy: $NLA | rtc_time_to_tm→rtc_time64_to_tm: $RTM | netif_rx_ni→netif_rx: $NRN | pci_set_dma_mask→dma_set_mask: $PDM 文件"

	find "$MTK_DRV" -path '*/include/os/trace.h' -type f -print0 |
	while IFS= read -r -d '' trace_h; do
		grep -q 'linux/timekeeping.h' "$trace_h" \
			|| sed -i 's|#include <linux/time\.h>|#include <linux/time.h>\n#include <linux/timekeeping.h>|' "$trace_h"
		sed -i \
			-e 's/struct timeval time;/struct timespec64 time;/g' \
			-e 's/do_gettimeofday(&time);/ktime_get_real_ts64(\&time);/g' \
			"$trace_h"
		note "trace.h 时间戳 → timespec64/ktime_get_real_ts64: ${trace_h#"$WRT_DIR"/}"
	done

	# kernel_thread() 未导出，且 5.10 起签名改为 (fn, arg, name, flags)；
	# 驱动在未定义 KTHREAD_SUPPORT 时走的正是这条老路径（rt_linux.c 里还有
	# #error "Not yet implemented"），模块必然编译/链接失败。
	# OpenWrt 包不走 CONFIG_NATIVE_CFG，mk/config/config_common.mk 不会被包含，
	# 所以直接在包 Makefile 的 KCFLAGS 里定义 KTHREAD_SUPPORT，切到厂商的
	# kthread_run 分支（init/kill/wait 代码齐全）。
	for mk in "$MTK_DRV/mt_wifi7/Makefile" "$MTK_DRV/mt_hwifi/Makefile"; do
		[ -f "$mk" ] || continue
		grep -q -- '-DKTHREAD_SUPPORT' "$mk" \
			|| echo 'KCFLAGS += -DKTHREAD_SUPPORT' >> "$mk"
		# GCC 14 把 int-conversion / incompatible-pointer-types /
		# return-mismatch 默认升级为错误；6.6 闭源树没有适配。只降级这三类，
		# 其它内核强错误（implicit-function-declaration 等）仍保留。
		grep -q 'Wno-error=incompatible-pointer-types' "$mk" \
			|| echo 'KCFLAGS += -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=return-mismatch' >> "$mk"
		note "KCFLAGS += -DKTHREAD_SUPPORT + GCC14 三类降级: ${mk#"$WRT_DIR"/}"
	done

	# warp 走自己的 ccflags-y（不接收 KCFLAGS），单独追加同样的降级项。
	WARP_MK="$MTK_DRV/warp/src/Makefile"
	if [ -f "$WARP_MK" ] && ! grep -q 'Wno-error=incompatible-pointer-types' "$WARP_MK"; then
		echo 'ccflags-y += -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=return-mismatch' >> "$WARP_MK"
		note "warp: GCC14 三类降级"
	fi

	# 6.12 起内核把 -Wmissing-prototypes / -Wmissing-declarations 放进默认
	# KBUILD_CFLAGS，pdn 的 6.6 闭源树从未面对这两个检查；这些包又用 -Werror
	# 把警告变错误。闭源源码不可能逐条补原型，统一把裸 -Werror 降为
	# -Wno-error（-Werror=implicit-function-declaration 等内核强错误仍保留）。
	WERR_FILES=$(grep -rlE -- '(^|[[:space:]])-Werror([[:space:]]|$)' "$MTK_DRV" \
		--include='Makefile' --include='*.mk' 2>/dev/null || true)
	if [ -n "$WERR_FILES" ]; then
		WERR_COUNT=$(printf '%s\n' "$WERR_FILES" | wc -l)
		printf '%s\n' "$WERR_FILES" | while IFS= read -r f; do
			sed -i -E 's/(^|[[:space:]])-Werror([[:space:]]|$)/\1-Wno-error\2/g' "$f"
		done
		note "-Werror → -Wno-error（6.6 闭源树）：$WERR_COUNT 文件"
	else
		note "-Werror 归一化：无匹配文件"
	fi

	# init_dummy_netdev() 在 6.18 变成内核内部函数，公开 API 只剩分配式的
	# alloc_netdev_dummy()。驱动把 struct net_device 内嵌在私有结构里，只能按
	# 6.12 的语义就地初始化（清零 + NETREG_DUMMY + PRESENT/START）。
	DMY=$(grep -rl 'return init_dummy_netdev(dev);' "$MTK_DRV" --include='*.c' 2>/dev/null | wc -l)
	grep -rl 'return init_dummy_netdev(dev);' "$MTK_DRV" --include='*.c' 2>/dev/null |
	while IFS= read -r f; do
		perl -0777 -pi -e 's/int mt_init_dummy_netdev\(struct net_device \*dev\)\s*\{\s*return init_dummy_netdev\(dev\);\s*\}/int mt_init_dummy_netdev(struct net_device *dev)\n{\n\tmemset(dev, 0, sizeof(*dev));\n\tdev->reg_state = NETREG_DUMMY;\n\tset_bit(__LINK_STATE_PRESENT, &dev->state);\n\tset_bit(__LINK_STATE_START, &dev->state);\n\treturn 0;\n}/s' "$f"
	done
	note "init_dummy_netdev 就地初始化: $DMY 文件"

	# proc_create_data() 自 5.6 起第 4 参数是 struct proc_ops *；
	# pdn 的 mt_fwdump.c（os/linux/rules.mk 无条件编入）仍用 file_operations。
	FWD=$(grep -rl 'static const struct file_operations fops_dump' "$MTK_DRV" --include='*.c' 2>/dev/null | wc -l)
	grep -rl 'static const struct file_operations fops_dump' "$MTK_DRV" --include='*.c' 2>/dev/null |
	while IFS= read -r f; do
		perl -0777 -pi -e 's/static const struct file_operations fops_dump = \{\n\t\.owner = THIS_MODULE,\n\t\.open = fwdumpopen,\n\t\.read = fwdumpread,\n\t\.write = fwdumpwrite,\n\};/#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)\nstatic const struct proc_ops fops_dump = {\n\t.proc_open = fwdumpopen,\n\t.proc_read = fwdumpread,\n\t.proc_write = fwdumpwrite,\n};\n#else\nstatic const struct file_operations fops_dump = {\n\t.owner = THIS_MODULE,\n\t.open = fwdumpopen,\n\t.read = fwdumpread,\n\t.write = fwdumpwrite,\n};\n#endif/s' "$f"
		grep -q 'struct proc_ops fops_dump' "$f" \
			|| die "mt_fwdump proc_ops 替换失败: ${f#"$WRT_DIR"/}"
	done
	note "mt_fwdump → proc_ops: $FWD 文件"

	# warp 的 platform_driver.remove 仍是 int；6.11 起必须返回 void
	# （GCC 14 下是 -Wincompatible-pointer-types 错误）。
	for f in "$MTK_DRV/warp/src/warp_main.c" \
		"$MTK_DRV/mt_wifi7/src/warp_driver/warp/warp_main.c" \
		"$MTK_DRV/mt_hwifi/src/warp_driver/warp/warp_main.c"; do
		[ -f "$f" ] || continue
		perl -0777 -pi -e 's/static int\nwarp_remove\(struct platform_device \*pdev\)/static void\nwarp_remove(struct platform_device *pdev)/' "$f"
		sed -i -E '/^warp_remove\(struct platform_device \*pdev\)$/,/^}$/ { s/^([[:space:]]*)return -1;[[:space:]]*$/\1return;/; s/^([[:space:]]*)return 0;[[:space:]]*$/\1return;/ }' "$f"
		grep -A1 '^static void$' "$f" | grep -q '^warp_remove' \
			|| die "warp_remove 未改成 void: ${f#"$WRT_DIR"/}"
	done
	note "warp_remove → void（6.18 platform_driver.remove）"

	# 归一化未命中就立即失败，避免把问题拖到 2h 后的编译阶段。
	# strlcpy 用词边界排除 nla_strlcpy（后者单独替换为 nla_strscpy）。
	n=$(grep -rlE '(^|[^[:alnum:]_])strlcpy\(' "$MTK_DRV" --include='*.c' --include='*.h' 2>/dev/null | wc -l)
	[ "$n" -eq 0 ] || die "API 归一化未覆盖: strlcpy(（$n 文件）"
	for pat in 'nla_strlcpy(' 'rtc_time_to_tm(' 'netif_rx_ni(' 'return init_dummy_netdev(dev);' \
		'pci_set_dma_mask(pdev,' 'pci_set_consistent_dma_mask(pdev,'; do
		n=$(grep -rlF "$pat" "$MTK_DRV" --include='*.c' --include='*.h' 2>/dev/null | wc -l)
		[ "$n" -eq 0 ] || die "API 归一化未覆盖: $pat（$n 文件）"
	done
	TRACE_LEFT=$(find "$MTK_DRV" -path '*/include/os/trace.h' -type f \
		-exec grep -l 'do_gettimeofday(&time);' {} + 2>/dev/null | wc -l)
	[ "$TRACE_LEFT" -eq 0 ] || die "trace.h 时间戳归一化未覆盖（$TRACE_LEFT 文件）"
	WERR_LEFT=$(grep -rlE -- '(^|[[:space:]])-Werror([[:space:]]|$)' "$MTK_DRV" \
		--include='Makefile' --include='*.mk' 2>/dev/null | wc -l)
	[ "$WERR_LEFT" -eq 0 ] || die "-Werror 归一化未覆盖（$WERR_LEFT 文件）"
else
	note "WARN: 无 package/mtk/drivers，跳过 API 归一化"
fi

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

# pdn 的 wifi_utility 只导出 mt_mtd_read_nm_wifi()/mt_mtd_write_nm_wifi()；
# legacy 栈（conninfra、mt_wifi 767x）调用的是 chasey 999-zzz-5203 补丁引入的
# mt_eeprom_read_wifi()/mt_eeprom_write_wifi()。只搬 pdn 版本会缺这两个符号，
# 模块 modpost 阶段报 undefined。补回最小实现（Factory/factory 回退），
# 并挂进 wifi_utility 的 Makefile。
EEPROM_C="$GITHUB_WORKSPACE/port/wifi-utility/mt_wifi_eeprom.c"
WU_DIR="$WRT_DIR/target/linux/mediatek/files-$KVER/drivers/net/wireless/wifi_utility"
if [ -f "$EEPROM_C" ] && [ -d "$WU_DIR" ]; then
	cp -f "$EEPROM_C" "$WU_DIR/mt_wifi_eeprom.c" || die "mt_wifi_eeprom.c 复制失败"
	grep -q 'mt_wifi_eeprom\.o' "$WU_DIR/Makefile" \
		|| echo 'obj-y += mt_wifi_eeprom.o' >> "$WU_DIR/Makefile"
	note "mt_eeprom_* 后备 → files-$KVER/.../wifi_utility（conninfra / mt_wifi 链接）"
else
	note "WARN: 跳过 mt_eeprom_* 后备（缺 $EEPROM_C 或 wifi_utility 目录）"
fi

# platform_driver.remove 自 6.11 起返回 void；pdn 的 rbus_remove 仍是 int，
# 在 GCC 14 下是 incompatible-pointer-types 错误。
RBUS="$WU_DIR/pci_mediatek_rbus.c"
if [ -f "$RBUS" ]; then
	sed -i 's/^static int rbus_remove(struct platform_device \*pdev)$/static void rbus_remove(struct platform_device *pdev)/' "$RBUS"
	sed -i '/^static void rbus_remove(struct platform_device \*pdev)$/,/^}$/ { /^\treturn 0;$/d }' "$RBUS"
	note "rbus_remove → void（6.18 platform_driver.remove）"
fi

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
	CONFIG_NET_MEDIATEK_HNAT=m \
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
