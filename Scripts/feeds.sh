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

# luci-app-taygedo（塔吉多签到）：上游是 monorepo，包在 openwrt/luci-app-taygedo。
# 只在配置显式选中时导入；Rust 后端用上游 Release 的 aarch64 openwrt 形态预编译
# 二进制（taygedo-rs-*-openwrt.tar.gz），预取到 dl/，避免在 buildroot 里跑 cargo。
if [ "${WRT_CONFIG:-}" != "" ] \
	&& grep -qx 'CONFIG_PACKAGE_luci-app-taygedo=y' \
		"${GITHUB_WORKSPACE:-.}/Config/$WRT_CONFIG.txt" 2>/dev/null; then
	echo "[feeds] 导入 luci-app-taygedo（预编译 Rust 后端）"
	rm -rf ./package/luci-app-taygedo ./.taygedo-src
	git clone -q --depth=1 --branch main \
		https://github.com/LianXia233/taygedo-CI.git ./.taygedo-src || {
		echo "[feeds] ERROR: taygedo-CI 克隆失败" >&2; exit 1; }
	[ -d ./.taygedo-src/openwrt/luci-app-taygedo ] || {
		echo "[feeds] ERROR: taygedo-CI 缺少 openwrt/luci-app-taygedo" >&2; exit 1; }
	cp -a ./.taygedo-src/openwrt/luci-app-taygedo ./package/
	rm -rf ./.taygedo-src

	TG_MK=./package/luci-app-taygedo/Makefile
	# TAYGEDO_VER 在上游写作 v$(PKG_VERSION)，这里直接展开 PKG_VERSION。
	TG_PKGVER=$(sed -n 's/^PKG_VERSION:=//p' "$TG_MK" | head -n1)
	TG_VER="v${TG_PKGVER}"
	TG_TRIPLE=aarch64-unknown-linux-musl
	TG_ASSET="taygedo-rs-${TG_TRIPLE}-openwrt.tar.gz"
	[ -n "$TG_PKGVER" ] || { echo "[feeds] ERROR: taygedo Makefile 缺 PKG_VERSION" >&2; exit 1; }
	mkdir -p ./dl
	if [ ! -s "./dl/$TG_ASSET" ]; then
		curl -fL --retry 3 --retry-delay 2 \
			-o "./dl/$TG_ASSET.part" \
			"https://github.com/LianXia233/taygedo-CI/releases/download/${TG_VER}/${TG_ASSET}" \
			|| { rm -f "./dl/$TG_ASSET.part"; echo "[feeds] ERROR: taygedo 资产下载失败" >&2; exit 1; }
		mv -f "./dl/$TG_ASSET.part" "./dl/$TG_ASSET"
	fi
	tar tzf "./dl/$TG_ASSET" 2>/dev/null | grep -qx 'taygedo-rs' || {
		echo "[feeds] ERROR: ${TG_ASSET} 内没有 taygedo-rs" >&2; exit 1; }
	echo "[feeds] luci-app-taygedo @ ${TG_VER}，资产 ${TG_ASSET}"
fi

# luci-app-mt5700：src/Makefile 直接调 cargo，没有为 musl 目标指定交叉链接器，
# CI 里会退回宿主 cc（aarch64 的 --fix-cortex-a53-843419 直接报错）。
# OpenWrt 会 export TARGET_CC_NOCACHE；在 cargo 命令行前按 RUST_TARGET 注入
# CARGO_TARGET_<TRIPLE>_LINKER。包后续若自行处理，检测到 _LINKER 就跳过。
MT5700_SRC="./package/luci-app-mt5700/src/Makefile"
if [ -f "$MT5700_SRC" ]; then
	python3 - "$MT5700_SRC" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
bs = chr(92)
anchor = '\t\tMT5700_VERSION="$(MT5700_VERSION)" ' + bs + '\n'
add = ('\t\tCARGO_TARGET_$(shell echo $(RUST_TARGET) | tr "a-z-" "A-Z_")'
       '_LINKER="$(TARGET_CC_NOCACHE)" ' + bs + '\n')
if '_LINKER' not in s and anchor in s:
    open(p, 'w', encoding='utf-8', newline='').write(s.replace(anchor, anchor + add, 1))
    print('[feeds] luci-app-mt5700: 注入 CARGO_TARGET_*_LINKER')
else:
    print('[feeds] luci-app-mt5700: 已存在链接器设置或锚点未命中，跳过')
PY
fi

# 私有扩展（存在才执行）
if [ -f "$GITHUB_WORKSPACE/Scripts/feeds.private.sh" ]; then
	source "$GITHUB_WORKSPACE/Scripts/feeds.private.sh"
fi

exit 0
