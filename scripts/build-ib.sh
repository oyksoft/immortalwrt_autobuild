#!/usr/bin/env bash
# scripts/build-ib.sh
# 由 build.yml 调用。复杂 bash 在这里，workflow 文件保持简洁。
# 干：
# 1) 下 ImmortalWrt ImageBuilder
# 2) 解压
# 3) 改 IB 内置分区大小（kernel 64MB + rootfs 400MB）
# 4) 找 R66S profile
# 5) 从 files/r66s.config 提取 PACKAGES（过滤 busybox variant/INCLUDE flag）
# 6) 下 luci-app-passwall + i18n apk 进 IB packages（UI 用）
# 7) make package_index
# 8) make image

set -euo pipefail

BRANCH="${BRANCH:-25.12.2}"
WORKSPACE="${WORKSPACE:-$GITHUB_WORKSPACE}"
TARGET_DIR="${TARGET_DIR:-out}"

cd "$WORKSPACE"

echo "=== [1/9] 下 ImageBuilder ==="
IB_URL="https://downloads.immortalwrt.org/releases/${BRANCH}/targets/rockchip/armv8/immortalwrt-imagebuilder-${BRANCH}-rockchip-armv8.Linux-x86_64.tar.zst"
curl -fsSL "$IB_URL" -o ib.tar.zst
ls -la ib.tar.zst

echo "=== [2/9] 解压 ImageBuilder ==="
mkdir -p ib-extracted
tar --use-compress-program=zstd -xf ib.tar.zst -C ib-extracted
IB_DIR=$(find ib-extracted -maxdepth 1 -type d -name 'immortalwrt-imagebuilder-*' | head -1)
[ -z "$IB_DIR" ] && { echo "❌ 找不到 IB 目录"; ls ib-extracted/; exit 1; }
# 转成绝对路径——后面要 cd 进去再引用
IB_DIR="$WORKSPACE/$IB_DIR"
echo "IB_DIR=$IB_DIR"

echo "=== [3/9] 改 IB 内置分区大小（kernel 64MB + rootfs 400MB）==="
# IB 默认用 ptgen -p 16m -p 300m 写死，不读 CONFIG_TARGET_*_PARTSIZE。
# 直接改解压后的目录就行——make image 读的是这个目录，不是 tarball。
if [ -f "$IB_DIR/.config" ]; then
  sed -i \
    -e 's/^CONFIG_TARGET_KERNEL_PARTSIZE=.*/CONFIG_TARGET_KERNEL_PARTSIZE=64/' \
    -e 's/^CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=400/' \
    "$IB_DIR/.config"
  echo "  ✓ .config 分区大小：kernel=64, rootfs=400"
fi
# 改所有用 ptgen 的脚本里的 -p 参数
ptgen_scripts=$(grep -rlE "ptgen.*-p [0-9]+m" "$IB_DIR" 2>/dev/null || true)
for s in $ptgen_scripts; do
  sed -i \
    -e 's/-p 16m/-p 64m/g' \
    -e 's/-p 300m/-p 400m/g' \
    "$s"
  echo "  ✓ ptgen 参数：$s"
done

echo "=== [4/9] 注入自定义文件（BBR 加速 UI 等）==="
# IB Makefile 里的 prepare_rootfs target 会执行：
#     $(call prepare_rootfs,$(TARGET_DIR),$(USER_FILES),$(DISABLED_SERVICES))
# 第二个参数就是 USER_FILES，其目录内容会被拷进 rootfs。
# 所以只要 make image 时传 USER_FILES=<目录> 即可（官方机制）。
#
# 注：IB 里没有源码编译版的 $(TOPDIR)/files 机制，也没有 install target；
#     make image 会重建 rootfs 目录，事后拷文件无效。
if [ -d "$WORKSPACE/files/rootfs" ]; then
  echo "  ✓ USER_FILES=$WORKSPACE/files/rootfs"
  find "$WORKSPACE/files/rootfs" -type f | sed "s|$WORKSPACE/files/rootfs/|    |"
else
  echo "  ⚠️  files/rootfs 不存在，固件将不含自定义文件"
fi

echo "=== [5/9] 找 R66S profile ==="
if [ -n "${USER_PROFILE:-}" ]; then
  PROFILE="$USER_PROFILE"
else
  PROFILE=$(grep -rhoE 'Device/lunzn_fastrhino[a-zA-Z0-9_-]+' "$IB_DIR/target/linux/rockchip/" 2>/dev/null | head -1 | sed 's|^Device/||')
  if [ -z "$PROFILE" ]; then
    echo "❌ 找不到 lunzn_fastrhino-* profile"
    grep -rhoE 'Device/[a-zA-Z0-9_-]+' "$IB_DIR/target/linux/rockchip/" 2>/dev/null | sort -u | head -10
    exit 1
  fi
