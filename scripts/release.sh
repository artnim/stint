#!/usr/bin/env bash
# Build a signed, notarized, stapled Stint.app and package it as a drag-to-Applications DMG.
#
#   scripts/release.sh                 # build + sign + notarize + staple -> dist/Stint-<version>.dmg
#   scripts/release.sh --no-notarize   # build + sign only (no Apple credentials needed)
#
# The app is notarized and stapled before it goes into the DMG (so a copy in /Applications carries its
# ticket, also offline); then the DMG itself is signed, notarized and stapled.
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
DMGBUILD_VERSION=1.6.7

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)   # every target carries it
[ -n "$VERSION" ] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }
BUILD_NUMBER=$(git rev-list --count HEAD)
# a clean, dedicated derived-data dir: an incremental build can re-copy resource bundles
# after the app was sealed, which breaks the signature
DERIVED=build-release
APP=$DERIVED/Build/Products/Release/Stint.app
DIST=dist
DMG="$DIST/Stint-$VERSION.dmg"

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

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*\([0-9A-F]\{40\}\) "Developer ID Application.*/\1/p' | head -1)
[ -n "$IDENTITY" ] || { echo "no Developer ID Application identity in the keychain" >&2; exit 1; }

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

if [ "$NOTARIZE" = 1 ]; then
  # credentials: an App Store Connect API key via env (CI), else the keychain profile (local)
  if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
  else
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
  fi
fi

# notarize <file>: submit, wait, print the log and fail unless Accepted
notarize() {
  echo "==> notarizing $(basename "$1")"
  local result id
  result=$(xcrun notarytool submit "$1" "${AUTH[@]}" --wait 2>&1 | tee /dev/stderr)
  if ! grep -q "status: Accepted" <<<"$result"; then
    id=$(sed -n 's/^ *id: *//p' <<<"$result" | head -1)
    echo "notarization not accepted; log:" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "${AUTH[@]}" >&2
    exit 1
  fi
}

if [ "$NOTARIZE" = 1 ]; then
  ZIP="$DERIVED/Stint-notarize.zip"            # notarytool takes a zip; it never ships
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  echo "==> stapling the app"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "==> building the DMG"
python3 -m venv "$DERIVED/dmgbuild-venv"
"$DERIVED/dmgbuild-venv/bin/pip" install --quiet "dmgbuild==$DMGBUILD_VERSION"
swift scripts/dmg/background.swift 1 "$DERIVED/dmg-bg.png" >/dev/null
swift scripts/dmg/background.swift 2 "$DERIVED/dmg-bg@2x.png" >/dev/null
tiffutil -cathidpicheck "$DERIVED/dmg-bg.png" "$DERIVED/dmg-bg@2x.png" -out "$DERIVED/dmg-bg.tiff" >/dev/null
mkdir -p "$DIST"
rm -f "$DMG"
"$DERIVED/dmgbuild-venv/bin/dmgbuild" -s scripts/dmg/settings.py \
  -D app="$APP" -D background="$DERIVED/dmg-bg.tiff" "Stint" "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  notarize "$DMG"
  echo "==> stapling the DMG"
  xcrun stapler staple "$DMG"
  echo "==> gatekeeper check"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

echo "==> done: $DMG"
