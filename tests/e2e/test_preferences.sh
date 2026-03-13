#!/bin/bash
# Test: Cmd+, opens preferences window
set -euo pipefail
source "$(dirname "$0")/helpers.sh"

echo "Test: Preferences (Cmd+,)"

launch_app

before=$(count_windows)
send_keystroke "," "command down"
sleep 1
after=$(count_windows)

assert_true "Preferences window appeared" '[ "$after" -gt "$before" ]'

quit_app

echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed"
exit $FAIL_COUNT
