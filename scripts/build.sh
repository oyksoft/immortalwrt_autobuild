#!/usr/bin/env bash
# ImmortalWrt 多设备编译脚本。
# 由 .github/workflows/build.yml 在 ubuntu-22.04 runner 上调用。
#
# 必需环境变量（由 workflow matrix 传入）：
#   DEVICE             - 设备 slug，如 r66s, redmi-ax6s, x86_64
#   IMMORTALWRT_BRANCH - 上游分支，如 master, openwrt-23.05
#
# 配置文件查找顺序：
#   files/<DEVICE>.config
#   files/.config       （单设备 fallback）
set -euo pipefail

# ----- 可调参数（可通过环境变量覆盖） --------------------------------------
IMMORTALWRT_REPO="${IMMORTALWRT_REPO:-https://github.com/immortalwrt/immortalwrt.git}"
IMMORTALWRT_BRANCH="${IMMORTALWRT_BRANCH:-master}"
DEVICE="${DEVICE:-r66s}"
JOBS="${JOBS:-$(nproc)}"

# ROOT_DIR：仓库根目录的绝对路径（无论源码树检到哪里都能找到 files/$DEVICE.config）
ROOT_DIR="${ROOT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "$0")/.." && pwd)}"
WORKSPACE="${WORKSPACE:-$ROOT_DIR/_work}"
SRC_DIR="$WORKSPACE/immortalwrt"
LOG_DIR="$WORKSPACE/logs"
OUTPUT_DIR="$WORKSPACE/output"
# ----------------------------------------------------------------------------

mkdir -p "$WORKSPACE" "$LOG_DIR" "$OUTPUT_DIR"

log()  { printf '\033[1;34m[build:%s]\033[0m %s\n' "$DEVICE" "$*"; }
fail() { printf '\033[1;31m[build:%s]\033[0m %s\n' "$DEVICE" "$*" >&2; exit 1; }

log "设备=$DEVICE 分支=$IMMORTALWRT_BRANCH 工作区=$ROOT_DIR"

# 1. 安装编译依赖 ----------------------------------------------------------
log "安装编译依赖"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential ccache ecj fastjar file gawk gettext git \
  java-propose-classpath libelf-dev libncurses5-dev libncursesw5-dev \
  libssl-dev python3 python3-distutils python3-pyelftools qemu-utils \
  rsync subversion swig unzip wget xsltproc zlib1g-dev \
  qemu-user-static

# 2. 获取源码 --------------------------------------------------------------
# HiGarfield/cachewrtbuild 在 step 内部 restore 了 staging_dir/host 和
# staging_dir/tool-*/，这些是 toolchain 编译产物，必须保留。
# 但我们也要 fresh clone 源码树，所以流程：
#   1. 临时把 staging_dir 挪出 SRC_DIR
#   2. 删 SRC_DIR 整体（避免 git clone 报 "not empty"）
#   3. git clone fresh
#   4. 把 staging_dir 挪回 SRC_DIR/staging_dir
log "克隆 $IMMORTALWRT_REPO @ $IMMORTALWRT_BRANCH"
if [[ -d "$SRC_DIR/staging_dir" ]]; then
  mv "$SRC_DIR/staging_dir" "$WORKSPACE/.staging_dir.bak"
fi
rm -rf "$SRC_DIR"
git clone --depth=1 --branch "$IMMORTALWRT_BRANCH" "$IMMORTALWRT_REPO" "$SRC_DIR"
if [[ -d "$WORKSPACE/.staging_dir.bak" ]]; then
  mv "$WORKSPACE/.staging_dir.bak" "$SRC_DIR/staging_dir"
fi

cd "$SRC_DIR"

# 3. 更新 feeds ------------------------------------------------------------
log "更新并安装 feeds"
./scripts/feeds update -a
./scripts/feeds install -a

# 4. 应用 patches/ 下的补丁 ------------------------------------------------
if compgen -G "$ROOT_DIR/patches/*.patch" > /dev/null; then
  log "从 $ROOT_DIR/patches/ 应用补丁"
  for p in "$ROOT_DIR/patches/"*.patch; do
    log "  - $(basename "$p")"
    if ! patch -p1 --dry-run < "$p" >/dev/null 2>&1; then
      fail "补丁预检失败（上游可能改了上下文）：$p"
    fi
    patch -p1 < "$p" || fail "补丁应用失败：$p"
  done
fi

# 5. 应用用户 .config -------------------------------------------------------
PICKED=""
for candidate in "$ROOT_DIR/files/$DEVICE.config" "$ROOT_DIR/files/.config"; do
  if [[ -f "$candidate" ]]; then
    PICKED="$candidate"
    break
  fi
done

if [[ -z "$PICKED" ]]; then
  fail "未找到配置文件。请提供以下之一：
        - $ROOT_DIR/files/$DEVICE.config
        - $ROOT_DIR/files/.config"
fi

log "应用配置：$PICKED"
cp "$PICKED" .config

# 启用 ccache：让 OpenWrt build system 用 ccache 包裹 gcc/g++
# CCACHE_DIR 默认就是 ~/.ccache，显式声明以便与 build.yml 缓存路径对齐
export CCACHE_DIR="$HOME/.ccache"
mkdir -p "$CCACHE_DIR"
if ! grep -q '^CONFIG_CCACHE=y' .config; then
  echo 'CONFIG_CCACHE=y' >> .config
  log "已在 .config 中启用 CONFIG_CCACHE=y"
fi
# 限制 ccache 容量（默认 5GB，对 GitHub cache 配额太大，2GB 足够）
ccache -M 2G >/dev/null 2>&1 || true

# 6. 校验 .config ----------------------------------------------------------
log "执行 make defconfig 校验"
make defconfig 2>&1 | tee -a "$LOG_DIR/${DEVICE}-defconfig.log"

# 7. 下载所有源码 ----------------------------------------------------------
log "下载所有源码（首次后会由 actions/cache 缓存到 dl/）"
make -j"$JOBS" download 2>&1 | tee -a "$LOG_DIR/${DEVICE}-download.log"
find dl -maxdepth 1 -type f -name '*.dl' -print -delete 2>/dev/null || true

# 8. 编译 -----------------------------------------------------------------
log "编译固件（并行任务数=$JOBS）"
make -j"$JOBS" world 2>&1 | tee -a "$LOG_DIR/${DEVICE}-build.log"

# 9. 整理产物 --------------------------------------------------------------
if [[ ! -d bin/targets ]]; then
  fail "编译完成但未找到 bin/targets/，请检查 $LOG_DIR/${DEVICE}-build.log"
fi

STAGE="$OUTPUT_DIR/$DEVICE"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a bin/. "$STAGE/"

(
  cd "$STAGE"
  find . -type f \( \
      -name '*.img' -o -name '*.img.gz' -o -name '*.tar' \
      -o -name '*.manifest' -o -name '*.itb' -o -name '*.bin' \
      -o -name '*.squashfs' -o -name '*.kernel' \
      \) -print0 \
    | xargs -0 sha256sum > SHA256SUMS
)

log "固件产物已就绪：$STAGE"
log "产物列表："
find "$STAGE" -maxdepth 4 -type f | sort | sed 's/^/  /'

# 打印 ccache 命中率，方便跨 run 对比
log "ccache 统计："
ccache -s 2>&1 | sed 's/^/  /' | tee -a "$LOG_DIR/${DEVICE}-build.log"
