#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
#
# verify-artifacts.sh —— 构建后产物级移植校验
#
# 位置：必须在"收拢固件产物"之前执行（那一步会删掉 manifest / buildinfo / Packages）。
# 断言的是"产物里真的有 HNAT 驱动"，而不是"编译没报错"：
#   1) mtkhnat.ko 存在，且是目标架构的可重定位对象
#   2) modules.dep 收录 mtkhnat，modules.builtin 不得收录（它必须是模块）
#   3) 内核 .config 里 HNAT / NETSYS / bridge-netfilter 生效
#   4) 固件 manifest 里含 kmod-mediatek_hnat
#   5) 该 kmod 包的架构字段与目标一致，镜像文件名含目标设备名

set -uo pipefail

BASE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WRT="$BASE/wrt"

FAIL=0
err() { echo "[artifacts] FAIL  $*"; FAIL=1; }
ok()  { echo "[artifacts] OK    $*"; }

[ -d "$WRT" ] || { echo "[artifacts] FATAL: 缺 $WRT"; exit 1; }

case "${WRT_CONFIG:-}" in
	H5000M*)  STACK=wifi7 ;;
	AP3000M*) STACK=legacy ;;
	*)        STACK=unknown ;;
esac
echo "== 驱动栈: $STACK =="

KDIR=$(ls -d "$WRT"/build_dir/target-*/linux-*/linux-* 2>/dev/null | head -n1)
[ -n "${KDIR:-}" ] || { echo "[artifacts] FATAL: 找不到内核构建目录（build_dir/target-*/linux-*/linux-*）"; exit 1; }
ok "内核构建目录：${KDIR#$WRT/}"

# ---- 1. 模块本体 ---------------------------------------------------------
KO=$(find "$KDIR" -name 'mtkhnat.ko' 2>/dev/null | head -n1)
if [ -n "${KO:-}" ]; then
	ok "mtkhnat.ko 存在：${KO#$WRT/}（$(wc -c < "$KO") 字节）"
	if command -v file >/dev/null 2>&1; then
		DESC=$(file -b "$KO")
		case "$DESC" in
			*aarch64*|*ARM*) ok "模块架构：$DESC" ;;
			*) err "模块架构异常：$DESC" ;;
		esac
	fi
else
	err "找不到 mtkhnat.ko（HNAT 驱动没有编出来）"
fi

# ---- 2. 模块依赖表 -------------------------------------------------------
DEP="$KDIR/modules.dep"
BUILTIN="$KDIR/modules.builtin"
if [ -f "$DEP" ]; then
	if grep -q 'mtkhnat' "$DEP"; then
		ok "modules.dep 收录 mtkhnat"
	else
		err "modules.dep 未收录 mtkhnat"
	fi
else
	err "缺 $DEP"
fi
if [ -f "$BUILTIN" ]; then
	if grep -q 'mtkhnat' "$BUILTIN"; then
		err "modules.builtin 出现 mtkhnat（应为模块，内置会让 kmod 包为空）"
	else
		ok "mtkhnat 未被打进内核镜像（保持模块形态）"
	fi
else
	err "缺 $BUILTIN"
fi

# ---- 3. 内核配置生效 -----------------------------------------------------
KCONF="$KDIR/.config"
if [ -f "$KCONF" ]; then
	for sym in 'CONFIG_NET_MEDIATEK_HNAT=y' \
	           'CONFIG_BRIDGE_NETFILTER=y' \
	           'CONFIG_NETFILTER_FAMILY_BRIDGE=y'; do
		if grep -qx "$sym" "$KCONF"; then
			ok "内核配置含 $sym"
		else
			err "内核配置缺 $sym"
		fi
	done
	if [ "$STACK" = legacy ]; then
		grep -qx 'CONFIG_MEDIATEK_NETSYS_V2=y' "$KCONF" && ok "内核配置：NETSYS V2" \
			|| err "内核配置缺 CONFIG_MEDIATEK_NETSYS_V2=y"
		grep -qx '# CONFIG_MEDIATEK_NETSYS_V3 is not set' "$KCONF" && ok "内核配置：NETSYS V3 关闭" \
			|| err "内核配置未关闭 NETSYS V3"
	elif [ "$STACK" = wifi7 ]; then
		grep -qx 'CONFIG_MEDIATEK_NETSYS_V3=y' "$KCONF" && ok "内核配置：NETSYS V3" \
			|| err "内核配置缺 CONFIG_MEDIATEK_NETSYS_V3=y"
		grep -qx '# CONFIG_MEDIATEK_NETSYS_V2 is not set' "$KCONF" && ok "内核配置：NETSYS V2 关闭" \
			|| err "内核配置未关闭 NETSYS V2"
	fi
else
	err "缺内核 .config：$KCONF"
fi

# ---- 4. manifest 里的 kmod 包 -------------------------------------------
MANIFEST=$(find "$WRT/bin/targets" -name '*.manifest' 2>/dev/null | head -n1)
if [ -n "${MANIFEST:-}" ]; then
	if grep -q '^kmod-mediatek_hnat ' "$MANIFEST"; then
		ok "manifest 含 kmod-mediatek_hnat"
	else
		err "manifest 未含 kmod-mediatek_hnat（$(basename "$MANIFEST")）"
	fi
else
	err "找不到固件 manifest（bin/targets/*/*/*.manifest）"
fi

# ---- 5. 架构与设备名 -----------------------------------------------------
ARCH=$(sed -n 's/^CONFIG_TARGET_ARCH_PACKAGES="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$WRT/.config" 2>/dev/null | head -n1)
IPK=$(find "$WRT/bin/targets" -name 'kmod-mediatek_hnat_*.ipk' 2>/dev/null | head -n1)
if [ -n "${IPK:-}" ]; then
	ok "kmod 包：$(basename "$IPK")"
	if [ -n "${ARCH:-}" ]; then
		case "$(basename "$IPK")" in
			*"_${ARCH}.ipk") ok "kmod 包架构匹配：$ARCH" ;;
			*) err "kmod 包架构不匹配（期望 $ARCH）：$(basename "$IPK")" ;;
		esac
	fi
else
	err "找不到 kmod-mediatek_hnat_*.ipk"
fi

DEVICE=$(grep -oP '^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_\K[^=]+(?==y)' "$WRT/.config" 2>/dev/null | head -n1)
if [ -n "${DEVICE:-}" ]; then
	IMG=$(find "$WRT/bin/targets" -type f -name "*${DEVICE}*sysupgrade*" 2>/dev/null | head -n1)
	if [ -n "${IMG:-}" ]; then
		ok "固件镜像匹配设备 $DEVICE：$(basename "$IMG")"
	else
		err "未找到含设备名 $DEVICE 的 sysupgrade 镜像"
	fi
else
	err "无法从 .config 解析目标设备"
fi

echo ""
if [ "$FAIL" -eq 1 ]; then
	echo "[artifacts] 产物级校验失败。"
	exit 1
fi
echo "[artifacts] 产物级校验全部通过。"
