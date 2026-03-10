#!/bin/bash
# Generate AppIcon.icns from a 1024x1024 source PNG
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE_DIR="${1:-$ROOT_DIR/app/Sources/App/Resources}"
ICONSET_DIR="$ROOT_DIR/app/Sources/App/Resources/AppIcon.iconset"
OUTPUT_ICNS="$ROOT_DIR/app/Sources/App/Resources/AppIcon.icns"
SOURCE_PNG="$SOURCE_DIR/AppIcon-source.png"

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }

if [ ! -f "$SOURCE_PNG" ]; then
    red "Error: Source PNG not found at $SOURCE_PNG"
    exit 1
fi

# Verify source is at least 1024x1024
width=$(sips -g pixelWidth "$SOURCE_PNG" | awk '/pixelWidth/{print $2}')
height=$(sips -g pixelHeight "$SOURCE_PNG" | awk '/pixelHeight/{print $2}')
if [ "$width" -lt 1024 ] || [ "$height" -lt 1024 ]; then
    red "Error: Source image must be at least 1024x1024 (got ${width}x${height})"
    exit 1
fi

# Create iconset directory
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Generate all required sizes
sizes=(16 32 128 256 512)
for size in "${sizes[@]}"; do
    retina=$((size * 2))
    sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null 2>&1
    sips -z "$retina" "$retina" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null 2>&1
done

# Convert iconset to icns
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

# Clean up iconset directory
rm -rf "$ICONSET_DIR"

green "Generated $OUTPUT_ICNS"
