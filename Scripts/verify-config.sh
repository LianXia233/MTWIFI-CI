#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
#
# verify-config.sh —— defconfig 之后的强校验（在 wrt 根目录执行）
#
# 背景：defconfig 会把写错名字/写错层级的符号静默丢弃，最终编出
# target.mk 默认设备（如 openwrt_one）或漏掉闭源驱动栈。本脚本把
# 这类事故提前到编译前拦截。

set -uo pipefail

FAIL=0
err() { echo "[verify] ✗ $*"; FAIL=1; }
ok()  { echo "[verify] ✓ $*"; }

require() { # require <描述> <grep -E 模式>
	if grep -Eq "$2" .config; then
		ok "$1"
	else
		err "$1"
	fi
}

echo "== 设备与平台 =="
require "目标是 mediatek"        '^CONFIG_TARGET_mediatek=y$'
require "子目标是 filogic"       '^CONFIG_TARGET_mediatek_filogic=y$'

DEVICE_LINE=$(grep -E '^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_.+=y$' .config | head -n1)
if [ -n "$DEVICE_LINE" ]; then
	ok "锁定设备: ${DEVICE_LINE#CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_}"
else
	err "未锁定任何设备（CONFIG_TARGET_DEVICE_...=y）——defconfig 将回退默认设备！"
fi

echo "== 闭源驱动栈 =="
require "mt_wifi / mt_wifi7 至少一个被选中" \
	'^CONFIG_PACKAGE_kmod-mt(_wifi7?)=y$'
require "kmod-warp（WED 卸载引擎）" '^CONFIG_PACKAGE_kmod-warp=y$'
require "kmod-conninfra"           '^CONFIG_PACKAGE_kmod-conninfra=y$'
require "kmod-mediatek_hnat（HNAT 硬件加速）" \
	'^CONFIG_PACKAGE_kmod-mediatek_hnat=y$'

echo "== 用户态 =="
require "datconf（驱动参数数据面）" '^CONFIG_PACKAGE_datconf=y$'
if grep -Eq '^CONFIG_PACKAGE_mtwifi-cfg-ucode=y$' .config; then
	ok "mtwifi 前端: ucode 版"
	require "luci-app-mtwifi-cfg" '^CONFIG_PACKAGE_luci-app-mtwifi-cfg=y$'
elif grep -Eq '^CONFIG_PACKAGE_mtwifi-cfg=y$' .config; then
	ok "mtwifi 前端: lua 版"
else
	err "mtwifi 用户态前端缺失（mtwifi-cfg 或 mtwifi-cfg-ucode）"
fi
require "luci-app-turboacc-mtk（加速开关 UI）" '^CONFIG_PACKAGE_luci-app-turboacc-mtk=y$'

echo "== 双栈冲突检查 =="
# 闭源驱动接管无线，主线 mt76 栈不应被显式选中（DEVICE_PACKAGES 默认项允许存在，
# 但显式 =y 视为配置错误——两套驱动同时绑同一 wmac 没有意义）
if grep -Eq '^CONFIG_PACKAGE_kmod-mt7915e=y$' .config; then
	err "kmod-mt7915e 被显式选中，与闭源 mt_wifi 冲突（应为 is not set）"
else
	ok "mt76 内置 WiFi 栈未显式选中"
fi

echo ""
if [ "$FAIL" -eq 1 ]; then
	echo "[verify] 配置校验失败，停止构建。请修正 Config/*.txt 中的符号名与层级。"
	exit 1
fi
echo "[verify] 配置校验全部通过。"
