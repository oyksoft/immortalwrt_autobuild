#!/usr/bin/env bash
# 从完整 .config 抽取「已启用项」清单（用于快速 review）。
# 注意：这不是真正的 diffconfig（那需要跟默认配置逐项对比），
#       这里的输出仍包含大量默认值，体积约为完整 .config 的 1/10。
# 用法：./scripts/diffconfig.sh <.config 路径> [输出文件]
set -euo pipefail

CONFIG="${1:-files/r66s.config}"
OUTPUT="${2:-files/r66s.diffconfig}"

if [[ ! -f "$CONFIG" ]]; then
  echo "错误：$CONFIG 不存在" >&2
  exit 1
fi

awk '
  /^CONFIG_/ {
    if ($0 !~ /is not set/) {
      print $0
    }
  }
' "$CONFIG" | sort > "$OUTPUT"

echo "已写入 $OUTPUT，共 $(wc -l < "$OUTPUT") 行"
