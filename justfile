# awal-terminal build orchestration

set shell := ["zsh", "-cu"]

core_dir := "core"
app_dir := "app"

# Default: build everything
default: build

# Build the Rust core library (release)
build-core:
    cd {{core_dir}} && cargo build --release

# Build the Rust core library (debug)
build-core-debug:
    cd {{core_dir}} && cargo build

# Build the Swift app (requires core to be built first)
build-app: build-core
    cd {{app_dir}} && swift build -c release

# Build the Swift app (debug)
build-app-debug: build-core-debug
    cd {{app_dir}} && swift build

# Build everything
build: build-core build-app

# Build everything (debug)
build-debug: build-core-debug build-app-debug

# Run the app (debug build, launched from .app bundle for correct icon/notifications)
run: build-core-debug build-app-debug
    scripts/bundle.sh debug
    build/AwalTerminal.app/Contents/MacOS/AwalTerminal

# Run all tests
test: test-rust test-swift

# Run Rust tests
test-rust:
    cd {{core_dir}} && cargo test

# Run Swift tests
test-swift: build-core-debug
    cd {{app_dir}} && swift test

# Clean all build artifacts
clean:
    cd {{core_dir}} && cargo clean
    cd {{app_dir}} && swift package clean
    rm -rf build/

# Regenerate the C header
header:
    cd {{core_dir}} && cargo build

# Format code
fmt:
    cd {{core_dir}} && cargo fmt

# Lint
lint:
    cd {{core_dir}} && cargo clippy -- -W warnings

# Build the Rust core library for both architectures (universal)
build-core-universal:
    cd {{core_dir}} && cargo build --release --target aarch64-apple-darwin
    cd {{core_dir}} && cargo build --release --target x86_64-apple-darwin
    mkdir -p {{core_dir}}/target/universal-release
    lipo -create \
        {{core_dir}}/target/aarch64-apple-darwin/release/libawalterminal.a \
        {{core_dir}}/target/x86_64-apple-darwin/release/libawalterminal.a \
        -output {{core_dir}}/target/universal-release/libawalterminal.a

# Build the Swift app as universal binary
build-app-universal: build-core-universal
    cd {{app_dir}} && swift build -c release --arch arm64 --arch x86_64

# Package as .app bundle (release)
bundle: build
    scripts/bundle.sh

# Package as universal .app bundle
bundle-universal: build-app-universal
    scripts/bundle.sh universal

# Generate app icon from source PNG
generate-icon:
    swift scripts/generate-icon.swift

# Generate brand assets (logomark, banners, social cards, favicons)
generate-brand:
    swift scripts/generate-brand-assets.swift

# Serve the promotional website locally
serve-website:
    cd docs && python3 -m http.server 8000

# Show binary size info
size: build
    @ls -lh app/.build/arm64-apple-macosx/release/AwalTerminal | awk '{print "Binary: " $5}'

# Show universal binary size info
size-universal: build-app-universal
    @ls -lh app/.build/apple/Products/Release/AwalTerminal | awk '{print "Binary: " $5}'
    @lipo -info app/.build/apple/Products/Release/AwalTerminal
