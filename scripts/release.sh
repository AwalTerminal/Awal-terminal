#!/bin/bash
# Create a new GitHub Release with the universal app bundle
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: scripts/release.sh <version>"
    echo "Example: scripts/release.sh v0.2.0"
    exit 1
fi

echo "==> Building universal release binary..."
cd "$ROOT/app"
swift build -c release --arch arm64 --arch x86_64
cd "$ROOT"

BINARY="$ROOT/app/.build/apple/Products/Release/AwalTerminal"
if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at $BINARY"
    exit 1
fi

echo "==> Bundling app..."
"$ROOT/scripts/bundle.sh" universal

APP_DIR="$ROOT/build/AwalTerminal.app"
if [ ! -d "$APP_DIR" ]; then
    echo "Error: App bundle not found at $APP_DIR"
    exit 1
fi

echo "==> Zipping app bundle..."
ZIP="$ROOT/docs/AwalTerminal.zip"
rm -f "$ZIP"
cd "$ROOT/build"
zip -r "$ZIP" AwalTerminal.app
cd "$ROOT"

echo ""
echo "Ready to release $VERSION"
echo "This will create a git tag and a GitHub Release."
read -p "Continue? [y/N] " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

echo "==> Creating git tag $VERSION..."
git tag "$VERSION"

echo "==> Creating GitHub Release..."
gh release create "$VERSION" "$ZIP" --title "$VERSION" --generate-notes

echo "==> Done! Released $VERSION"
