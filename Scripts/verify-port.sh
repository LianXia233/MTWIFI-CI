#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
#
# verify-port.sh —— 预构建移植校验（在 wrt 根目录、defconfig 之后执行）
#
# 目的：把"已经写进 .config 但 kernel KCONFIG 覆盖项没生成"这类静默失败提前拦下。
# 覆盖项由 scripts/package-metadata.pl kconfig 生成，规则是：
#   只有 CONFIG_PACKAGE_<包名>=y 的包，其 KCONFIG 行才会出现在 .config.override；
#   未出现在覆盖项里的带 prompt 新符号，内核 syncconfig 会以 (NEW) 追问，
#   非交互构建直接 Error 1（历史失败即 MediaTek Ethernet NETSYS V2 support (NEW)）。
# 因此这里断言的是"覆盖项"，不是"Config/*.txt 里写了"。

set -uo pipefail

FAIL=0
err() { echo "[port] FAIL  $*"; FAIL=1; }
ok()  { echo "[port] OK    $*"; }

[ -f rules.mk ] || { echo "[port] FATAL: 当前目录不是 OpenWrt 根目录"; exit 1; }

KVER=$(sed -n 's/^KERNEL_PATCHVER:=//p' target/linux/mediatek/Makefile 2>/dev/null | head -n1 | tr -d ' \t')
[ -n "$KVER" ] || { echo "[port] FATAL: 无法解析 KERNEL_PATCHVER"; exit 1; }

case "${WRT_CONFIG:-}" in
	H5000M*)  STACK=wifi7 ;;
	AP3000M*) STACK=legacy ;;
	*)        STACK=unknown ;;
esac

echo "== 当前代际: $KVER / 驱动栈: $STACK =="

PKGINFO=tmp/.packageinfo
if [ ! -f "$PKGINFO" ]; then
	echo "[port] FATAL: 缺 $PKGINFO（defconfig 之前的状态，无法生成覆盖项）"
	exit 1
fi
if [ ! -f .config ]; then
	echo "[port] FATAL: 缺 .config"
	exit 1
fi

OVERRIDE=$(mktemp)
trap 'rm -f "$OVERRIDE"' EXIT
if ! ./scripts/package-metadata.pl kconfig "$PKGINFO" .config "$KVER" > "$OVERRIDE" 2>"$OVERRIDE.err"; then
	echo "[port] FATAL: package-metadata.pl kconfig 执行失败"
	sed -n '1,20p' "$OVERRIDE.err" 2>/dev/null
	exit 1
fi
ok "覆盖项生成（$(wc -l < "$OVERRIDE") 行）"

in_override() { grep -qxF "$1" "$OVERRIDE"; }

# ---- 1. 包定义自身被选中 -------------------------------------------------
if grep -qx 'CONFIG_PACKAGE_kmod-mediatek_hnat=y' .config; then
	ok "kmod-mediatek_hnat 已被选中"
else
	err "kmod-mediatek_hnat 未被选中（CONFIG_PACKAGE_kmod-mediatek_hnat 不是 =y），其 KCONFIG 不会进入覆盖项"
fi

# ---- 2. HNAT 主符号必须出现在覆盖项 --------------------------------------
# HNAT 必须是 =m：包定义按 mtkhnat.ko 收集产物，写成 =y 会把它编进 vmlinux、
# 让 FILES 里的 .ko 不存在。不带值的裸符号在覆盖项里不会成型，所以显式写 =m。
for sym in CONFIG_NET_MEDIATEK_HNAT=m \
           CONFIG_BRIDGE_NETFILTER=y \
           CONFIG_NETFILTER_FAMILY_BRIDGE=y; do
	if in_override "$sym"; then
		ok "覆盖项含 $sym"
	else
		err "覆盖项缺 $sym（内核会按默认值走，HNAT 编不出来或编译失败）"
	fi
done

# ---- 3. 两代 NETSYS 都必须显式表态 --------------------------------------
# 本代 =y、另一代显式 not set。只写本代时，另一代仍是带 prompt 的新符号，
# syncconfig 会以 (NEW) 追问并中断非交互构建。
if [ "$STACK" = legacy ]; then
	OWN='CONFIG_MEDIATEK_NETSYS_V2=y';  OWN_NAME='V2'
	OTHER='CONFIG_MEDIATEK_NETSYS_V3';  OTHER_NAME='V3'
elif [ "$STACK" = wifi7 ]; then
	OWN='CONFIG_MEDIATEK_NETSYS_V3=y';  OWN_NAME='V3'
	OTHER='CONFIG_MEDIATEK_NETSYS_V2';  OTHER_NAME='V2'
