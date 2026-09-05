#!/usr/bin/env bash
# Extract a compact diffconfig from a full .config file.
# Usage: ./scripts/diffconfig.sh <path-to-.config> [output-file]
set -euo pipefail

CONFIG="${1:-files/.config}"
OUTPUT="${2:-files/diffconfig}"

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: $CONFIG not found" >&2
  exit 1
fi

# diffconfig keeps lines that differ from the default (i.e. CONFIG_FOO=y / # CONFIG_FOO is not set)
awk '
  /^CONFIG_/ {
    if ($0 !~ /is not set/) {
      print $0
    }
  }
' "$CONFIG" | sort > "$OUTPUT"

echo "Wrote $(wc -l < "$OUTPUT") lines to $OUTPUT"
