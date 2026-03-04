#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE_DIR="${1:-$ROOT_DIR/app/Sources/App/Resources}"
ICONSET_DIR="$ROOT_DIR/app/Sources/App/Resources/AppIcon.iconset"
OUTPUT_ICNS="$ROOT_DIR/app/Sources/App/Resources/AppIcon.icns"
SOURCE_PNG="$SOURCE_DIR/AppIcon-source.png"

if [ ! -f "$SOURCE_PNG" ]; then
    echo "Error: Source PNG not found at $SOURCE_PNG"
    exit 1
fi

# Create iconset directory
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Generate all required sizes by resizing the 1024x1024 source
# iconset requires: 16, 32 (16@2x), 32, 64 (32@2x), 128, 256 (128@2x),
#                   256, 512 (256@2x), 512, 1024 (512@2x)
sizes=(16 32 128 256 512)
for size in "${sizes[@]}"; do
    retina=$((size * 2))
    sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    sips -z "$retina" "$retina" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

# Convert iconset to icns
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

# Clean up iconset directory
rm -rf "$ICONSET_DIR"

echo "Generated $OUTPUT_ICNS"
