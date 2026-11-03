# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# Copyright (C) 2026 LianXia233 (adaptation)
#
# 保留 OpenWrt 原生 host 打点，但跳过源码下载与 bootstrap，
# 直接使用 runner 上预置的 Rust 工具链（CI_RUST_ROOT 由 rust-toolchain.sh 注入）。

PKG_SOURCE:=
PKG_SOURCE_URL:=

define Host/Prepare
endef

define Host/Configure
endef

define Host/Compile
	"$(CI_RUST_ROOT)/bin/rustc" --version
endef

define Host/Install
	$(INSTALL_DIR) $(STAGING_DIR)/host/bin
	ln -sfn "$(CI_RUST_ROOT)/bin/cargo" "$(STAGING_DIR)/host/bin/cargo"
	ln -sfn "$(CI_RUST_ROOT)/bin/rustc" "$(STAGING_DIR)/host/bin/rustc"
	ln -sfn "$(CI_RUST_ROOT)/bin/rustdoc" "$(STAGING_DIR)/host/bin/rustdoc"
endef

define Host/Uninstall
	rm -f $(addprefix $(STAGING_DIR)/host/bin/,cargo rustc rustdoc)
endef
