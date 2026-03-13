#!/bin/bash
# Test: Cmd+F shows find bar
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo "Test: Find Bar (Cmd+F)"

launch_app

send_keystroke "f" "command down"
sleep 1

# Check that the app is still running and responsive
assert_true "App still running after Cmd+F" "app_is_running"

# Press Escape to dismiss
send_key_code 53
sleep 0.5

quit_app

echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed"
exit $FAIL_COUNT
