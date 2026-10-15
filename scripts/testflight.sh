#!/usr/bin/env bash
# Archive the iPhone app (with the watch app and its complication inside), sign it for App Store
# distribution and upload it to TestFlight.
#
#   scripts/testflight.sh              # archive + upload
#   scripts/testflight.sh --no-upload  # archive + export an .ipa into build-testflight/export (no upload)
#
# Signing is automatic (cloud-managed distribution certificate and App Store profiles for
# io.artnim.stint.ios, .watchkitapp and .watchkitapp.widget). Credentials: locally the Apple ID
# signed in to Xcode; in CI an App Store Connect API key via NOTARY_KEY_PATH / NOTARY_KEY_ID /
# NOTARY_ISSUER_ID (the same variables scripts/release.sh uses). The key needs the Admin role
# (App Manager can upload but cannot create distribution certificates and profiles).
set -euo pipefail

cd "$(dirname "$0")/.."
UPLOAD=1
[ "${1:-}" = "--no-upload" ] && UPLOAD=0

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)   # every target carries it
[ -n "$VERSION" ] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }
BUILD_NUMBER=$(git rev-list --count HEAD)          # same build number as the Mac release; always increases
OUT=build-testflight
ARCHIVE="$OUT/Stint.xcarchive"

AUTH=()
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  AUTH=(-authenticationKeyPath "$NOTARY_KEY_PATH" -authenticationKeyID "$NOTARY_KEY_ID"
        -authenticationKeyIssuerID "$NOTARY_ISSUER_ID")
fi

echo "==> generating project"
xcodegen generate --quiet

echo "==> archiving StintMobile $VERSION ($BUILD_NUMBER)"
rm -rf "$OUT"
xcodebuild archive -scheme StintMobile -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT/derived" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  2>&1 | grep -E "error:|warning: .*(Mobile|Watch)/|ARCHIVE" || true
[ -d "$ARCHIVE/Products/Applications/StintMobile.app" ] || { echo "archive failed" >&2; exit 1; }
[ -d "$ARCHIVE/Products/Applications/StintMobile.app/Watch/StintWatch.app" ] \
  || { echo "archive is missing the embedded watch app" >&2; exit 1; }

DEST=export; [ "$UPLOAD" = 1 ] && DEST=upload
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DEST</string>
	<key>teamID</key><string>76C3CLR3D5</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>testFlightInternalTestingOnly</key><true/>
</dict>
</plist>
EOF

echo "==> exporting ($DEST)"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} 2>&1 \
  | grep -E "error|Upload|EXPORT|Progress" || true
if [ "$UPLOAD" = 1 ]; then
  echo "==> uploaded $VERSION ($BUILD_NUMBER); TestFlight shows it after processing (about 10-30 minutes)"
else
  ls "$OUT/export"/*.ipa >/dev/null 2>&1 || { echo "export failed: no .ipa" >&2; exit 1; }
  echo "==> exported: $(ls "$OUT/export"/*.ipa)"
fi
