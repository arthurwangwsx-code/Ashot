#!/bin/bash
#
# dev.sh — common Ashot development tasks.
#
# Usage:
#   ./dev.sh test [NAME]   Run unit tests. Optional NAME runs just one suite or test:
#                            ./dev.sh test                                    (all unit tests)
#                            ./dev.sh test ColorFormattingTests               (one suite)
#                            ./dev.sh test HotKeyTests/keyStringMapsCommonKeys (one test)
#   ./dev.sh ui            Run the UI tests (slow, drives the real GUI).
#   ./dev.sh check         Fast compile check (Debug build, no signing).
#   ./dev.sh run           Build the signed Release .app and launch it.
#   ./dev.sh build         Build the signed Release .app (no launch) via build.sh.
#   ./dev.sh clean         Remove build/ and cached derived data.
#   ./dev.sh reset-perms   Reset this app's Screen Recording permission (re-grant once after).
#   ./dev.sh kill          Quit a running Ashot instance.
#   ./dev.sh help          Show this help.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="Ashot.xcodeproj"
SCHEME="Ashot"
DERIVED="$SCRIPT_DIR/.dd"            # persistent derived data → fast incremental test/check
LOG_DIR="$SCRIPT_DIR/build/logs"
BUNDLE_ID="com.arthur.Ashot"

# Run xcodebuild, stream a readable summary, keep a full log, and propagate the real exit code.
xcb() {
    mkdir -p "$LOG_DIR"
    local log="$LOG_DIR/xcodebuild.log"
    local filter="Test Suite|Test Case|passed|failed|✔|✘|◇|◆|error:|BUILD (SUCCEEDED|FAILED)|TEST (SUCCEEDED|FAILED)|Signed by|Output:"
    xcodebuild "$@" 2>&1 | tee "$log" | grep --line-buffered -iE "$filter"
    local st=${PIPESTATUS[0]}
    if [ "$st" -ne 0 ]; then
        echo ""
        echo "❌ xcodebuild failed (exit $st). Recent errors:"
        grep -iE "error:|fatal error|FAILED" "$log" | tail -30
        echo "Full log: $log"
    fi
    return "$st"
}

cmd="${1:-help}"
[ $# -gt 0 ] && shift

case "$cmd" in
    test)
        only="AshotTests"
        [ $# -gt 0 ] && only="AshotTests/$1"
        echo "▶ Unit tests: $only"
        xcb test -project "$PROJECT" -scheme "$SCHEME" -sdk macosx \
            -destination "platform=macOS,arch=$(uname -m)" -destination-timeout 30 \
            -parallel-testing-enabled NO \
            -only-testing:"$only" \
            -derivedDataPath "$DERIVED" \
            CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
        ;;

    ui)
        echo "▶ UI tests (this launches and drives the GUI)…"
        xcb test -project "$PROJECT" -scheme "$SCHEME" \
            -destination 'platform=macOS,arch=arm64' \
            -only-testing:AshotUITests \
            -derivedDataPath "$DERIVED"
        ;;

    check)
        echo "▶ Compile check (Debug, unsigned)…"
        xcb build -project "$PROJECT" -scheme "$SCHEME" -sdk macosx \
            -configuration Debug \
            -destination 'generic/platform=macOS' -destination-timeout 30 \
            -derivedDataPath "$DERIVED" \
            CODE_SIGNING_ALLOWED=NO
        ;;

    build)
        echo "▶ Building signed Release .app…"
        ./build.sh || exit $?
        ;;

    run)
        echo "▶ Building + launching…"
        ./build.sh || exit $?
        pkill -x Ashot 2>/dev/null || true
        open "$SCRIPT_DIR/build/Ashot.app"
        echo "✅ Launched build/Ashot.app"
        ;;

    clean)
        rm -rf "$SCRIPT_DIR/build" "$DERIVED"
        echo "✅ Removed build/ and $DERIVED"
        ;;

    reset-perms)
        echo "Resetting Screen Recording permission for $BUNDLE_ID…"
        tccutil reset ScreenCapture "$BUNDLE_ID"
        echo "✅ Done. Launch the app and grant Screen Recording once when prompted."
        ;;

    kill)
        pkill -x Ashot && echo "✅ Quit Ashot." || echo "Ashot was not running."
        ;;

    help|--help|-h)
        sed -n '2,/^set /p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '/^set /d'
        ;;

    *)
        echo "Unknown command: $cmd"
        echo "Run ./dev.sh help for usage."
        exit 1
        ;;
esac
