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
run: build-core-debug
    cd {{app_dir}} && swift build
    @bin_path=$(cd {{app_dir}} && swift build --show-bin-path) && \
        cp "$bin_path/AwalTerminal" build/AwalTerminal.app/Contents/MacOS/AwalTerminal && \
        codesign -f -s - build/AwalTerminal.app && \
        build/AwalTerminal.app/Contents/MacOS/AwalTerminal

# Run tests
test:
    cd {{core_dir}} && cargo test

# Clean all build artifacts
clean:
    cd {{core_dir}} && cargo clean
    cd {{app_dir}} && swift package clean

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
