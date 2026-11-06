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

echo "=== [1/8] 下 ImageBuilder ==="
IB_URL="https://downloads.immortalwrt.org/releases/${BRANCH}/targets/rockchip/armv8/immortalwrt-imagebuilder-${BRANCH}-rockchip-armv8.Linux-x86_64.tar.zst"
curl -fsSL "$IB_URL" -o ib.tar.zst
ls -la ib.tar.zst

echo "=== [2/8] 解压 ImageBuilder ==="
mkdir -p ib-extracted
tar --use-compress-program=zstd -xf ib.tar.zst -C ib-extracted
IB_DIR=$(find ib-extracted -maxdepth 1 -type d -name 'immortalwrt-imagebuilder-*' | head -1)
[ -z "$IB_DIR" ] && { echo "❌ 找不到 IB 目录"; ls ib-extracted/; exit 1; }
echo "IB_DIR=$IB_DIR"

echo "=== [3/8] 改 IB 内置分区大小（kernel 64MB + rootfs 400MB）==="
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

echo "=== [4/8] 找 R66S profile ==="
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

echo "=== [5/8] 提取 PACKAGES 列表 ==="
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

echo "=== [6/8] 下 luci-app-passwall apk 进 IB packages（UI 用）==="
mkdir -p "$IB_DIR/packages"
cd "$WORKSPACE"

# 自动查 GitHub API 最新 release，取 tag_name 和对应 apk
# asset 文件名带 "<BRANCH>_" 前缀（如 25.12+_luci-app-passwall-xxx.apk）
RELEASE_JSON=$(curl -fsSL --max-time 30 \
  "https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall/releases/latest" 2>/dev/null || true)
if [ -z "$RELEASE_JSON" ]; then
  echo "  ⚠️  查最新 release 失败，luci-app-passwall apk 不会下到 IB"
else
  TAG_NAME=$(echo "$RELEASE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null)
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
" 2>/dev/null)
  I18N_ASSET=$(echo "$RELEASE_JSON" | python3 -c "
import sys,json
r = json.load(sys.stdin)
prefix = '$VER_PREFIX'
for a in r.get('assets', []):
    n = a.get('name','')
    if n.startswith(prefix + 'luci-i18n-passwall-zh-cn-'):
        print(n); break
" 2>/dev/null)

  echo "  最新 release：$TAG_NAME"
  echo "  版本前缀：$VER_PREFIX"

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
fi

echo "=== [7/8] make package_index ==="
cd "$IB_DIR"
make package_index 2>&1 | tail -10

echo "=== [8/8] make image ==="
cd "$WORKSPACE"  # packagelist.txt 在这
PACKAGES=$(tr '\n' ' ' < packagelist.txt)
# BIN_DIR 用绝对路径——避免相对路径跑到 ib-extracted/out
OUTPUT_DIR="$WORKSPACE/$TARGET_DIR"
mkdir -p "$OUTPUT_DIR"
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
