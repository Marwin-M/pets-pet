#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
iconset="$PWD/.build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/Artwork/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  pixels=$((size * 2))
  sips -z "$pixels" "$pixels" Resources/Artwork/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
sips -z 44 44 Resources/Artwork/MenuBarIcon.png --out Resources/MenuBarIcon.png >/dev/null
