#!/bin/sh
# Archive Dits and upload it to TestFlight.
#
# Auth (pick one):
#   • Signed-in Xcode account for team 7Q2SS8772K (Xcode → Settings →
#     Accounts), OR
#   • An App Store Connect API key. Set:
#       export ASC_KEY_ID=XXXXXXXXXX
#       export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#     and place AuthKey_$ASC_KEY_ID.p8 in ~/.appstoreconnect/private_keys/
#     (or set ASC_KEY_PATH to its full path).
#
# Also one-time: an App Store Connect app record for com.w2asm.dits
# (App Store Connect → Apps → ＋ → New App — website only).
#
# Usage: tools/upload-testflight.sh
set -e

cd "$(dirname "$0")/../app"

BUILD=${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
ARCHIVE=/tmp/Dits-$BUILD.xcarchive
PLIST=/tmp/Dits-ExportOptions.plist

# Optional App Store Connect API key auth (bypasses the Xcode session).
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
AUTH_ARGS=""
if [ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER_ID" ] && [ -f "$KEY_PATH" ]; then
  echo "==> Using App Store Connect API key $ASC_KEY_ID"
  AUTH_ARGS="-authenticationKeyPath $KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
fi

echo "==> Generating project"
xcodegen generate > /dev/null

echo "==> Archiving build $BUILD"
xcodebuild archive \
  -project Dits.xcodeproj -scheme Dits \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  -allowProvisioningUpdates $AUTH_ARGS -quiet

cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>7Q2SS8772K</string>
</dict>
</plist>
XML

echo "==> Uploading to App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "/tmp/Dits-upload-$BUILD" \
  -exportOptionsPlist "$PLIST" \
  -allowProvisioningUpdates $AUTH_ARGS

echo "==> Uploaded build $BUILD. It will appear in TestFlight after"
echo "    Apple's processing (typically 5-15 minutes)."
