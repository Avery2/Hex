#!/bin/sh
# Build the local Hex fork and install it as /Applications/Hex Debug.app.
#
# This QUITS the running app, so run it when you are not mid-recording. It exists so you
# control that timing instead of asking someone else to do it for you.
#
#   ./install-fork.sh
#
# Signing with your own Apple Development identity (rather than ad-hoc) is what keeps
# Microphone, Accessibility and Input Monitoring granted across rebuilds: ad-hoc signing
# changes the cdhash every build, which macOS reads as a different app.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

identity=${HEX_SIGN_IDENTITY:-"Apple Development: javerychan@outlook.com (7L8S7AGTK6)"}
derived=${HEX_DERIVED_DATA:-"$root/.build-fork"}
bundle="Hex Debug.app"
destination="/Applications/$bundle"

echo "==> Building"
xcodebuild \
  -project Hex.xcodeproj \
  -scheme Hex \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" \
  build \
  -skipMacroValidation \
  -IDESkipPackagePluginFingerprintValidation=YES \
  DEVELOPMENT_TEAM="" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  > "$derived/build.log" 2>&1 || {
    echo "Build failed. Tail of $derived/build.log:" >&2
    tail -30 "$derived/build.log" >&2
    exit 1
  }

built="$derived/Build/Products/Debug/$bundle"
[ -d "$built" ] || { echo "Build product missing at $built" >&2; exit 1; }

echo "==> Quitting the running app"
pkill -f "$destination/Contents/MacOS/Hex" 2>/dev/null || true
sleep 2

echo "==> Installing to $destination"
rm -rf "$destination"
cp -R "$built" "$destination"

echo "==> Signing"
codesign --force --deep --sign "$identity" \
  --entitlements "$root/Hex/Hex.entitlements" "$destination" >/dev/null

echo "==> Launching"
open "$destination"

sleep 8
if pgrep -f "$destination/Contents/MacOS/Hex" >/dev/null; then
  echo "Installed and running."
else
  echo "Installed, but it did not stay running — check Console for 'Hex Debug'." >&2
  exit 1
fi
