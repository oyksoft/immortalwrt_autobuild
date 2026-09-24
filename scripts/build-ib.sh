#!/usr/bin/env bash
# scripts/build-ib.sh
# 由 build.yml 调用。复杂 bash 在这里，workflow 文件保持简洁。
# 干：
# 1) 下 ImmortalWrt ImageBuilder
# 2) 解压
# 3) 加 openwrt-passwall feed 到 repositories.conf
# 4) 找 R66S profile
# 5) 从 files/r66s.config 提 PACKAGES（过滤 busybox variant/INCLUDE flag）
# 6) ./scripts/feeds update + install
# 7) make package_index
# 8) make image
# 9) 拷贝产物

set -euo pipefail

BRANCH="${BRANCH:-25.12.2}"
WORKSPACE="${WORKSPACE:-$GITHUB_WORKSPACE}"
TARGET_DIR="${TARGET_DIR:-out}"

cd "$WORKSPACE"

echo "=== [1/8] 下 IB ==="
IB_URL="https://downloads.immortalwrt.org/releases/${BRANCH}/targets/rockchip/armv8/immortalwrt-imagebuilder-${BRANCH}-rockchip-armv8.Linux-x86_64.tar.zst"
curl -fsSL "$IB_URL" -o ib.tar.zst
ls -la ib.tar.zst

echo "=== [2/8] 解压 ==="
mkdir -p ib-extracted
tar --use-compress-program=zstd -xf ib.tar.zst -C ib-extracted
IB_DIR=$(find ib-extracted -maxdepth 1 -type d -name 'immortalwrt-imagebuilder-*' | head -1)
[ -z "$IB_DIR" ] && { echo "❌ 找不到 IB 目录"; ls ib-extracted/; exit 1; }
echo "IB_DIR=$IB_DIR"

echo "=== [2.5/8] 改 IB tarball 的分区大小（用户 r66s.config 64+400）==="
# IB tarball 里内置 .config + image-partition 脚本。PTGEN 用 -p 16m -p 300m
# 写死，不读 CONFIG_TARGET_*_PARTSIZE（除非改内置文件）。
# 解 IB → sed 改 PART SIZE + PTGEN 参数 → 重打包。
if [ -f "$IB_DIR/.config" ]; then
  sed -i \
    -e 's/^CONFIG_TARGET_KERNEL_PARTSIZE=.*/CONFIG_TARGET_KERNEL_PARTSIZE=64/' \
    -e 's/^CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=400/' \
    "$IB_DIR/.config"
  echo "  ✓ 改 .config PART SIZE：kernel=64, rootfs=400"
fi
# 改所有用 ptgen 的脚本里的 -p 参数
ptgen_scripts=$(grep -rlE "ptgen.*-p [0-9]+m" "$IB_DIR" 2>/dev/null || true)
for s in $ptgen_scripts; do
  sed -i \
    -e 's/-p 16m/-p 64m/g' \
    -e 's/-p 300m/-p 400m/g' \
    "$s"
  echo "  ✓ 改 ptgen：$s"
done
# 重打包 IB tarball
cd "$(dirname "$IB_DIR")"
tar -cI 'zstd -19 -T0' -f /tmp/ib-modified.tar.zst "$(basename "$IB_DIR")" 2>/dev/null
cd - >/dev/null
mv /tmp/ib-modified.tar.zst ib.tar.zst
echo "  ✓ ib.tar.zst 已用新 PART SIZE 打包"

echo "=== [3/8] 加 passwall feed ==="
cat >> "$IB_DIR/repositories.conf" <<'EOF'
  src-git passwall_packages https://github.com/immortalwrt/openwrt-passwall-packages.git;main
  src-git passwall_luci https://github.com/immortalwrt/openwrt-passwall.git;main
EOF
echo "repositories.conf 末尾："
tail -3 "$IB_DIR/repositories.conf" | sed 's/^/  /'

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

echo "=== [5/8] 提 PACKAGES ==="
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

echo "=== [5.5/8] 下 luci-app-passwall apk 进 IB packages（用户 UI 用） ==="
mkdir -p "$IB_DIR/packages"
cd "$WORKSPACE"

# 自动查 GitHub API 最新 release，取 tag_name 和对应 25.12+ asset
RELEASE_JSON=$(curl -fsSL --max-time 30 \
  "https://api.github.com/repos/Openwrt-Passwall/openwrt-passwall/releases/latest" 2>/dev/null || true)
