#!/bin/bash
# Build on this Mac; GitHub stores source, tags and release artifacts, not signing credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
fail() { echo "ERROR: $*" >&2; exit 1; }
usage() {
    echo 'Usage: ./release.sh VERSION [--publish] [--allow-unnotarized]'
    echo 'Default: package locally. Publishing requires a public GitHub origin and a clean tree.'
    echo 'Unnotarized builds require a prerelease version, e.g. 1.0.0-preview.1.'
    echo 'Trusted releases: set ASHOT_SIGNING_IDENTITY and ASHOT_NOTARY_PROFILE.'
}
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
[[ $# -gt 0 ]] || { usage; exit 2; }
VERSION="$1"; shift
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]] || fail 'Use a semantic version without v, e.g. 1.0.0-preview.1.'
PUBLISH=false
UNNOTARIZED=false
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=true ;;
        --allow-unnotarized) UNNOTARIZED=true ;;
        *) fail "Unknown option: $arg" ;;
    esac
done
if $UNNOTARIZED; then
    [[ "$VERSION" == *-* ]] || fail 'Unnotarized packages must use a prerelease version.'
    SIGNING=adhoc
else
    [[ "${ASHOT_SIGNING_IDENTITY:-}" == 'Developer ID Application:'* ]] || fail 'Developer ID Application identity required, or explicitly use --allow-unnotarized for a preview.'
    [[ -n "${ASHOT_NOTARY_PROFILE:-}" ]] || fail 'ASHOT_NOTARY_PROFILE is required for notarization.'
    SIGNING=developer-id
fi
for tool in git python3 xcodebuild codesign ditto hdiutil shasum lipo; do
    command -v "$tool" >/dev/null || fail "Missing tool: $tool"
done
[[ "$(uname -s)" == Darwin ]] || fail 'Run packaging on macOS.'
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Review and commit all changes before packaging.'
python3 scripts/check_public_files.py
COMMIT="$(git rev-parse HEAD)"
BRANCH="$(git symbolic-ref --quiet --short HEAD)" || fail 'Detached HEAD is not publishable.'
TAG="v$VERSION"
DIST="$ROOT/dist/$TAG"
[[ ! -e "$DIST" ]] || fail "Output already exists: $DIST (preserved; move it aside before retrying)."
REPO=''
if $PUBLISH; then
    command -v gh >/dev/null || fail 'GitHub CLI (gh) is required.'
    gh auth status --hostname github.com >/dev/null 2>&1 || fail 'Authenticate with gh auth login first.'
    ORIGIN="$(git remote get-url origin)" || fail 'Configure origin to your public GitHub repository first.'
    REPO="$(python3 - "$ORIGIN" <<'PY'
import re, sys
match = re.fullmatch(r'(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?', sys.argv[1])
if not match:
    sys.exit('origin must be a credential-free github.com HTTPS or SSH URL')
print(match.group(1))
PY
)"
    [[ "$(git remote get-url --push origin)" == "$ORIGIN" ]] || fail 'origin has a different push URL; review it first.'
    [[ "$(gh repo view "$REPO" --json visibility --jq .visibility)" == PUBLIC ]] || fail 'The destination repository must be public.'
    git fetch origin --tags
    if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
        git merge-base --is-ancestor "origin/$BRANCH" HEAD || fail 'Local branch is behind or diverged from origin.'
    fi
    ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "Tag already exists: $TAG"
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then fail "Release already exists: $TAG"; fi
fi
echo 'Running unit tests and release-script checks…'
python3 -m unittest discover -s scripts/tests -v
./dev.sh test
BUILD_NUMBER="$(git rev-list --count HEAD)"
ASHOT_SIGNING="$SIGNING" ASHOT_ARCHS='arm64 x86_64' ASHOT_VERSION="${VERSION%%-*}" \
    ASHOT_BUILD_NUMBER="$BUILD_NUMBER" ./build.sh
