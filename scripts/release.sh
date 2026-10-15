#!/usr/bin/env bash
# Build a signed, notarized, stapled Stint.app and zip it for distribution.
#
#   scripts/release.sh            # build + sign + notarize + staple -> dist/Stint-<version>.zip
#   scripts/release.sh --no-notarize   # build + sign only (no Apple credentials needed)
#
# One-time setup for notarization (stores an app-specific password in the login keychain,
# nothing lands in the repo):
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id <apple-id> --team-id 76C3CLR3D5
# In CI, set NOTARY_KEY_PATH (.p8), NOTARY_KEY_ID and NOTARY_ISSUER_ID instead (App Store Connect API key).
set -euo pipefail

cd "$(dirname "$0")/.."
NOTARY_PROFILE="${NOTARY_PROFILE:-stint-notary}"
NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)   # both targets carry it
[ -n "$VERSION" ] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }
BUILD_NUMBER=$(git rev-list --count HEAD)
# a clean, dedicated derived-data dir: an incremental build can re-copy resource bundles
# after the app was sealed, which breaks the signature
DERIVED=build-release
APP=$DERIVED/Build/Products/Release/Stint.app
DIST=dist
ZIP="$DIST/Stint-$VERSION.zip"

PROFILE_FOUND=0
# Xcode 16 and later keep profiles under UserData; older Xcode under MobileDevice. A missing directory
# leaves its glob unexpanded, which the existence guard skips.
for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile \
         "$HOME/Library/MobileDevice/Provisioning Profiles"/*.provisionprofile; do
  [ -e "$f" ] || continue
  [ "$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null)" = "Stint Developer ID" ] \
    && { PROFILE_FOUND=1; break; }
done
[ "$PROFILE_FOUND" = 1 ] \
  || { echo "no provisioning profile named 'Stint Developer ID' installed; see README -> Release build" >&2; exit 1; }

echo "==> generating project"
xcodegen generate --quiet

echo "==> building Release $VERSION ($BUILD_NUMBER) from scratch"
rm -rf "$DERIVED"
xcodebuild -scheme Stint -configuration Release -derivedDataPath "$DERIVED" \
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
  # credentials: an App Store Connect API key via env (CI), else the keychain profile (local)
  if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    echo "==> notarizing (API key $NOTARY_KEY_ID)"
  else
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
    echo "==> notarizing (profile $NOTARY_PROFILE)"
  fi
  RESULT=$(xcrun notarytool submit "$ZIP" "${AUTH[@]}" --wait 2>&1 | tee /dev/stderr)
  if ! grep -q "status: Accepted" <<<"$RESULT"; then
    ID=$(sed -n 's/^ *id: *//p' <<<"$RESULT" | head -1)
    echo "notarization not accepted; log:" >&2
    [ -n "$ID" ] && xcrun notarytool log "$ID" "${AUTH[@]}" >&2
    exit 1
  fi
  echo "==> stapling"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> gatekeeper check"
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> done: $ZIP"
