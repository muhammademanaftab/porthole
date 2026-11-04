#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
SIGN_ID=${SIGN_ID:-$(security find-identity -p codesigning 2>/dev/null | awk '/"Porthole Dev"/{print $2; exit}')}
SIGN_ID=${SIGN_ID:-"-"}
swift build ${SWIFT_JOBS:+-j "$SWIFT_JOBS"} -c "$CONFIG" --arch arm64
BIN=.build/arm64-apple-macosx/$CONFIG
rm -rf dist && mkdir -p dist

make_app() {
  local app="dist/$1.app" exe=$2 id=$3 agent=$4 icon=$5
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
  cp "assets/$icon.icns" "$app/Contents/Resources/AppIcon.icns"
  cp "$BIN/$exe" "$app/Contents/MacOS/$exe"
  for fw in "$BIN"/*.framework; do [ -e "$fw" ] && cp -R "$fw" "$app/Contents/Frameworks/"; done
  install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/$exe" 2>/dev/null || true
  for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleDisplayName</key><string>$1</string>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><$agent/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Porthole shares this Mac's windows with your other machines.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Porthole connects your Macs on this network.</string>
  <key>NSBonjourServices</key><array><string>_porthole._tcp</string></array>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
}

make_app "Porthole Host" porthole-host io.github.muhammademanaftab.porthole true PortholeHost
AGENTS="dist/Porthole Host.app/Contents/Library/LaunchAgents"
mkdir -p "$AGENTS"
"$BIN/porthole-host" agent-plist > "$AGENTS/io.github.muhammademanaftab.porthole.watchdog.plist"
plutil -lint -s "$AGENTS/io.github.muhammademanaftab.porthole.watchdog.plist"
WEBDST="dist/Porthole Host.app/Contents/Resources/web"
mkdir -p "$WEBDST"
find web -maxdepth 1 -type f ! -name '.*' \( -name index.html -o -name '*.js' -o -name '*.css' -o -name '*.png' -o -name '*.webmanifest' \) \
  -exec cp {} "$WEBDST/" \;
LK=$(command -v livekit-server || true)
if [ -z "$LK" ]; then echo "livekit-server not found: brew install livekit" >&2; exit 1; fi
LKDST="dist/Porthole Host.app/Contents/MacOS/livekit-server"
cat "$(realpath "$LK")" > "$LKDST"
chmod 755 "$LKDST"
codesign --force --options runtime --timestamp=none -s "$SIGN_ID" "$LKDST"
make_app "Porthole" porthole-view io.github.muhammademanaftab.porthole.view false Porthole
TILEDST="dist/Porthole.app/Contents/Helpers/porthole-tile"
mkdir -p "$(dirname "$TILEDST")"
cp "$BIN/porthole-tile" "$TILEDST"
codesign --force --options runtime --timestamp=none -s "$SIGN_ID" "$TILEDST"

for app in "dist/Porthole Host.app" "dist/Porthole.app"; do
  codesign --force --deep --options runtime --timestamp=none -s "$SIGN_ID" \
    --entitlements scripts/entitlements.plist "$app"
done
echo "Built: $(ls -d dist/*.app | tr '\n' ' ')"