[[ "$(git rev-parse HEAD)" == "$COMMIT" && -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Source changed during the build. Nothing was published.'

mkdir -p "$DIST"
STAGE="$(mktemp -d "$ROOT/build/.release-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Ashot.app"
ditto --noextattr --norsrc "$ROOT/build/Ashot.app" "$APP"
[[ ! -e "$APP/Contents/embedded.provisionprofile" ]] || fail 'Distribution app contains a provisioning profile.'
if ! $UNNOTARIZED; then
    ditto -c -k --keepParent --noextattr --norsrc "$APP" "$STAGE/notarize.zip"
    xcrun notarytool submit "$STAGE/notarize.zip" --keychain-profile "$ASHOT_NOTARY_PROFILE" --wait --timeout 30m
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute "$APP"
fi
codesign --verify --deep --strict "$APP"
NAME="Ashot-$VERSION-universal"
ditto -c -k --keepParent --noextattr --norsrc "$APP" "$DIST/$NAME.zip"
mkdir "$STAGE/dmg"
ditto --noextattr --norsrc "$APP" "$STAGE/dmg/Ashot.app"
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -quiet -volname Ashot -srcfolder "$STAGE/dmg" -format UDZO "$DIST/$NAME.dmg"
hdiutil verify "$DIST/$NAME.dmg"
if ! $UNNOTARIZED; then
    codesign --timestamp --sign "$ASHOT_SIGNING_IDENTITY" "$DIST/$NAME.dmg"
    xcrun notarytool submit "$DIST/$NAME.dmg" --keychain-profile "$ASHOT_NOTARY_PROFILE" --wait --timeout 30m
    xcrun stapler staple "$DIST/$NAME.dmg"
    xcrun stapler validate "$DIST/$NAME.dmg"
fi
python3 - "$APP" "$DIST/release.json" "$VERSION" "$TAG" "$COMMIT" "$SIGNING" "$REPO" <<'PY'
import datetime, json, pathlib, plistlib, sys
app, output, version, tag, commit, signing, repository = sys.argv[1:]
with open(pathlib.Path(app) / 'Contents/Info.plist', 'rb') as file:
    info = plistlib.load(file)
data = dict(version=version, tag=tag, commit=commit, repository=repository,
            bundleVersion=info['CFBundleShortVersionString'], buildNumber=info['CFBundleVersion'],
            minimumMacOS=info['LSMinimumSystemVersion'], architectures=['arm64', 'x86_64'],
            signing=signing, notarized=signing == 'developer-id',
            builtAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
pathlib.Path(output).write_text(json.dumps(data, indent=2) + '\n')
PY
python3 - "$DIST/release.json" "$DIST/RELEASE_NOTES.md" <<'PY'
import json, pathlib, sys
m = json.loads(pathlib.Path(sys.argv[1]).read_text())
warning = ('Developer ID signed and Apple notarized.\n' if m['notarized'] else
           '**Preview: ad-hoc signed, NOT Apple notarized. macOS Gatekeeper may block first launch.**\n'
           'Use only after reviewing the source and verifying SHA256SUMS. Do not disable Gatekeeper globally.\n'
           'Screen Recording authorization may need to be granted again after upgrades.\n')
pathlib.Path(sys.argv[2]).write_text(f'''# Ashot {m['version']}

Menu-bar screenshots, editable annotations, on-device OCR, pinning, color picking,
background beautification, local history, and English / Simplified Chinese settings.

## Installation
macOS {m['minimumMacOS']} or later; Universal binary for Apple silicon and Intel.
Open the DMG and drag Ashot into Applications, or unzip the ZIP and move Ashot.app there.
The app appears in the menu bar, not the Dock by default. Grant Screen Recording access.

{warning}
## Release review
- Prevent concurrent history filenames from overwriting images and late writes restoring cleared history.
- Sanitize history filename templates and use atomic metadata writes.
- Bound scrolling-capture frame count and pixel storage; ignore late frames after stopping.
- Correct window-preview coordinate conversion and enforce a total screenshot pixel budget.
- Build/test/package locally; publish source, tag, DMG, ZIP and checksums to GitHub.

## Known limitations
Scrolling capture remains experimental and opens the editor rather than the ordinary capture completion flow.
Real Screen Recording prompts, multi-monitor interactions and global shortcuts need interactive testing.
There is no in-app GitHub login or automatic application updater. No license grant has been added.

Source commit: `{m['commit']}`. Build number: `{m['buildNumber']}`.
See `doc/05-github-release.md` and `doc/06-release-review.md` in the source repository.
''')
PY
(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" release.json RELEASE_NOTES.md > SHA256SUMS && shasum -a 256 -c SHA256SUMS)

if $PUBLISH; then
    [[ "$(git rev-parse HEAD)" == "$COMMIT" && -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Source changed before publishing.'
    # Push an explicit branch and tag together. Never force-push or overwrite existing assets.
    git tag -a "$TAG" "$COMMIT" -m "Ashot $VERSION"
    git push --atomic origin "HEAD:refs/heads/$BRANCH" "refs/tags/$TAG"
    OPTIONS=(--repo "$REPO" --verify-tag --title "Ashot $VERSION" --notes-file "$DIST/RELEASE_NOTES.md" --draft)
    if [[ "$VERSION" == *-* ]]; then OPTIONS+=(--prerelease --latest=false); fi
    gh release create "$TAG" "${OPTIONS[@]}" "$DIST/$NAME.zip" "$DIST/$NAME.dmg" \
        "$DIST/SHA256SUMS" "$DIST/release.json" "$DIST/RELEASE_NOTES.md"
    # Keep incomplete uploads hidden as a draft on error; publish only after all uploads return success.
    gh release edit "$TAG" --repo "$REPO" --draft=false
    gh release view "$TAG" --repo "$REPO" --json url,assets,isDraft,isPrerelease
fi
echo "Release artifacts: $DIST"
