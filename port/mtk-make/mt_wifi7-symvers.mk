# SPDX-License-Identifier: MIT
# overlay-mtk: mt_wifi7-symvers
# 6.18 移植：mt_wifi7 符号表收集（由 Scripts/overlay-mtk.sh 注入到
# $(eval $(call KernelPackage,mt_wifi7)) 之前）。
#
# 必须放在 eval 之前：include/package.mk 的 BuildPackage → Build/CoreTargets
# 在 eval 时就把 $(Hooks/Compile/Post) 展开成 recipe，之后再 += 不会生效。
# 同理 PKG_EXTMOD_SUBDIRS 也必须此时已定义。
#
# OpenWrt 原生的 collect_module_symvers 假设 Module.symvers 的模块路径字段
# 包含 $(PKG_BUILD_DIR)，但 external kbuild 写的是相对路径（mt_wifi_ap/xxx.o），
# 过滤后 mt_wifi7.symvers 为空，mt_hwifi/connac_if modpost 报 mtk_mac_* undefined。
# 这里覆盖该函数：kbuild 产出的 mt_wifi_ap/Module.symvers 本身就是完整符号表。
# 注意本文件里的 shell 变量/命令替换要写四个 $：eval 展开一次，recipe 再展开一次。
PKG_EXTMOD_SUBDIRS:=mt_wifi_ap

define collect_module_symvers
	@echo "[mt_wifi7] symvers raw=$$$$(wc -l < $(PKG_BUILD_DIR)/mt_wifi_ap/Module.symvers 2>/dev/null || echo 0) mtk_mac=$$$$(grep -cE 'mtk_mac|is_amsdu_capable' $(PKG_BUILD_DIR)/mt_wifi_ap/Module.symvers 2>/dev/null || true)"
	mkdir -p "$(PKG_SYMVERS_DIR)"
	cp -f "$(PKG_BUILD_DIR)/mt_wifi_ap/Module.symvers" "$(PKG_SYMVERS_DIR)/$(PKG_NAME).symvers"
	@echo "[mt_wifi7] symvers dest=$$$$(wc -l < $(PKG_SYMVERS_DIR)/$(PKG_NAME).symvers)"
endef
