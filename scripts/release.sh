#!/usr/bin/env bash
# Build a signed, notarized, stapled Timetracker.app and zip it for distribution.
#
#   scripts/release.sh            # build + sign + notarize + staple -> dist/Timetracker-<version>.zip
#   scripts/release.sh --no-notarize   # build + sign only (no Apple credentials needed)
#
# One-time setup for notarization (stores an app-specific password in the login keychain,
# nothing lands in the repo):
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id <apple-id> --team-id 76C3CLR3D5
set -euo pipefail

cd "$(dirname "$0")/.."
NOTARY_PROFILE="${NOTARY_PROFILE:-timetracker-notary}"
NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
[ -n "$VERSION" ] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }
BUILD_NUMBER=$(git rev-list --count HEAD)
APP=build/Build/Products/Release/Timetracker.app
DIST=dist
ZIP="$DIST/Timetracker-$VERSION.zip"

echo "==> generating project"
xcodegen generate --quiet

echo "==> building Release $VERSION ($BUILD_NUMBER)"
xcodebuild -scheme Timetracker -configuration Release -derivedDataPath build \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build 2>&1 | grep -E "error:|warning: .*App/|BUILD" || true
[ -d "$APP" ] || { echo "build failed: $APP missing" >&2; exit 1; }

echo "==> verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|TeamIdentifier|flags=.*runtime" \
  || { echo "not signed with Developer ID + hardened runtime" >&2; exit 1; }

mkdir -p "$DIST"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "$NOTARIZE" = 1 ]; then
  echo "==> notarizing (profile $NOTARY_PROFILE)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> stapling"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> gatekeeper check"
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> done: $ZIP"
