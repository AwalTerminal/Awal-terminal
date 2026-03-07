#!/bin/bash
# Create AwalTerminal.app bundle from the release binary
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/build/AwalTerminal.app"

if [ "${1:-}" = "universal" ]; then
    BUILD_DIR="$ROOT/app/.build/apple/Products/Release"
else
    BUILD_DIR="$ROOT/app/.build/arm64-apple-macosx/release"
    # Fallback to generic release path
    if [ ! -d "$BUILD_DIR" ]; then
        BUILD_DIR="$ROOT/app/.build/release"
    fi
fi

BINARY="$BUILD_DIR/AwalTerminal"

if [ ! -f "$BINARY" ]; then
    echo "Error: Release binary not found. Run 'just build' first."
    exit 1
fi

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

# Write Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
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
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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

echo "Built: $APP_DIR"