fi
echo "PROFILE=$PROFILE"

echo "=== [6/9] 提取 PACKAGES 列表 ==="
grep -E '^CONFIG_PACKAGE_' files/r66s.config | \
  sed 's/^CONFIG_PACKAGE_//; s/=y$//' | \
  # 不是真包（busybox variant/INCLUDE flag/dnsmasq full 子项/luci variant）
  grep -vE '_INCLUDE_|^TAR_|^dnsmasq_full_|^knot-resolver_dnstap$|^luci-lib-nixio_openssl$|^apk-openssl$' | \
  # passwall 核心包（Lua 脚本）IB 没预编。用户刷机后后台手动装。
  grep -vE '^passwall$' | \
  # trusted-firmware + u-boot：IB 没自动下，build 不带。
  # 刷机后用户从官方 R66S 固件 dd 出或手动 git clone 填。
  grep -vE '^(trusted-firmware-a-rk3568|u-boot-fastrhino-r66s-rk3568)$' | \
  sort -u > packagelist.txt
echo "包数量：$(wc -l < packagelist.txt)"

echo "=== [7/9] 下 luci-app-passwall apk 进 IB packages（UI 用）==="
mkdir -p "$IB_DIR/packages"
cd "$WORKSPACE"


# 自动查 GitHub API 最新 release，取 tag_name 和对应 apk
# asset 文件名带 "<BRANCH>_" 前缀（如 25.12+_luci-app-passwall-xxx.apk）
#
# 限流问题：匿名调 api.github.com 只有 60 次/小时/IP，Actions runner 共享出口 IP，
# 连续构建很容易被限流（表现为“查最新 release 失败” + 固件装上旧版 passwall）。
# 对策：
#   1. 带 GITHUB_TOKEN（Actions 自动提供），限额 5000/小时
#   2. 失败重试 3 次
#   3. 还失败就用 git ls-remote 取版本号（不走 API，无限额），并按规则尝试构造 asset 名
API_URL="https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall/releases/latest"
RELEASE_JSON=""
for try in 1 2 3; do
  RELEASE_JSON=$(curl -fsSL --max-time 30 \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    "$API_URL" 2>/dev/null || true)
  if [ -n "$RELEASE_JSON" ]; then
    break
  fi
  echo "  · GitHub API 第 $try 次失败（可能是限流），重试..."
  sleep 5
done

if [ -z "$RELEASE_JSON" ]; then
  echo "  ⚠️  GitHub API 不可用，改用 git ls-remote 取版本号"
  TAG_NAME=$(git ls-remote --tags --refs https://github.com/Openwrt-Passwall/openwrt-passwall 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/tags/||' | sort -V | tail -1)
  [ -n "$TAG_NAME" ] && echo "  · 最新 tag：$TAG_NAME"
else
  TAG_NAME=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null || true)
fi

if [ -z "${TAG_NAME:-}" ]; then
  echo "  ❌ 取不到 passwall 版本号，luci-app-passwall apk 不会下到 IB（将用官方源自带版本）"
