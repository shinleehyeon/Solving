#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/tools/.build/test_option_ocr"
mkdir -p "$ROOT/tools/.build"

echo "Compiling OCR bench…"
swiftc -O \
  -framework AppKit -framework Vision \
  -o "$OUT" \
  "$ROOT/Solv/OptionOCRLocator.swift" \
  "$ROOT/tools/NSImage+PixelSize.swift" \
  "$ROOT/tools/OCRBenchMain.swift"

echo "Running…"
"$OUT"
