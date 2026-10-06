#!/bin/bash
# Regenerate AppIcon.appiconset from logo/logo.png.
#
# Apple macOS icons expect the squircle to occupy ~824/1024 (80.5%) of the
# canvas with transparent margins. logo.png is artwork-only, so it is padded
# before the per-size rasters are produced.
#
# Usage: ./scripts/generate-appicon.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="logo/logo.png"
DST="NetworkManager/Assets.xcassets/AppIcon.appiconset"
CANVAS=1024
CONTENT=824

if [ ! -f "$SRC" ]; then
  echo "error: $SRC not found"
  exit 1
fi

mkdir -p "$DST"

# Master: artwork padded into Apple's icon canvas.
PAD_TMP="$(mktemp -d)/icon-1024.png"
swift scripts/pad-icon.swift "$SRC" "$PAD_TMP" "$CANVAS" "$CONTENT"

# Per-size rasters required by AppIcon.appiconset/Contents.json
rm -f "$DST"/*.png
for s in 16 32 128 256 512; do
  sips -s format png -z "$s" "$s" "$PAD_TMP" --out "$DST/icon_${s}x${s}.png" >/dev/null
done
sips -s format png -z 32   32   "$PAD_TMP" --out "$DST/icon_16x16@2x.png"   >/dev/null
sips -s format png -z 64   64   "$PAD_TMP" --out "$DST/icon_32x32@2x.png"   >/dev/null
sips -s format png -z 256  256  "$PAD_TMP" --out "$DST/icon_128x128@2x.png" >/dev/null
sips -s format png -z 512  512  "$PAD_TMP" --out "$DST/icon_256x256@2x.png" >/dev/null
sips -s format png -z 1024 1024 "$PAD_TMP" --out "$DST/icon_512x512@2x.png" >/dev/null

# Keep the padded master outside the appiconset so the asset catalog only
# sees files declared in Contents.json.
cp "$PAD_TMP" "logo/icon-1024-padded.png"
rm -rf "$(dirname "$PAD_TMP")"

echo "==> Generated 11 rasters in $DST"
ls -la "$DST"
