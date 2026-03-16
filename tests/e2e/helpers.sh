#!/bin/bash
# Shared helpers for E2E tests

APP_BUNDLE="${APP_BUNDLE:-build/AwalTerminal.app}"
APP_NAME="Awal Terminal"
PASS_COUNT=0
FAIL_COUNT=0

assert_true() {
    local desc="$1"
    local condition="$2"
    if eval "$condition"; then
        echo "  PASS: $desc"
        ((PASS_COUNT++)) || true
    else
        echo "  FAIL: $desc"
        ((FAIL_COUNT++)) || true
    fi
}

launch_app() {
    open -a "$APP_BUNDLE"
    sleep 2
}

quit_app() {
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    sleep 1
}

app_is_running() {
    pgrep -x "AwalTerminal" > /dev/null 2>&1
}

count_windows() {
    osascript -e "tell application \"System Events\" to tell process \"AwalTerminal\" to count windows" 2>/dev/null
}

send_keystroke() {
    local key="$1"
    shift
    local mods="$*"
    if [ -n "$mods" ]; then
        osascript -e "tell application \"System Events\" to tell process \"AwalTerminal\" to keystroke \"$key\" using {$mods}"
    else
        osascript -e "tell application \"System Events\" to tell process \"AwalTerminal\" to keystroke \"$key\""
    fi
}

send_key_code() {
    local code="$1"
    shift
    local mods="$*"
    if [ -n "$mods" ]; then
        osascript -e "tell application \"System Events\" to tell process \"AwalTerminal\" to key code $code using {$mods}"
    else
        osascript -e "tell application \"System Events\" to tell process \"AwalTerminal\" to key code $code"
    fi
}
