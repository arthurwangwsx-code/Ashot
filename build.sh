#!/bin/bash
# Local development signing remains the default. See doc/05-github-release.md for distribution.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
SIGNING="${ASHOT_SIGNING:-development}"
ARCHS="${ASHOT_ARCHS:-$(uname -m)}"
case "$SIGNING" in development|adhoc|developer-id) ;; *) echo "Invalid ASHOT_SIGNING" >&2; exit 2;; esac
case "$ARCHS" in arm64|x86_64|'arm64 x86_64') ;; *) echo "Invalid ASHOT_ARCHS" >&2; exit 2;; esac
if [[ "$SIGNING" == developer-id && "${ASHOT_SIGNING_IDENTITY:-}" != 'Developer ID Application:'* ]]; then
    echo 'Set ASHOT_SIGNING_IDENTITY to a Developer ID Application identity.' >&2
    exit 2
fi
mkdir -p "$ROOT/build/logs"
STAGE="$(mktemp -d "$ROOT/build/.build-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Ashot.app"
ARGS=(-quiet -project "$ROOT/Ashot.xcodeproj" -scheme Ashot -configuration Release -sdk macosx
    -destination 'generic/platform=macOS' -destination-timeout 30 -derivedDataPath "$STAGE/DerivedData"
    "ARCHS=$ARCHS" ONLY_ACTIVE_ARCH=NO)
if [[ -n "${ASHOT_VERSION:-}" ]]; then ARGS+=("MARKETING_VERSION=$ASHOT_VERSION"); fi
if [[ -n "${ASHOT_BUILD_NUMBER:-}" ]]; then ARGS+=("CURRENT_PROJECT_VERSION=$ASHOT_BUILD_NUMBER"); fi
if [[ "$SIGNING" != development ]]; then
    ARGS+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=)
fi
echo "Building Release ($ARCHS; signing=$SIGNING)…"
xcodebuild "${ARGS[@]}" build 2>&1 | tee "$ROOT/build/logs/release-build.log"
ditto "$STAGE/DerivedData/Build/Products/Release/Ashot.app" "$APP"
if [[ "$SIGNING" != development ]]; then
    # Never distribute development provisioning data. Sign only the final bundle.
    rm -f "$APP/Contents/embedded.provisionprofile"
    if [[ "$SIGNING" == developer-id ]]; then
        codesign --force --options runtime --timestamp --sign "$ASHOT_SIGNING_IDENTITY" "$APP"
    else
        codesign --force --options runtime --sign - "$APP"
    fi
fi
codesign --verify --deep --strict "$APP"
for arch in $ARCHS; do lipo "$APP/Contents/MacOS/Ashot" -verify_arch "$arch"; done
# Replace the old app only after a successful build. Preserve test logs and other artifacts.
rm -rf "$ROOT/build/Ashot.app"
ditto "$APP" "$ROOT/build/Ashot.app"
echo "Output: $ROOT/build/Ashot.app"
codesign -dv "$ROOT/build/Ashot.app" 2>&1
