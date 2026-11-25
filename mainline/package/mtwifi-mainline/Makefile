include $(TOPDIR)/rules.mk

PKG_NAME:=mtwifi-mainline
PKG_VERSION:=1
PKG_RELEASE:=3

include $(INCLUDE_DIR)/package.mk

define Package/mtwifi-mainline
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Mainline MediaTek WiFi and flow offload defaults
  DEPENDS:=+firewall4 +ethtool +nftables +kmod-nft-offload
endef

define Package/mtwifi-mainline/install
	$(INSTALL_DIR) $(1)/etc/modprobe.d
	$(INSTALL_DATA) ./files/etc/modprobe.d/mt7915e.conf $(1)/etc/modprobe.d/mt7915e.conf
	$(INSTALL_DATA) ./files/etc/modprobe.d/mt7996e.conf $(1)/etc/modprobe.d/mt7996e.conf
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-mtwifi-offload $(1)/etc/uci-defaults/90-mtwifi-offload
	$(INSTALL_DIR) $(1)/etc/hotplug.d/net
	$(INSTALL_BIN) ./files/etc/hotplug.d/net/99-mtwifi-usb-offload $(1)/etc/hotplug.d/net/99-mtwifi-usb-offload
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/mtwifi-offload-status $(1)/usr/sbin/mtwifi-offload-status
endef

define Build/Compile
endef

$(eval $(call BuildPackage,mtwifi-mainline))
