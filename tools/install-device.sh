#!/bin/sh
# Build a signed Debug build of Dits and install + launch it on a
# connected iPhone. The iPhone must be plugged in (or paired over the
# network), unlocked, and trusting this Mac.
#
# Usage: tools/install-device.sh [device-name-or-udid]
set -e

cd "$(dirname "$0")/../app"

DEVICE="$1"
if [ -z "$DEVICE" ]; then
  # First connected physical device reported by xctrace.
  DEVICE=$(xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices/{d=1;next} /^== /{d=0} d && /\(/ && !/Simulator/ && !/MacBook/ {print; exit}' \
    | sed -E 's/ \([0-9].*//')
fi

if [ -z "$DEVICE" ]; then
  echo "No connected iPhone found. Plug one in, unlock it, tap Trust, and retry."
  exit 1
fi

echo "==> Target device: $DEVICE"
echo "==> Generating project"
xcodegen generate > /dev/null

echo "==> Building & installing (automatic signing)"
xcodebuild \
  -project Dits.xcodeproj -scheme Dits \
  -destination "platform=iOS,name=$DEVICE" \
  -allowProvisioningUpdates \
  -derivedDataPath /tmp/dits-device \
  build

APP="/tmp/dits-device/Build/Products/Debug-iphoneos/Dits.app"
echo "==> Installing $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "==> Installed. Launch Dits from the Home Screen (or trust the developer"
echo "    profile under Settings → General → VPN & Device Management first)."