if [ -z "$RELEASE_JSON" ]; then
  echo "  ⚠️  查最新 release 失败，luci-app-passwall apk 不会下到 IB"
else
  TAG_NAME=$(echo "$RELEASE_JSON" | python -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null)
  LUCI_ASSET=$(echo "$RELEASE_JSON" | python -c "
import sys,json
r = json.load(sys.stdin)
for a in r.get('assets', []):
    n = a.get('name','')
    if n.startswith('25.12+_luci-app-passwall-') and not n.startswith('25.12+_luci-app-passwall2'):
        print(n); break
" 2>/dev/null)
  I18N_ASSET=$(echo "$RELEASE_JSON" | python -c "
import sys,json
r = json.load(sys.stdin)
for a in r.get('assets', []):
    n = a.get('name','')
    if n.startswith('25.12+_luci-i18n-passwall-zh-cn-'):
        print(n); break
" 2>/dev/null)

  echo "  最新 release：$TAG_NAME"

  if [ -n "$TAG_NAME" ] && [ -n "$LUCI_ASSET" ]; then
    LUCI_URL="https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${TAG_NAME}/${LUCI_ASSET}"
    # IB 找 apk 文件按 <Package>-<Version>.apk 名字，上游 release
    # 文件带 "25.12+_" 版本前缀要去掉
    LUCI_FNAME="${LUCI_ASSET#25.12+_}"
    if curl -fsSL --max-time 30 -o "$IB_DIR/packages/$LUCI_FNAME" "$LUCI_URL"; then
      echo "  ✓ $LUCI_FNAME (原名: $LUCI_ASSET)"
    else
      echo "  ⚠️  下 luci-app-passwall apk 失败"
    fi
  fi

  if [ -n "$TAG_NAME" ] && [ -n "$I18N_ASSET" ]; then
    I18N_URL="https://github.com/Openwrt-Passwall/openwrt-passwall/releases/download/${TAG_NAME}/${I18N_ASSET}"
    I18N_FNAME="${I18N_ASSET#25.12+_}"
    if curl -fsSL --max-time 30 -o "$IB_DIR/packages/$I18N_FNAME" "$I18N_URL"; then
      echo "  ✓ $I18N_FNAME (原名: $I18N_ASSET)"
    fi
  fi
fi

echo "=== [6/8] 跳过 feeds update（OpenWrt 25.12 IB 没 feeds.conf，不需要）==="
echo "  IB 里 feeds 相关文件（应为空）："
ls -la "$IB_DIR"/feeds* 2>&1 | sed 's/^/    /' || true
cd "$IB_DIR"
echo "  注：repositories.conf 里加的 passwall feed 这条路在 25.12 IB 里走不通"

echo "=== [7/8] make package_index ==="
make package_index 2>&1 | tail -10

echo "=== [8/8] make image ==="
cd "$WORKSPACE"  # 从 $IB_DIR 回到 workspace，packagelist.txt 在这
PACKAGES=$(tr '\n' ' ' < packagelist.txt)
# BIN_DIR 用绝对路径——避免 BIN_DIR=../out 相对 IB_DIR 跑到 ib-extracted/out
OUTPUT_DIR="$WORKSPACE/$TARGET_DIR"
mkdir -p "$OUTPUT_DIR"
cd "$IB_DIR"
# 硬编码分区大小：IB 不读 r66s.config 里的 CONFIG_TARGET_*_PARTSIZE。
# R66S 用户配 64+400，IB 默认 16+300，需要覆盖。
# - KERNELSIZE：kernel 分区大小（MB）
# - ROOTFSPARTSIZE：rootfs 分区大小（MB）
# - PARTSIZE：总分区大小（MB）；kernel + rootfs + 其它
# 2>&1 抓 stderr——apk 的 ERROR 在 stderr，不然看不到具体哪个包挂了
make image \
  PROFILE="$PROFILE" \
  PACKAGES="$PACKAGES" \
  KERNELSIZE=64 \
  ROOTFSPARTSIZE=400 \
  PARTSIZE=480 \
  BIN_DIR="$OUTPUT_DIR" \
  2>&1 | tee "$WORKSPACE/output.log"
echo "=== make image exit: ${PIPESTATUS[0]} ==="
cd "$WORKSPACE"

echo "=== 产物 ==="
ls -la "$OUTPUT_DIR/" 2>&1 | head -20