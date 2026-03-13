#!/bin/bash
# Test: App launches and shows a window, then quits cleanly
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo "Test: App Launch"

launch_app
assert_true "App is running" "app_is_running"
assert_true "At least 1 window" '[ "$(count_windows)" -ge 1 ]'

quit_app
sleep 1
assert_true "App quit cleanly" "! app_is_running"

echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed"
exit $FAIL_COUNT
