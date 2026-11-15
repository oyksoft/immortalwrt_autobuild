#!/bin/sh
# install-passwall-core.sh
# 在 R66S 上跑：安装 passwall 核心（/usr/share/passwall 下的 Lua 脚本集）
#
# 背景：
#   固件里已预装 luci-app-passwall（UI）+ luci-i18n-passwall-zh-cn + 各代理引擎
#   （sing-box / xray-core / hysteria 等）。
#   但 passwall 核心包不在任何 ImmortalWrt/OpenWrt 预编译仓里——
#   Openwrt-Passwall 仓只 source build，没有 release apk。
#   所以这里从 GitHub 拉源码，把文件手动装到系统目录。
#
# 兼容 apk（OpenWrt 25.12+）和 opkg（旧版）。

set -e

echo "=== passwall 核心安装 ==="

# --- 检测包管理器 ---
if command -v apk >/dev/null 2>&1; then
	PKG="apk"
elif command -v opkg >/dev/null 2>&1; then
	PKG="opkg"
else
	echo "❌ 找不到 apk / opkg，无法继续"
	exit 1
fi
echo "包管理器：$PKG"

# --- 准备工具（wget/tar busybox 自带，缺了再装）---
command -v wget >/dev/null 2>&1 || $PKG add wget >/dev/null 2>&1 || $PKG install wget >/dev/null 2>&1 || true
command -v tar  >/dev/null 2>&1 || $PKG add tar  >/dev/null 2>&1 || $PKG install tar  >/dev/null 2>&1 || true

echo "=== [1/4] 下 passwall 核心源码 ==="
cd /tmp
rm -rf passwall-pkg passwall.tar.gz
if ! wget -q -O passwall.tar.gz \
	"https://github.com/immortalwrt/openwrt-passwall-packages/archive/refs/heads/openwrt-25.12.tar.gz"; then
	echo "  · immortalwrt 分支失败，改用 Openwrt-Passwall 主仓"
	wget -q -O passwall.tar.gz \
		"https://github.com/Openwrt-Passwall/openwrt-passwall-packages/archive/refs/heads/main.tar.gz"
fi
tar -xzf passwall.tar.gz

PKG_DIR=$(find . -path '*/package/passwall' -type d 2>/dev/null | head -1)
if [ -z "$PKG_DIR" ]; then
	echo "❌ 源码里没找到 package/passwall 目录"
	exit 1
fi
echo "  passwall 包目录：$PKG_DIR"

echo "=== [2/4] 安装核心文件 ==="
if [ -d "$PKG_DIR/files/usr/share/passwall" ]; then
	mkdir -p /usr/share/passwall
	cp -r "$PKG_DIR/files/usr/share/passwall/." /usr/share/passwall/
	chmod +x /usr/share/passwall/*.sh 2>/dev/null || true
	echo "  ✓ /usr/share/passwall（$(find /usr/share/passwall -type f | wc -l) 个文件）"
else
	echo "  ⚠️  源码里没有 files/usr/share/passwall"
fi

if [ -f "$PKG_DIR/files/etc/config/passwall" ]; then
	# 不覆盖用户已有配置
	if [ -f /etc/config/passwall ]; then
		echo "  · /etc/config/passwall 已存在，保留用户配置"
	else
		cp "$PKG_DIR/files/etc/config/passwall" /etc/config/passwall
		echo "  ✓ /etc/config/passwall"
	fi
fi

if [ -f "$PKG_DIR/files/etc/init.d/passwall" ]; then
	cp "$PKG_DIR/files/etc/init.d/passwall" /etc/init.d/passwall
	chmod +x /etc/init.d/passwall
	echo "  ✓ /etc/init.d/passwall"
fi

echo "=== [3/4] 启用服务 ==="
/etc/init.d/passwall enable  2>/dev/null || true
/etc/init.d/passwall restart 2>/dev/null || true
sleep 1

echo "=== [4/4] 验证 ==="
if [ -f /usr/share/passwall/util.lua ]; then
	echo "  ✓ 核心文件已就位（/usr/share/passwall/util.lua）"
else
	echo "  ⚠️  没找到 /usr/share/passwall/util.lua，核心可能不完整"
fi
echo "  passwall 服务状态："
/etc/init.d/passwall status 2>&1 | head -5 | sed 's/^/    /' || true

echo ""
echo "🎉 装好了。"
echo "   LuCI 入口：http://192.168.100.1/cgi-bin/luci/admin/services/passwall"
echo "   在页面里配置节点订阅 / 单个节点 URL，点「保存并应用」。"
echo ""
echo "提示：如果 LuCI 里看不到 Passwall 菜单，强制刷新浏览器（Ctrl+F5）；"
echo "      仍然没有就执行：rm -f /tmp/luci-indexcache* && /etc/init.d/uhttpd restart"