else
  # asset 名前缀用 minor 版本（25.12.2 → 25.12+_），upstream 不带 patch 号
  VER_PREFIX="${BRANCH%.*}+_"
  LUCI_ASSET=$(echo "$RELEASE_JSON" | python3 -c "
import sys,json
r = json.load(sys.stdin)
prefix = '$VER_PREFIX'
for a in r.get('assets', []):
    n = a.get('name','')
    if n.startswith(prefix + 'luci-app-passwall-') and not n.startswith(prefix + 'luci-app-passwall2'):
        print(n); break
" 2>/dev/null || true)
  I18N_ASSET=$(echo "$RELEASE_JSON" | python3 -c "
import sys,json
r = json.load(sys.stdin)
prefix = '$VER_PREFIX'
for a in r.get('assets', []):
    n = a.get('name','')
    if n.startswith(prefix + 'luci-i18n-passwall-zh-cn-'):
        print(n); break
" 2>/dev/null || true)

  echo "  最新 release：$TAG_NAME"
  echo "  版本前缀：$VER_PREFIX"
  # 写到文件供 release step 用
  echo "$TAG_NAME" > "$WORKSPACE/passwall_version.txt"

  # API 不可用时，按已知规则尝试构造 asset 名（tag 26.11.11-1 → apk 26.11.11-r1）
  if [ -z "$LUCI_ASSET" ]; then
    VER="${TAG_NAME%%-*}"
    for cand in "${VER_PREFIX}luci-app-passwall-${VER}-r1.apk" \
                "${VER_PREFIX}luci-app-passwall-${VER}.apk"; do
      if curl -fsSL --max-time 30 -o /dev/null "https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${TAG_NAME}/${cand}"; then
        LUCI_ASSET="$cand"
        break
      fi
    done
    [ -n "$LUCI_ASSET" ] && echo "  · 兜底匹配到 asset：$LUCI_ASSET"
  fi
  if [ -z "$I18N_ASSET" ]; then
    VER="${TAG_NAME%%-*}"
    for cand in "${VER_PREFIX}luci-i18n-passwall-zh-cn-${VER}.apk" \
                "${VER_PREFIX}luci-i18n-passwall-zh-cn-${VER}-r1.apk"; do
      if curl -fsSL --max-time 30 -o /dev/null "https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${TAG_NAME}/${cand}"; then
        I18N_ASSET="$cand"
        break
      fi
    done
    [ -n "$I18N_ASSET" ] && echo "  · 兜底匹配到 asset：$I18N_ASSET"
  fi

  if [ -n "$TAG_NAME" ] && [ -n "$LUCI_ASSET" ]; then
    LUCI_URL="https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${TAG_NAME}/${LUCI_ASSET}"
    # IB 按 <Package>-<Version>.apk 找，去掉 "25.12+_" 前缀
    LUCI_FNAME="${LUCI_ASSET#${VER_PREFIX}}"
    if curl -fsSL --max-time 30 -o "$IB_DIR/packages/$LUCI_FNAME" "$LUCI_URL"; then
      echo "  ✓ $LUCI_FNAME（原名: $LUCI_ASSET）"
    else
      echo "  ⚠️  下 luci-app-passwall apk 失败"
    fi
  fi

  if [ -n "$TAG_NAME" ] && [ -n "$I18N_ASSET" ]; then
    I18N_URL="https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${TAG_NAME}/${I18N_ASSET}"
    I18N_FNAME="${I18N_ASSET#${VER_PREFIX}}"
    if curl -fsSL --max-time 30 -o "$IB_DIR/packages/$I18N_FNAME" "$I18N_URL"; then
      echo "  ✓ $I18N_FNAME（原名: $I18N_ASSET）"
    fi
  fi

  # 本地包已就位 → 把安装列表里的同名条目换成「包名=版本」形式，
  # 让 apk 精确选我们下载的本地包。
  #
  # 为什么要加版本约束：
  #   官方源的 luci-app-passwall 版本号是 luci 的 commit 号（如 26.309.25225），
  #   语义上比 upstream 的发布号（如 26.11.11）大，不加约束 apk 会优先选官方源的。
  #
  # 不能简单从列表里移除：
  #   IB 只安装 PACKAGES 列表里的包，packages/ 目录里的本地包并不会被自动安装
  #   （移除 = 根本不装这个包）。
  if [ -n "$LUCI_ASSET" ] && [ -f "$IB_DIR/packages/${LUCI_ASSET#${VER_PREFIX}}" ]; then
    LUCI_FNAME="${LUCI_ASSET#${VER_PREFIX}}"
    LUCI_VER=$(echo "$LUCI_FNAME" | sed 's/^luci-app-passwall-//; s/\.apk$//')
    grep -v '^luci-app-passwall$' packagelist.txt > packagelist.tmp
    echo "luci-app-passwall=$LUCI_VER" >> packagelist.tmp
    mv packagelist.tmp packagelist.txt
    echo "  ✓ 安装列表改为 luci-app-passwall=$LUCI_VER（强制用本地包）"
  fi
  if [ -n "$I18N_ASSET" ] && [ -f "$IB_DIR/packages/${I18N_ASSET#${VER_PREFIX}}" ]; then
    I18N_FNAME="${I18N_ASSET#${VER_PREFIX}}"
    I18N_VER=$(echo "$I18N_FNAME" | sed 's/^luci-i18n-passwall-zh-cn-//; s/\.apk$//')
    grep -v '^luci-i18n-passwall-zh-cn$' packagelist.txt > packagelist.tmp
    echo "luci-i18n-passwall-zh-cn=$I18N_VER" >> packagelist.tmp
    mv packagelist.tmp packagelist.tmp2
    mv packagelist.tmp2 packagelist.txt
    echo "  ✓ 安装列表改为 luci-i18n-passwall-zh-cn=$I18N_VER（强制用本地包）"
  fi
fi

echo "=== [8/9] make package_index ==="
cd "$IB_DIR"
make package_index 2>&1 | tail -10

echo "=== [9/9] make image ==="
cd "$WORKSPACE"  # packagelist.txt 在这
PACKAGES=$(tr '\n' ' ' < packagelist.txt)
# BIN_DIR 用绝对路径——避免相对路径跑到 ib-extracted/out
OUTPUT_DIR="$WORKSPACE/$TARGET_DIR"
mkdir -p "$OUTPUT_DIR"

# USER_FILES：IB 官方机制，prepare_rootfs 会把它拷进 rootfs
# （IB Makefile: $(call prepare_rootfs,$(TARGET_DIR),$(USER_FILES),$(DISABLED_SERVICES))）
cd "$IB_DIR"
# 硬编码分区大小：IB 不读 r66s.config 里的 CONFIG_TARGET_*_PARTSIZE。
# - KERNELSIZE：kernel 分区（MB）
# - ROOTFSPARTSIZE：rootfs 分区（MB）
# - PARTSIZE：总分区（MB）= kernel + rootfs + 其它
# 2>&1 抓 stderr——apk 的 ERROR 在 stderr，不然看不到具体哪个包挂了
set -o pipefail
make image \
  PROFILE="$PROFILE" \
  PACKAGES="$PACKAGES" \
  USER_FILES="$WORKSPACE/files/rootfs" \
  KERNELSIZE=64 \
  ROOTFSPARTSIZE=400 \
  PARTSIZE=480 \
  BIN_DIR="$OUTPUT_DIR" \
  2>&1 | tee "$WORKSPACE/output.log"
MAKE_EXIT=${PIPESTATUS[0]}
cd "$WORKSPACE"
if [ "$MAKE_EXIT" -ne 0 ]; then
  echo "❌ make image 失败，exit=$MAKE_EXIT"
  exit "$MAKE_EXIT"
fi

echo "=== 产物 ==="
ls -la "$OUTPUT_DIR/" 2>&1 | head -20

# 自检：确认自定义文件真的进了固件（注入失败时能第一时间发现）
echo "=== 自检：自定义文件是否进固件 ==="
IMG_CHECK=$(ls "$OUTPUT_DIR"/*squashfs-sysupgrade.img.gz 2>/dev/null | head -1)
UNSQUASH=""
for u in "$IB_DIR/staging_dir/host/bin/unsquashfs" "$(command -v unsquashfs 2>/dev/null)"; do
  if [ -n "$u" ] && [ -x "$u" ]; then UNSQUASH="$u"; break; fi
done
if [ -z "$IMG_CHECK" ]; then
  echo "  ⚠️  找不到 sysupgrade 镜像，跳过自检"
else
  # squashfs 是压缩的，strings 搜不到——必须用 unsquashfs 列目录
  FOUND=0
  if [ -n "$UNSQUASH" ]; then
    zcat "$IMG_CHECK" > /tmp/bbr-check.img 2>/dev/null || true
    # sysupgrade.img 是带 u-boot 头/分区的镜像，squashfs 不在偏移 0，
    # 用 magic 'hsqs' 定位真正位置
    OFF=$(grep -abo 'hsqs' /tmp/bbr-check.img 2>/dev/null | head -1 | cut -d: -f1)
    echo "  · squashfs magic 偏移：${OFF:-未找到}"
    if [ -n "$OFF" ]; then
      tail -c +$((OFF + 1)) /tmp/bbr-check.img > /tmp/bbr-root.squashfs 2>/dev/null || true
      echo "  --- 镜像内的 bbr 相关文件 ---"
      "$UNSQUASH" -l /tmp/bbr-root.squashfs 2>/dev/null | grep -iE "bbr" | sed 's/^/      /' || true
      # LAN IP 机制调查：固件里到底有没有 /etc/config/network、/etc/board.json
      echo "  --- 镜像内的网络相关文件 ---"
      "$UNSQUASH" -l /tmp/bbr-root.squashfs 2>/dev/null | grep -E "etc/config/network$|etc/board.json|etc/board.d/" | sed 's/^/      /' || true
      echo "  --- /etc/board.json 内容 ---"
      "$UNSQUASH" -cat /tmp/bbr-root.squashfs etc/board.json 2>/dev/null | head -40 | sed 's/^/      /' || true
      echo "  --- /etc/config/network 内容 ---"
      "$UNSQUASH" -cat /tmp/bbr-root.squashfs etc/config/network 2>/dev/null | head -30 | sed 's/^/      /' || true
      if "$UNSQUASH" -l /tmp/bbr-root.squashfs 2>/dev/null | grep -qE "etc/config/bbr|luci/controller/bbr\.lua|luci/model/cbi/bbr\.lua|board\.d/03_lan-ip"; then
        FOUND=1
        echo "  ✓ 镜像内含 BBR 页面文件"
      fi
    fi
  else
    echo "  ⚠️  找不到 unsquashfs"
  fi

  if [ "$FOUND" = "1" ]; then
    echo "  ✓ 自检通过：BBR 页面已包含在固件中"
  else
    echo "  ❌ 自检失败：自定义文件没进固件（注入机制需重新排查）"
  fi
fi
