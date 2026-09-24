#!/bin/sh
# install-passwall-core.sh
# 在 R66S 上跑：装 passwall 核心包 + luci-app-passwall UI + passwall 中文
#
# 我们的 IB build 已经把 luci-app-passwall + luci-i18n-passwall-zh-cn
# 塞到 /etc/apk/cache/ 了。问题是 passwall 核心包（Lua 脚本集）不在
# 任何 ImmortalWrt/Openwrt release 仓里——必须手动装。
#
# 这个脚本：从 GitHub 拉 passwall 核心源码 → 手动 cp 到系统目录 → 
# 喂给 opkg 一个"假"包信息 → 然后 opkg install luci-app-passwall

set -e

echo "=== [1/5] 准备工具 ==="
opkg update
opkg install wget tar xz findutils

echo "=== [2/5] 下 passwall 核心源码（openwrt-passwall-packages 仓）==="
cd /tmp
rm -rf passwall-pkg
wget -q -O passwall.tar.gz \
  "https://github.com/immortalwrt/openwrt-passwall-packages/archive/refs/heads/openwrt-25.12.tar.gz" \
  || wget -q -O passwall.tar.gz \
     "https://github.com/Openwrt-Passwall/openwrt-passwall-packages/archive/refs/heads/main.tar.gz"
tar -xzf passwall.tar.gz
PKG_DIR=$(find . -path '*/package/passwall' -type d 2>/dev/null | head -1)
if [ -z "$PKG_DIR" ]; then
  echo "❌ 没找到 passwall 包目录"
  exit 1
fi
echo "  passwall 包目录：$PKG_DIR"

echo "=== [3/5] cp Lua 脚本到 /usr/share/passwall ==="
mkdir -p /usr/share/passwall
if [ -d "$PKG_DIR/files/usr/share/passwall" ]; then
  cp -r "$PKG_DIR/files/usr/share/passwall/"* /usr/share/passwall/
  chmod +x /usr/share/passwall/*.sh 2>/dev/null || true
  echo "  ✓ Lua 脚本 cp 完成"
else
  echo "  ⚠️  files/usr/share/passwall 不存在"
fi

# UCI 默认配置
if [ -f "$PKG_DIR/files/etc/config/passwall" ]; then
  cp "$PKG_DIR/files/etc/config/passwall" /etc/config/passwall
  echo "  ✓ UCI config cp 完成"
fi

# init 脚本
if [ -f "$PKG_DIR/files/etc/init.d/passwall" ]; then
  cp "$PKG_DIR/files/etc/init.d/passwall" /etc/init.d/passwall
  chmod +x /etc/init.d/passwall
  echo "  ✓ init.d cp 完成"
fi

echo "=== [4/5] 注册假包让 opkg 知道 passwall 装了 ==="
mkdir -p /var/opkg-info
cat > /var/opkg-info/passwall.control <<'EOF'
Package: passwall
Version: 99
Description: OpenWrt Passwall core (manually installed)
Maintainer: local
Section: net
Priority: optional
Depends: libc, coreutils
EOF
echo "  ✓ /var/opkg-info/passwall.control"

echo "=== [5/5] 装 luci-app-passwall 和 i18n（IB build 预装的） ==="
# luci-app-passwall.apk 和 luci-i18n-passwall-zh-cn.apk 在 /etc/apk/cache/
# （IB build 时 inject-passwall.sh 下载进去的）
ls -la /etc/apk/cache/25.12+_luci-app-passwall*.apk 2>/dev/null || echo "  ⚠️  /etc/apk/cache/ 里没有 luci-app-passwall apk"
ls -la /etc/apk/cache/25.12+_luci-i18n-passwall*.apk 2>/dev/null || echo "  ⚠️  /etc/apk/cache/ 里没有 i18n apk"

# 装
opkg update
opkg install luci-app-passwall
opkg install luci-i18n-passwall-zh-cn

echo "=== 启 passwall 服务 ==="
/etc/init.d/passwall enable 2>/dev/null || true
/etc/init.d/passwall restart 2>/dev/null || true

echo ""
echo "=== 验证 ==="
echo "  passwall 服务状态："
/etc/init.d/passwall status 2>&1 | head -5
echo ""
echo "  LuCI 入口：http://192.168.100.1/cgi-bin/luci/admin/services/passwall"
echo ""
echo "  🎉 装好了。配置节点订阅 / 单个节点 URL，点 Save & Apply。"
