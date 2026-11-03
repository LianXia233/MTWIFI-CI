#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
#
# feeds.sh —— 第三方插件注入（为本仓库精选，不做大而全）
# 在 wrt 根目录执行（feeds install 之后、defconfig 之前）。

set -uo pipefail

# 用上游仓库替换 feeds 内的同名包：DELETE <feed内目录名...> 然后 clone 到 package/
pull() {
	local repo="$1" ref="$2" name="$3" extra="${4:-}"
	local dest="./package/${repo#*/}"

	for old in $name $extra; do
		find ./feeds/luci ./feeds/packages -maxdepth 3 -type d -iname "$old" \
			-exec rm -rf {} + 2>/dev/null || true
	done

	git clone -q --depth=1 --branch "$ref" "https://github.com/$repo.git" "$dest" || {
		echo "[feeds] WARN: $repo@$ref 克隆失败，跳过"; return 0; }
	echo "[feeds] $repo@$ref -> $dest"
}

echo "== 主题 =="
pull anothaDev/luci-theme-vantage      main   "luci-theme-vantage"
pull sbwml/luci-theme-argon            openwrt-25.12 "luci-theme-argon"
pull eamonxg/luci-theme-aurora         master "luci-theme-aurora"
pull eamonxg/luci-app-aurora-config    master "luci-app-aurora-config"

echo "== 科学上网 =="
pull vernesong/OpenClash               dev   "openclash"        # pkg 提取略：整仓可用
pull Openwrt-Passwall/openwrt-passwall2 main "luci-app-passwall2 passwall2"
pull nikkinikki-org/OpenWrt-nikki      main  "nikki mihomo-alpha"

echo "== 系统增强 =="
pull 4IceG/luci-app-mini-diskmanager   main  "luci-app-mini-diskmanager"
pull EasyTier/luci-app-easytier        main  "luci-app-easytier"
pull FUjr/QModem                       main  "QModem"

echo "== 自家插件（LianXia233）=="
pull LianXia233/luci-app-airpi3000m-fancontrol main "luci-app-airpi3000m-fancontrol"
pull LianXia233/luci-app-h5000m-fancontrol     main "luci-app-h5000m-fancontrol"
pull LianXia233/luci-app-h5000m-netmode        main "luci-app-h5000m-netmode"
pull LianXia233/luci-app-mt5700                main "luci-app-mt5700"
pull LianXia233/luci-app-netmonitor            main "luci-app-netmonitor"
pull LianXia233/luci-app-qmodem-generic        main "luci-app-qmodem-generic"
pull LianXia233/luci-app-chfs                  main "luci-app-chfs"
pull LianXia233/luci-app-fm350                 main "luci-app-fm350"

# 私有扩展（存在才执行）
if [ -f "$GITHUB_WORKSPACE/Scripts/feeds.private.sh" ]; then
	source "$GITHUB_WORKSPACE/Scripts/feeds.private.sh"
fi

exit 0
