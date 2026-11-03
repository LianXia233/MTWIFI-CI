#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
#
# tweaks.sh —— 个性化与设备资产注入（在 wrt 根目录执行，defconfig 之前）
# 覆盖：出厂默认（IP/主机名/主题/语言）、mtwifi 出厂无线参数、
#       AP3000M EEPROM 模板、主题细节修正。全部带守卫，缺包不中断。

set -uo pipefail

say() { echo "[tweaks] $*"; }
sed_or_skip() { # sed_or_skip <说明> <目标文件> <sed 表达式...>
	local desc="$1" file="$2"; shift 2
	if [ -f "$file" ]; then
		sed -i "$@" "$file" && say "$desc: ok"
	else
		say "$desc: 跳过（$file 不存在）"
	fi
}

# ---------------------------------------------------------------------------
# 出厂默认：后台 IP / 主机名
# ---------------------------------------------------------------------------
sed_or_skip "后台地址" ./package/base-files/files/bin/config_generate \
	-e "s/192\.168\.[0-9]*\.[0-9]*/${WRT_LAN_IP:-192.168.10.1}/g" \
	-e "s/hostname='.*'/hostname='${WRT_HOSTNAME:-OWRT}'/g"

# ---------------------------------------------------------------------------
# 默认主题与中文
# ---------------------------------------------------------------------------
THEME="${WRT_THEME:-vantage}"
sed_or_skip "默认主题" ./feeds/luci/collections/luci/Makefile \
	-e "s/luci-theme-bootstrap/luci-theme-$THEME/g"

cat >> .config <<EOF
CONFIG_PACKAGE_luci=y
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-theme-$THEME=y
EOF
[ "$THEME" = "vantage" ] && echo 'CONFIG_PACKAGE_luci-app-vantage=y' >> .config
[ -f "./package/luci-app-aurora-config/Makefile" ] && echo 'CONFIG_PACKAGE_luci-app-aurora-config=y' >> .config

# vantage 进度条字体修正（anothaDev/luci-theme-vantage#52）
if [ -f ./package/luci-theme-vantage/luci-theme-vantage/htdocs/luci-static/vantage/vantage.css ]; then
	sed -i \
		-e '/^\/\* progress bars: thin track/,$ { /^\.cbi-progressbar::before {/,/^}/ { s/^[[:space:]]*font: 500 var(--fs-micro)\/1\.2 var(--mono);/\tfont: inherit; line-height: normal;/; } }' \
		./package/luci-theme-vantage/luci-theme-vantage/htdocs/luci-static/vantage/vantage.css
	say "vantage css 修正: ok"
fi

# ---------------------------------------------------------------------------
# mtwifi 出厂无线参数（闭源驱动两套配置前端都适配）
#   lua 版：package/mtk/applications/mtwifi-cfg/files/mtwifi.sh
#   ucode 版：package/mtk/applications/mtwifi-cfg-ucode/files/lib/wifi/mtwifi.uc
# ---------------------------------------------------------------------------
MTWIFI_SH="./package/mtk/applications/mtwifi-cfg/files/mtwifi.sh"
if [ -f "$MTWIFI_SH" ]; then
	sed -i -E "s/ImmortalWrt/${WRT_SSID:-OWRT}/g; s/(.*)encryption=none/\1encryption=psk2+ccmp\n\1key=${WRT_WIFI_KEY:-12345678}/" \
		"$MTWIFI_SH"
	say "mtwifi(lua) 出厂 SSID/密钥: ok"
fi

MTWIFI_UC="./package/mtk/applications/mtwifi-cfg-ucode/files/lib/wifi/mtwifi.uc"
if [ -f "$MTWIFI_UC" ]; then
	sed -i "s/ImmortalWrt/${WRT_SSID:-OWRT}/g; s/\"none\"/\"psk2+ccmp\", \"key\": \"${WRT_WIFI_KEY:-12345678}\"/" \
		"$MTWIFI_UC"
	say "mtwifi(ucode) 出厂 SSID/密钥: ok"
	# ucode 前端与旧 Lua 组件互斥
	printf '# CONFIG_PACKAGE_mtwifi-cfg is not set\n# CONFIG_PACKAGE_iwinfo is not set\nCONFIG_PACKAGE_mtwifi-cfg-ucode=y\n' >> .config
fi

# ---------------------------------------------------------------------------
# AP3000M EEPROM 模板注入（首启 hotplug 初始化 factory 分区）
# 脚本自带板级守卫（仅 airpi,ap3000m 生效），H5000M 构建不受影响。
# ---------------------------------------------------------------------------
if [ -f "$GITHUB_WORKSPACE/AP3000M-EEPROM/99-ap3000m-eeprom" ]; then
	mkdir -p files/etc/hotplug.d/iface files/lib/firmware/mediatek
	cp -f "$GITHUB_WORKSPACE/AP3000M-EEPROM/99-ap3000m-eeprom" files/etc/hotplug.d/iface/
	cp -f "$GITHUB_WORKSPACE/AP3000M-EEPROM/mt7981_eeprom_mt7976_dbdc.bin" files/lib/firmware/mediatek/
	chmod +x files/etc/hotplug.d/iface/99-ap3000m-eeprom
	say "AP3000M EEPROM 模板: 注入 files/"
fi

# ---------------------------------------------------------------------------
# 状态页构建标识（LuCI 路径随版本漂移，用 find 定位）
# ---------------------------------------------------------------------------
find ./feeds/luci/modules/luci-mod-status -type f -name "10_system.js" 2>/dev/null \
	-exec sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ MTWIFI-CI-${WRT_DATE:-$(TZ=UTC-8 date +'%y.%m.%d')}')/g" {} +
say "构建标识: 已处理"

# 私有扩展
if [ -f "$GITHUB_WORKSPACE/Scripts/tweaks.private.sh" ]; then
	source "$GITHUB_WORKSPACE/Scripts/tweaks.private.sh"
fi

exit 0