else
	OWN=''; OTHER=''; OWN_NAME=''; OTHER_NAME=''
	err "无法从 WRT_CONFIG='${WRT_CONFIG:-}' 判定驱动栈，无法断言 NETSYS 代际"
fi

if [ -n "$OWN" ]; then
	if in_override "$OWN"; then
		ok "覆盖项含本代 $OWN_NAME（$OWN）"
	else
		err "覆盖项缺本代 $OWN_NAME（$OWN）"
	fi
	if in_override "# $OTHER is not set"; then
		ok "覆盖项显式关闭另一代 $OTHER_NAME"
	else
		err "覆盖项未显式关闭另一代 $OTHER_NAME（$OTHER）—— 会以 (NEW) 追问"
	fi
	# 反向断言：两代同时 =y 说明代际判定错乱
	if in_override 'CONFIG_MEDIATEK_NETSYS_V2=y' && in_override 'CONFIG_MEDIATEK_NETSYS_V3=y'; then
		err "覆盖项里两代 NETSYS 同时 =y"
	else
		ok "两代 NETSYS 未同时启用"
	fi
	# 反向断言：这两代必须是 bool。若有人改回 tristate，NET_MEDIATEK_SOC=m 时
	# 内核会把它降级成 m，autoconf.h 里只剩 _MODULE，闭源 HNAT 的
	# #if defined(CONFIG_MEDIATEK_NETSYS_Vx) 布局分支会全部失效。
	if grep -qxE 'CONFIG_MEDIATEK_NETSYS_V[23]=m' .config 2>/dev/null; then
		err "NETSYS 代际被降级成 =m —— 只能是 bool（见 port/README.md）"
	else
		ok "NETSYS 代际未被降级成 =m"
	fi
fi

# ---- 4. overlay 侧产物齐备 ----------------------------------------------
if [ -f "package/kernel/linux/modules/netdevices.mk" ]; then
	if grep -qE 'CONFIG_MEDIATEK_NETSYS_(STACK|OTHER)' package/kernel/linux/modules/netdevices.mk; then
		err "netdevices.mk 里仍有未替换的 NETSYS 占位符"
	else
		ok "netdevices.mk 无残留占位符"
	fi
else
	err "缺 package/kernel/linux/modules/netdevices.mk"
fi

RA_NAT="target/linux/mediatek/files-$KVER/include/net/ra_nat.h"
if [ -s "$RA_NAT" ]; then
	ok "头文件 ra_nat.h 就位（$(wc -c < "$RA_NAT") 字节）"
else
	err "缺 $RA_NAT —— 9xx-hnat 系列给 skbuff.c 插了 #include <net/ra_nat.h>"
fi

HNAT_DIR="target/linux/mediatek/files-$KVER/drivers/net/ethernet/mediatek/mtk_hnat"
if [ -d "$HNAT_DIR" ]; then
	NC=$(find "$HNAT_DIR" -name '*.c' | wc -l)
	if [ "$NC" -ge 4 ]; then
		ok "mtk_hnat 源码就位（$NC 个 .c 文件）"
	else
		err "mtk_hnat 源码文件过少（$NC 个）"
	fi
else
	err "缺 $HNAT_DIR"
fi

# ---- 5. port/kernel 的每一条补丁都必须原样落进 patches-<KVER> ------------
# 这一步直接验"overlay 真的搬了"，避免白名单/路径写错导致补丁静默丢失。
PDIR="target/linux/mediatek/patches-$KVER"
SRCP="${GITHUB_WORKSPACE:-$PWD}/port/kernel"
if [ -d "$PDIR" ] && [ -d "$SRCP" ]; then
	MISS=0
	for p in "$SRCP"/*.patch; do
		[ -e "$p" ] || continue
		b=$(basename "$p")
		if [ ! -f "$PDIR/$b" ]; then
			err "补丁未装载：$b"
			MISS=$((MISS + 1))
		elif ! cmp -s "$p" "$PDIR/$b"; then
			err "补丁内容与源不一致：$b"
			MISS=$((MISS + 1))
		fi
	done
	[ "$MISS" -eq 0 ] && ok "port/kernel 补丁全部原样装载（$(ls "$SRCP"/*.patch 2>/dev/null | wc -l) 条）"
else
	err "缺 $PDIR 或 $SRCP"
fi

echo ""
if [ "$FAIL" -eq 1 ]; then
	echo "[port] 移植覆盖项校验失败，停止构建。"
	exit 1
fi
echo "[port] 移植覆盖项校验全部通过。"
