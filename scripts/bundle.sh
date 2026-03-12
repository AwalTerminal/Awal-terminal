#!/bin/bash
# Create AwalTerminal.app bundle from the release binary
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/AwalTerminal.app"
VERSION="${2:-}"

# --- Helpers ---------------------------------------------------------------
red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
info()  { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

die() { red "Error: $*" >&2; exit 1; }

# --- Resolve build directory -----------------------------------------------
if [ "${1:-}" = "universal" ]; then
    BUILD_DIR="$ROOT/app/.build/apple/Products/Release"
elif [ "${1:-}" = "debug" ]; then
    BUILD_DIR="$ROOT/app/.build/debug"
else
    BUILD_DIR="$ROOT/app/.build/arm64-apple-macosx/release"
    # Fallback to generic release path
    if [ ! -d "$BUILD_DIR" ]; then
        BUILD_DIR="$ROOT/app/.build/release"
    fi
fi

BINARY="$BUILD_DIR/AwalTerminal"
[ -f "$BINARY" ] || die "Binary not found at $BINARY. Run 'swift build' first."

# --- Derive version from tag if not provided --------------------------------
if [ -z "$VERSION" ]; then
    VERSION=$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")
fi
# Strip leading 'v' for plist (v1.2.0 -> 1.2.0)
PLIST_VERSION="${VERSION#v}"

# --- Build .app structure --------------------------------------------------
info "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/AwalTerminal"

# Copy SPM resource bundle (required at runtime)
RESOURCE_BUNDLE="$BUILD_DIR/AwalTerminal_AwalTerminal.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/MacOS/"
fi

# Copy icon if available
ICON="$ROOT/app/Sources/App/Resources/AppIcon.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# --- Write Info.plist with actual version -----------------------------------
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Awal Terminal</string>
    <key>CFBundleDisplayName</key>
    <string>Awal Terminal</string>
    <key>CFBundleIdentifier</key>
    <string>com.awal.terminal</string>
    <key>CFBundleVersion</key>
    <string>${PLIST_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${PLIST_VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>AwalTerminal</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Awal Terminal uses the microphone for voice input and dictation.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Awal Terminal uses speech recognition to transcribe voice input into terminal commands and text.</string>
</dict>
</plist>
PLIST

# --- Code sign --------------------------------------------------------------
info "Code signing..."
codesign --force --sign - "$APP_DIR"

green "Built: $APP_DIR (version $PLIST_VERSION)"
