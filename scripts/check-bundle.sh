#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/.."
APP="dist/Porthole.app"
WEB="$APP/Contents/Resources/web"
failures=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi }
plist() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || echo "<missing>"; }

if [ ! -d "$APP" ]; then echo "$APP not found; run scripts/bundle.sh first" >&2; exit 2; fi
expect "bundle id" "$(plist "$APP" CFBundleIdentifier)" "io.github.muhammademanaftab.porthole"
expect "bundle name" "$(plist "$APP" CFBundleName)" "Porthole"
expect "starts as a menu-bar app (LSUIElement true); the Dock icon comes with a viewer window" "$(plist "$APP" LSUIElement)" "true"
expect "executable" "$(plist "$APP" CFBundleExecutable)" "porthole-host"
expect "declares the _porthole._tcp Bonjour service" "$(plist "$APP" NSBonjourServices.0)" "_porthole._tcp"
expect "names its icon" "$(plist "$APP" CFBundleIconFile)" "AppIcon"
if [ "$(head -c 4 "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null)" = "icns" ]; then pass "bundles AppIcon.icns"; else fail "bundles AppIcon.icns"; fi
if cmp -s "$APP/Contents/Resources/AppIcon.icns" assets/Porthole.icns; then pass "uses the Porthole icon"; else fail "uses the Porthole icon"; fi
VIEWLINK="$APP/Contents/MacOS/porthole-view"
expect "porthole-view is a relative link to the app's executable" "$(readlink "$VIEWLINK" 2>/dev/null)" "porthole-host"
"$VIEWLINK" help >/dev/null 2>&1
expect "porthole-view help runs" "$?" "0"
"$VIEWLINK" ls >/dev/null 2>&1
expect "porthole-view ls without a host is a usage error" "$?" "2"
"$APP/Contents/MacOS/porthole-host" pair >/dev/null 2>&1
expect "porthole-host routes viewer commands (pair without a host is a usage error)" "$?" "2"
if "$APP/Contents/MacOS/porthole-host" help 2>/dev/null | grep -q "usage: porthole-view"; then pass "porthole-host help lists the viewer commands too"; else fail "porthole-host help lists the viewer commands too"; fi

AGENT="$APP/Contents/Library/LaunchAgents/io.github.muhammademanaftab.porthole.watchdog.plist"
aplist() { plutil -extract "$1" raw -o - "$AGENT" 2>/dev/null || echo "<missing>"; }
if [ -f "$AGENT" ]; then pass "watchdog agent plist is bundled"; else fail "watchdog agent plist is bundled"; fi
if plutil -lint -s "$AGENT" >/dev/null 2>&1; then pass "watchdog agent plist is valid"; else fail "watchdog agent plist is valid"; fi
expect "watchdog agent label matches its file name" "$(aplist Label)" "io.github.muhammademanaftab.porthole.watchdog"
expect "watchdog agent runs the host binary" "$(aplist BundleProgram)" "Contents/MacOS/porthole-host"
if [ -x "$APP/$(aplist BundleProgram)" ]; then pass "watchdog agent program exists in the bundle"; else fail "watchdog agent program exists in the bundle"; fi
expect "watchdog agent passes watchdog" "$(aplist ProgramArguments.1)" "watchdog"
expect "watchdog agent sets PORTHOLE_COMMAND=watchdog" "$(aplist EnvironmentVariables.PORTHOLE_COMMAND)" "watchdog"
expect "watchdog agent starts at login" "$(aplist RunAtLoad)" "true"
if "$APP/Contents/MacOS/porthole-host" agent-plist 2>/dev/null | cmp -s - "$AGENT"; then
  pass "bundled agent plist matches what the host binary generates"
else fail "bundled agent plist matches what the host binary generates"; fi
if [ ! -e "$APP/Contents/Library/LaunchAgents/io.github.muhammademanaftab.porthole.plist" ]; then pass "the old login agent plist is not bundled"; else fail "the old login agent plist is not bundled"; fi

for f in index.html porthole-core.js livekit-client.umd.min.js; do
  if [ -f "$WEB/$f" ]; then pass "web/$f is bundled"; else fail "web/$f is bundled"; fi
done
for f in tests package.json; do
  if [ -e "$WEB/$f" ]; then fail "web/$f is not bundled"; else pass "web/$f is not bundled"; fi
done
extra=$(find "$WEB" -mindepth 1 \( -type d -o -name '.*' -o ! \( -name index.html -o -name '*.js' -o -name '*.css' -o -name '*.png' -o -name '*.webmanifest' \) \) 2>/dev/null)
if [ -z "$extra" ]; then pass "web holds only servable files"; else fail "web holds only servable files: $extra"; fi

if [ -x "$APP/Contents/MacOS/livekit-server" ]; then pass "livekit-server is executable"; else fail "livekit-server is executable"; fi
if codesign --verify --strict "$APP/Contents/MacOS/livekit-server" 2>/dev/null; then pass "livekit-server signature"; else fail "livekit-server signature"; fi
TILE="$APP/Contents/Helpers/porthole-tile"
if [ -x "$TILE" ]; then pass "porthole-tile helper is executable"; else fail "porthole-tile helper is executable"; fi
if codesign --verify --strict "$TILE" 2>/dev/null; then pass "porthole-tile signature"; else fail "porthole-tile signature"; fi
if otool -L "$TILE" 2>/dev/null | tail -n +2 | grep -qv -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/Library/'; then
  fail "porthole-tile links only system libraries"
else pass "porthole-tile links only system libraries"; fi
"$TILE" >/dev/null 2>&1
expect "porthole-tile refuses to run without arguments" "$?" "2"

for app in "$APP"; do
  CLI="$app/Contents/MacOS/porthole"
  if [ -x "$CLI" ]; then pass "$(basename "$app") bundles the porthole command"; else fail "$(basename "$app") bundles the porthole command"; fi
  if codesign --verify --strict "$CLI" 2>/dev/null; then pass "$(basename "$app") porthole signature"; else fail "$(basename "$app") porthole signature"; fi
  if otool -L "$CLI" 2>/dev/null | tail -n +2 | grep -qv -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/Library/'; then
    fail "$(basename "$app") porthole links only system libraries"
  else pass "$(basename "$app") porthole links only system libraries"; fi
  version=$("$CLI" version 2>/dev/null | head -1)
  if [[ "$version" == "porthole 0.1.0 "* ]]; then pass "$(basename "$app") porthole version runs"; else fail "$(basename "$app") porthole version runs ($version)"; fi
  "$CLI" bogus >/dev/null 2>&1
  rc=$?
  expect "$(basename "$app") porthole refuses an unknown command" "$rc" "2"
done

for app in "$APP"; do
  if codesign --verify --deep --strict "$app" 2>/dev/null; then pass "codesign --verify --deep --strict $app"; else fail "codesign --verify --deep --strict $app"; fi
done

if [ "$failures" -eq 0 ]; then echo; echo "Bundle checks passed."; else echo; echo "$failures bundle check(s) failed."; fi
[ "$failures" -eq 0 ]
