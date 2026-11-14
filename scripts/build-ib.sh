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
# IB 的 rootfs 是 apk 装包生成的（$(TARGET_DIR_ORIG) → $(TARGET_DIR) → 镜像），
# 源码编译路径用的 prepare_rootfs(..., $(TOPDIR)/files) 在 IB 里不会被调用，
# 所以文件必须直接进 rootfs 目录。
cd "$IB_DIR"

# 探测 IB 的 make 变量（make -pn 给的是未展开的定义，用 --eval 拿展开后的值）
VARS=$(make --eval='print-vars: ; @echo "V_BOARD=$(BOARD)"; echo "V_BUILD_DIR=$(BUILD_DIR)"; echo "V_TARGET_ROOTFS_DIR=$(TARGET_ROOTFS_DIR)"; echo "V_TARGET_DIR_ORIG=$(TARGET_DIR_ORIG)"; echo "V_TARGET_DIR=$(TARGET_DIR)"; echo "V_TOPDIR=$(TOPDIR)"' print-vars 2>/dev/null || true)
getvar() { echo "$VARS" | grep "^V_$1=" | head -1 | cut -d= -f2- || true; }
IB_TOPDIR=$(getvar TOPDIR)
BOARD=$(getvar BOARD)
TARGET_ROOTFS_DIR=$(getvar TARGET_ROOTFS_DIR)
TARGET_DIR_ORIG=$(getvar TARGET_DIR_ORIG)
IB_TARGET_DIR=$(getvar TARGET_DIR)   # 注意：不能叫 TARGET_DIR，脚本顶部已用该名表示输出目录
[ -n "$IB_TOPDIR" ] || IB_TOPDIR="$IB_DIR"
# 相对路径补全成绝对路径
case "$IB_TARGET_DIR" in /*) ;; *) IB_TARGET_DIR="$IB_DIR/$IB_TARGET_DIR" ;; esac
case "$TARGET_DIR_ORIG" in /*) ;; *) TARGET_DIR_ORIG="$IB_DIR/$TARGET_DIR_ORIG" ;; esac
echo "  TOPDIR=$IB_TOPDIR"
echo "  BOARD=$BOARD"
echo "  IB_TARGET_DIR=$IB_TARGET_DIR"
echo "  TARGET_DIR_ORIG=$TARGET_DIR_ORIG"

# 顺手把 IB 的相关 Makefile 片段打出来，方便排查
echo "  --- include/image.mk 里 prepare_rootfs / BuildImage ---"
grep -n -B3 -A6 "prepare_rootfs" "$IB_DIR/include/image.mk" 2>/dev/null | head -30 | sed 's/^/    /' || true
grep -n -B2 -A6 "BuildImage" "$IB_DIR/include/image.mk" 2>/dev/null | head -25 | sed 's/^/    /' || true
echo "  --- include/rootfs.mk 里的 prepare_rootfs ---"
grep -n -B2 -A10 "define prepare_rootfs" "$IB_DIR/include/rootfs.mk" 2>/dev/null | head -20 | sed 's/^/    /' || true
echo "  --- rules.mk 里的 target ---"
grep -nE "^[a-zA-Z_.-]+:" "$IB_DIR/rules.mk" 2>/dev/null | head -20 | sed 's/^/    /' || true

# 方案 A：IB 根目录 files/（万一某些版本会用到，先放上）
mkdir -p "$IB_TOPDIR/files"
cp -a "$WORKSPACE/files/rootfs/." "$IB_TOPDIR/files/" 2>/dev/null || true
chmod +x "$IB_TOPDIR/files/etc/init.d/bbr" 2>/dev/null || true

cd "$WORKSPACE"
echo "  注入文件清单："
find "$WORKSPACE/files/rootfs" -type f | sed "s|$WORKSPACE/files/rootfs/|    |"

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

# === 把自定义文件做成 apk 包，放进 IB 的 packages/ 目录 ===
# IB 会把 packages/ 里的本地包跟官方包一起 apk install 进 rootfs，
# 这是 OpenWrt ImageBuilder 官方支持的“注入自定义文件”方式。
echo "=== [7.5/9] 打包自定义文件为本地 apk（BBR 加速 UI 等）==="
PKG_NAME="luci-app-bbr"
PKG_VER="1.0.0"
PKG_STAGE="$WORKSPACE/.pkgstage/$PKG_NAME"
rm -rf "$PKG_STAGE"
mkdir -p "$PKG_STAGE"
cp -a "$WORKSPACE/files/rootfs/." "$PKG_STAGE/"
chmod +x "$PKG_STAGE/etc/init.d/bbr" 2>/dev/null || true
cat > "$PKG_STAGE/.PKGINFO" <<EOF
pkgname = $PKG_NAME
pkgver = $PKG_VER
pkgdesc = BBR 加速 LuCI 页面（自定义）
arch = all
size = $(du -sk "$PKG_STAGE" | cut -f1)
EOF
mkdir -p "$IB_DIR/packages"
tar -czf "$IB_DIR/packages/${PKG_NAME}-${PKG_VER}.apk" -C "$PKG_STAGE" .
echo "  ✓ 已生成 ${PKG_NAME}-${PKG_VER}.apk"
tar -tzf "$IB_DIR/packages/${PKG_NAME}-${PKG_VER}.apk" | sed 's/^/    /'

# 加进安装列表（apk add 才会装它）
echo "$PKG_NAME" >> packagelist.txt
echo "  ✓ 已加入安装列表（包总数：$(wc -l < packagelist.txt)）"

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
  # 写到文件供 release step 用
  echo "$TAG_NAME" > "$WORKSPACE/passwall_version.txt"

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

echo "=== [8/9] make package_index ==="
cd "$IB_DIR"
make package_index 2>&1 | tail -10

echo "=== [9/9] make image ==="
cd "$WORKSPACE"  # packagelist.txt 在这
PACKAGES=$(tr '\n' ' ' < packagelist.txt)
# BIN_DIR 用绝对路径——避免相对路径跑到 ib-extracted/out
OUTPUT_DIR="$WORKSPACE/$TARGET_DIR"
mkdir -p "$OUTPUT_DIR"

# 方案 B：先 make install 生成 rootfs 目录，把自定义文件放进去，
#         再 make image 打包（apk add 不会删除额外的文件）
cd "$IB_DIR"
echo "  --- 第一遍 make image（只为生成 rootfs 目录）---"
FIRST_OUT="$WORKSPACE/out-firstpass"
mkdir -p "$FIRST_OUT"
if make image PROFILE="$PROFILE" PACKAGES="$PACKAGES" \
     KERNELSIZE=64 ROOTFSPARTSIZE=400 PARTSIZE=480 BIN_DIR="$FIRST_OUT" \
     > "$WORKSPACE/image-firstpass.log" 2>&1; then
  echo "  ✓ 第一遍完成"
else
  echo "  ⚠️  第一遍失败（不影响后续）："
  tail -8 "$WORKSPACE/image-firstpass.log" | sed 's/^/    /'
fi
cd "$WORKSPACE"

# 注入自定义文件到 rootfs 目录
if [ -n "${IB_TARGET_DIR:-}" ] && [ -d "$IB_TARGET_DIR" ]; then
  cp -a "$WORKSPACE/files/rootfs/." "$IB_TARGET_DIR/"
  chmod +x "$IB_TARGET_DIR/etc/init.d/bbr" 2>/dev/null || true
  echo "  ✓ 已注入到 $IB_TARGET_DIR"
  find "$IB_TARGET_DIR" \( -name 'bbr' -o -name 'bbr.lua' \) 2>/dev/null | head -5 | sed 's/^/    /'
else
  echo "  ⚠️  rootfs 目录不存在：$IB_TARGET_DIR"
fi

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
  # 第二遍 make image 后，rootfs 目录里的文件是否还在
  if [ -f "$IB_TARGET_DIR/etc/config/bbr" ]; then
    echo "  · rootfs 目录里文件仍在：$IB_TARGET_DIR/etc/config/bbr"
  else
    echo "  ⚠️  rootfs 目录里文件已消失（make image 重建了目录）"
  fi

  # squashfs 是压缩的，strings 搜不到——必须用 unsquashfs 列目录
  FOUND=0
  if [ -x "$UNSQUASH" ]; then
    zcat "$IMG_CHECK" > /tmp/bbr-check.squashfs 2>/dev/null || true
    if "$UNSQUASH" -l /tmp/bbr-check.squashfs 2>/dev/null | grep -qE "etc/config/bbr|luci/controller/bbr\.lua|luci/model/cbi/bbr\.lua"; then
      FOUND=1
      echo "  ✓ 镜像内含："
      "$UNSQUASH" -l /tmp/bbr-check.squashfs 2>/dev/null | grep -E "bbr" | sed 's/^/      /'
    fi
  else
    echo "  ⚠️  没有 unsquashfs（$UNSQUASH）"
  fi

  if [ "$FOUND" = "1" ]; then
    echo "  ✓ 自检通过：BBR 页面已包含在固件中"
  else
    echo "  ❌ 自检失败：自定义文件没进固件（注入机制需重新排查）"
  fi
fi
