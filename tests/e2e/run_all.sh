#!/bin/bash
# E2E smoke test runner — builds, bundles, and runs all E2E tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$PROJECT_ROOT"

echo "=== Building Rust core (debug) ==="
cd core && cargo build
cd "$PROJECT_ROOT"

echo "=== Building Swift app (debug) ==="
cd app && swift build
cd "$PROJECT_ROOT"

echo "=== Bundling .app ==="
scripts/bundle.sh

export APP_BUNDLE="$PROJECT_ROOT/build/AwalTerminal.app"

echo ""
echo "=== Running E2E Tests ==="
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0
TESTS_RUN=0

for test_script in "$SCRIPT_DIR"/test_*.sh; do
    ((TESTS_RUN++))
    echo "--- $(basename "$test_script") ---"
    if bash "$test_script"; then
        ((TOTAL_PASS++))
    else
        ((TOTAL_FAIL++))
    fi
    # Ensure app is quit between tests
    osascript -e 'tell application "Awal Terminal" to quit' 2>/dev/null || true
    sleep 1
    echo ""
done

echo "=== E2E Summary ==="
echo "  Scripts: $TESTS_RUN"
echo "  Passed: $TOTAL_PASS"
echo "  Failed: $TOTAL_FAIL"

if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
fi
