#!/bin/sh
# 在 R66S 上跑：把 BBR 加速的 LuCI 页面 + init 脚本装到系统里
#
# 用途：
#   1. 排查固件注入是否生效（如果这个脚本能装上但固件里没有，
#      说明是 build 流程的问题，不是功能本身的问题）
#   2. 临时手动装一份，不等下次 build
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/oyksoft/immortalwrt_autobuild/main/scripts/install-bbr-ui.sh | sh

set -e

REPO="https://github.com/oyksoft/immortalwrt_autobuild"
REF="main"
TMP="/tmp/bbr-ui"

echo "=== [1/4] 下载仓库源码 ==="
rm -rf "$TMP"
mkdir -p "$TMP"
cd "$TMP"
if ! curl -fsSL --max-time 120 -o src.tar.gz "$REPO/archive/refs/heads/$REF.tar.gz"; then
	echo "❌ 下载失败，检查网络"
	exit 1
fi
tar -xzf src.tar.gz
SRC=$(find . -maxdepth 1 -type d -name 'immortalwrt_autobuild-*' | head -1)
[ -z "$SRC" ] && { echo "❌ 解压异常"; exit 1; }
echo "  ✓ 源码目录：$SRC"

echo "=== [2/4] 拷贝文件到系统 ==="
[ -f "$SRC/files/rootfs/etc/config/bbr" ] || { echo "❌ 源文件缺失"; exit 1; }
cp -a "$SRC/files/rootfs/." /
chmod +x /etc/init.d/bbr
echo "  ✓ 已安装："
ls -l /etc/config/bbr /etc/init.d/bbr \
	/usr/share/luci/menu.d/luci-app-bbr.json \
	/usr/lib/lua/luci/controller/bbr.lua \
	/usr/lib/lua/luci/model/cbi/bbr.lua 2>&1 | sed 's/^/    /'

echo "=== [3/4] 应用 BBR 配置 ==="
/etc/init.d/bbr start
echo "  当前拥塞控制算法：$(cat /proc/sys/net/ipv4/tcp_congestion_control)"
echo "  当前队列调度：      $(cat /proc/sys/net/core/default_qdisc)"
echo "  内核可用算法：      $(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"

echo "=== [4/4] 清理 LuCI 菜单缓存 ==="
rm -f /tmp/luci-indexcache* 2>/dev/null || true
echo "  ✓ 已清理（如果菜单没出现，重启一次 LuCI 再看）"

echo ""
echo "🎉 装好了。刷新 LuCI 页面，应该能在「网络」菜单下看到「BBR 加速」。"
echo "   如果没有，强制刷新浏览器（Ctrl+F5）再试。"
