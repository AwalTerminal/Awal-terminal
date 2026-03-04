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

# Run the app (debug build)
run: build-core-debug
    cd {{app_dir}} && swift build && swift run

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

# Generate app icon from source PNG
generate-icon:
    scripts/generate-icon.sh
