#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tools/.build/test_raycast_clipboard"
mkdir -p "$ROOT/tools/.build"

echo "Compiling Raycast clipboard bench…"
swiftc -O \
  -framework AppKit \
  -o "$OUT" \
  "$ROOT/Solv/RaycastTyper.swift" \
  "$ROOT/tools/RaycastClipboardBench.swift"

echo "Running…"
"$OUT"
