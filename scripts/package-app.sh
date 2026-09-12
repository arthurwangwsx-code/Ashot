#!/bin/bash
# Package a macOS app without resource forks while preserving executable modes and symlinks.
set -euo pipefail
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $# == 2 ]] || fail 'Usage: package-app.sh APP.app OUTPUT.zip'
[[ "$1" == *.app && -f "$1/Contents/Info.plist" && -d "$1/Contents/MacOS" ]] || fail 'Input must be an app bundle.'
[[ "$2" == *.zip ]] || fail 'Output must end in .zip.'
APP="$(cd "$1" && pwd -P)"
OUTPUT_DIR="$(cd "$(dirname "$2")" && pwd -P)"
OUTPUT="$OUTPUT_DIR/$(basename "$2")"
case "$OUTPUT_DIR/" in "$APP/"*) fail 'Output must be outside the app bundle.';; esac
[[ ! -e "$OUTPUT" ]] || fail "Output already exists: $OUTPUT"
STAGE="$(mktemp -d "$OUTPUT_DIR/.zip-stage-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
(cd "$(dirname "$APP")" && COPYFILE_DISABLE=1 zip -q -r -X -y "$STAGE/payload.zip" "$(basename "$APP")")
unzip -tq "$STAGE/payload.zip"
# Publish the completed archive atomically and without overwriting a concurrently created file.
ln "$STAGE/payload.zip" "$OUTPUT"
echo "Archive: $OUTPUT"
