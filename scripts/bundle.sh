#!/bin/bash
# Builds Porthole Host.app and Porthole.app into dist/.
# SIGN_ID: a code-signing identity (default: ad-hoc "-"). A stable identity keeps
# macOS privacy permissions across rebuilds; ad-hoc signing asks again after each build.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
SIGN_ID=${SIGN_ID:-"-"}
swift build -c "$CONFIG" --arch arm64
BIN=.build/arm64-apple-macosx/$CONFIG
rm -rf dist && mkdir -p dist

make_app() { # name exe bundle-id ui-element
  local app="dist/$1.app" exe=$2 id=$3 agent=$4
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
  cp "$BIN/$exe" "$app/Contents/MacOS/$exe"
  # Dynamic frameworks SwiftPM placed next to the binary (LiveKit's WebRTC and FFI).
  for fw in "$BIN"/*.framework; do [ -e "$fw" ] && cp -R "$fw" "$app/Contents/Frameworks/"; done
  install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/$exe" 2>/dev/null || true
  # SwiftPM resource bundles (LiveKit ships one).
  for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleDisplayName</key><string>$1</string>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><$agent/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Porthole shares this Mac's windows with your other machines.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Porthole connects your Macs on this network.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
}

make_app "Porthole Host" porthole-host io.github.muhammademanaftab.porthole true
cp -R web "dist/Porthole Host.app/Contents/Resources/web"
LK=$(command -v livekit-server || true)
[ -n "$LK" ] && cp "$(realpath "$LK")" "dist/Porthole Host.app/Contents/Resources/livekit-server"
make_app "Porthole" porthole-view io.github.muhammademanaftab.porthole.view false

for app in "dist/Porthole Host.app" "dist/Porthole.app"; do
  codesign --force --deep --options runtime --timestamp=none -s "$SIGN_ID" \
    --entitlements scripts/entitlements.plist "$app"
done
echo "Built: $(ls -d dist/*.app | tr '\n' ' ')"
