# SPDX-License-Identifier: MIT
# overlay-mtk: mt_hwifi-symvers
# 6.18 移植：mt_hwifi modpost 前的 mt_wifi7 符号表探测（由 overlay-mtk.sh 注入到
# 第一个 $(eval $(call KernelPackage,mt_hwifi)) 之前）。
#
# 与 mt_wifi7 一样，Hooks/Compile/Pre 必须在 eval 前加入才会进入 recipe。
# 四美元：eval 展开一次，recipe 再展开一次，最终交给 shell 的才是 $(cmd)/$var。
PKG_EXTMOD_SUBDIRS:=wlan_hwifi

define mt_hwifi_symvers_probe
	@f="$(PKG_SYMVERS_DIR)/mt_wifi7.symvers"; \
	 echo "[mt_hwifi] mt_wifi7.symvers=$$$$(wc -l < "$$$$f" 2>/dev/null || echo missing) lines"; \
	 grep -m4 -E 'mtk_mac_alloc_hw|mtk_mac_rx|is_amsdu_capable' "$$$$f" 2>/dev/null \
	  || echo "[mt_hwifi] mt_wifi7.symvers 缺少 mtk_mac_*/is_amsdu_capable"
endef
Hooks/Compile/Pre += mt_hwifi_symvers_probe
