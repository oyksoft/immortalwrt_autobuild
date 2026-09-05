#!/usr/bin/env bash
# 从完整 .config 抽取紧凑版 diffconfig（仅保留与默认不同的选项）。
# 用法：./scripts/diffconfig.sh <.config 路径> [输出文件]
set -euo pipefail

CONFIG="${1:-files/.config}"
OUTPUT="${2:-files/diffconfig}"

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
