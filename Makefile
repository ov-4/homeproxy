# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

LUCI_TITLE:=The modern ImmortalWrt proxy platform for ARM64/AMD64
LUCI_PKGARCH:=all
LUCI_DEPENDS:= \
	+sing-box \
	+firewall4 \
	+kmod-nft-tproxy \
	+ucode-mod-digest \
	+ucode-mod-socket

PKG_NAME:=luci-app-ov4proxy

define Package/luci-app-ov4proxy/conffiles
/etc/config/ov4proxy
/etc/ov4proxy/certs/
/etc/ov4proxy/ruleset/
/etc/ov4proxy/resources/direct_list.txt
/etc/ov4proxy/resources/proxy_list.txt
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
