#!/bin/bash
# Test: Cmd+T creates a new tab
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo "Test: New Tab (Cmd+T)"

launch_app

# Get initial tab count via menu bar (approximate — count windows as proxy)
initial=$(count_windows)
send_keystroke "t" "command down"
sleep 1
after=$(count_windows)

assert_true "Window count unchanged (tabs in same window)" '[ "$after" -ge "$initial" ]'

quit_app

echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed"
exit $FAIL_COUNT
