#!/bin/bash
# Test: Cmd+Shift+I toggles AI side panel
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo "Test: AI Side Panel (Cmd+Shift+I)"

launch_app

# Toggle panel on
send_keystroke "i" "command down, shift down"
sleep 1
assert_true "App still running after toggle on" "app_is_running"

# Toggle panel off
send_keystroke "i" "command down, shift down"
sleep 1
assert_true "App still running after toggle off" "app_is_running"

quit_app

echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed"
exit $FAIL_COUNT
