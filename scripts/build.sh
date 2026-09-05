#!/usr/bin/env bash
# ImmortalWrt multi-device build script.
# Invoked from .github/workflows/build.yml on an ubuntu-22.04 runner.
#
# Required env (provided by the workflow matrix):
#   DEVICE          - device slug, e.g. r66s, redmi-ax6s, x86_64
#   IMMORTALWRT_BRANCH - upstream branch, e.g. master, openwrt-23.05
#
# Resolves the config file with this precedence:
#   files/<DEVICE>.config
#   files/.config                                  (single-device fallback)
set -euo pipefail

# ----- knobs (overridable via environment) ----------------------------------
IMMORTALWRT_REPO="${IMMORTALWRT_REPO:-https://github.com/immortalwrt/immortalwrt.git}"
IMMORTALWRT_BRANCH="${IMMORTALWRT_BRANCH:-master}"
DEVICE="${DEVICE:-r66s}"
JOBS="${JOBS:-$(nproc)}"

# ROOT_DIR: absolute path to the repo root (so we can find files/$DEVICE.config
# regardless of where the source tree is checked out).
ROOT_DIR="${ROOT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "$0")/.." && pwd)}"
WORKSPACE="${WORKSPACE:-$ROOT_DIR/_work}"
SRC_DIR="$WORKSPACE/immortalwrt"
LOG_DIR="$WORKSPACE/logs"
OUTPUT_DIR="$WORKSPACE/output"
# ----------------------------------------------------------------------------

mkdir -p "$WORKSPACE" "$LOG_DIR" "$OUTPUT_DIR"

log()  { printf '\033[1;34m[build:%s]\033[0m %s\n' "$DEVICE" "$*"; }
fail() { printf '\033[1;31m[build:%s]\033[0m %s\n' "$DEVICE" "$*" >&2; exit 1; }

log "device=$DEVICE branch=$IMMORTALWRT_BRANCH root=$ROOT_DIR"

# 1. system packages ---------------------------------------------------------
log "Installing build dependencies"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential ccache ecj fastjar file gawk gettext git \
  java-propose-classpath libelf-dev libncurses5-dev libncursesw5-dev \
  libssl-dev python3 python3-distutils python3-pyelftools qemu-utils \
  rsync subversion swig unzip wget xsltproc zlib1g-dev \
  qemu-user-static

# 2. fetch source ------------------------------------------------------------
if [[ -d "$SRC_DIR/.git" ]]; then
  log "Updating existing source tree"
  ( cd "$SRC_DIR" && git fetch --prune origin "$IMMORTALWRT_BRANCH" \
      && git reset --hard "origin/$IMMORTALWRT_BRANCH" )
else
  log "Cloning $IMMORTALWRT_REPO @ $IMMORTALWRT_BRANCH"
  git clone --depth=1 --branch "$IMMORTALWRT_BRANCH" "$IMMORTALWRT_REPO" "$SRC_DIR"
fi

cd "$SRC_DIR"

# 3. feeds -------------------------------------------------------------------
log "Updating & installing feeds"
./scripts/feeds update -a
./scripts/feeds install -a

# 4. user .config ------------------------------------------------------------
PICKED=""
for candidate in "$ROOT_DIR/files/$DEVICE.config" "$ROOT_DIR/files/.config"; do
  if [[ -f "$candidate" ]]; then
    PICKED="$candidate"
    break
  fi
done

if [[ -z "$PICKED" ]]; then
  fail "No config found. Expected one of:
        - $ROOT_DIR/files/$DEVICE.config
        - $ROOT_DIR/files/.config"
fi

log "Applying config: $PICKED"
cp "$PICKED" .config

# 5. sanity ------------------------------------------------------------------
log "Generating .config sanity"
make defconfig 2>&1 | tee -a "$LOG_DIR/${DEVICE}-defconfig.log"

# 6. download sources --------------------------------------------------------
log "Downloading all sources (cached after first run via actions/cache on dl/)"
make -j"$JOBS" download 2>&1 | tee -a "$LOG_DIR/${DEVICE}-download.log"
find dl -maxdepth 1 -type f -name '*.dl' -print -delete 2>/dev/null || true

# 7. compile -----------------------------------------------------------------
log "Building firmware (jobs=$JOBS)"
make -j"$JOBS" world 2>&1 | tee -a "$LOG_DIR/${DEVICE}-build.log"

# 8. stage artifacts ---------------------------------------------------------
if [[ ! -d bin/targets ]]; then
  fail "Build completed but bin/targets/ not found — check $LOG_DIR/${DEVICE}-build.log"
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

log "Build artifacts ready under $STAGE"
log "Contents:"
find "$STAGE" -maxdepth 4 -type f | sort | sed 's/^/  /'
