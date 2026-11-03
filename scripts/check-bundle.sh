#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/.."
HOST="dist/Porthole Host.app"
VIEW="dist/Porthole.app"
WEB="$HOST/Contents/Resources/web"
failures=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi }
plist() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || echo "<missing>"; }

for app in "$HOST" "$VIEW"; do
  if [ ! -d "$app" ]; then echo "$app not found; run scripts/bundle.sh first" >&2; exit 2; fi
done

expect "host bundle id" "$(plist "$HOST" CFBundleIdentifier)" "io.github.muhammademanaftab.porthole"
expect "viewer bundle id" "$(plist "$VIEW" CFBundleIdentifier)" "io.github.muhammademanaftab.porthole.view"
expect "host is a menu-bar agent (LSUIElement true)" "$(plist "$HOST" LSUIElement)" "true"
expect "viewer is a regular app (LSUIElement false)" "$(plist "$VIEW" LSUIElement)" "false"
expect "host executable" "$(plist "$HOST" CFBundleExecutable)" "porthole-host"
expect "viewer executable" "$(plist "$VIEW" CFBundleExecutable)" "porthole-view"
for app in "$HOST" "$VIEW"; do
  expect "$(basename "$app") declares the _porthole._tcp Bonjour service" "$(plist "$app" NSBonjourServices.0)" "_porthole._tcp"
done

AGENT="$HOST/Contents/Library/LaunchAgents/io.github.muhammademanaftab.porthole.watchdog.plist"
aplist() { plutil -extract "$1" raw -o - "$AGENT" 2>/dev/null || echo "<missing>"; }
if [ -f "$AGENT" ]; then pass "watchdog agent plist is bundled"; else fail "watchdog agent plist is bundled"; fi
if plutil -lint -s "$AGENT" >/dev/null 2>&1; then pass "watchdog agent plist is valid"; else fail "watchdog agent plist is valid"; fi
expect "watchdog agent label matches its file name" "$(aplist Label)" "io.github.muhammademanaftab.porthole.watchdog"
expect "watchdog agent runs the host binary" "$(aplist BundleProgram)" "Contents/MacOS/porthole-host"
if [ -x "$HOST/$(aplist BundleProgram)" ]; then pass "watchdog agent program exists in the bundle"; else fail "watchdog agent program exists in the bundle"; fi
expect "watchdog agent passes watchdog" "$(aplist ProgramArguments.1)" "watchdog"
expect "watchdog agent sets PORTHOLE_COMMAND=watchdog" "$(aplist EnvironmentVariables.PORTHOLE_COMMAND)" "watchdog"
expect "watchdog agent starts at login" "$(aplist RunAtLoad)" "true"
if "$HOST/Contents/MacOS/porthole-host" agent-plist 2>/dev/null | cmp -s - "$AGENT"; then
  pass "bundled agent plist matches what the host binary generates"
else fail "bundled agent plist matches what the host binary generates"; fi
if [ ! -e "$HOST/Contents/Library/LaunchAgents/io.github.muhammademanaftab.porthole.plist" ]; then pass "the old login agent plist is not bundled"; else fail "the old login agent plist is not bundled"; fi

for f in index.html porthole-core.js livekit-client.umd.min.js; do
  if [ -f "$WEB/$f" ]; then pass "web/$f is bundled"; else fail "web/$f is bundled"; fi
done
for f in tests package.json; do
  if [ -e "$WEB/$f" ]; then fail "web/$f is not bundled"; else pass "web/$f is not bundled"; fi
done
extra=$(find "$WEB" -mindepth 1 \( -type d -o -name '.*' -o ! \( -name index.html -o -name '*.js' -o -name '*.css' -o -name '*.png' -o -name '*.webmanifest' \) \) 2>/dev/null)
if [ -z "$extra" ]; then pass "web holds only servable files"; else fail "web holds only servable files: $extra"; fi

if [ -x "$HOST/Contents/MacOS/livekit-server" ]; then pass "livekit-server is executable"; else fail "livekit-server is executable"; fi
if codesign --verify --strict "$HOST/Contents/MacOS/livekit-server" 2>/dev/null; then pass "livekit-server signature"; else fail "livekit-server signature"; fi
TILE="$VIEW/Contents/Helpers/porthole-tile"
if [ -x "$TILE" ]; then pass "porthole-tile helper is executable"; else fail "porthole-tile helper is executable"; fi
if codesign --verify --strict "$TILE" 2>/dev/null; then pass "porthole-tile signature"; else fail "porthole-tile signature"; fi
if otool -L "$TILE" 2>/dev/null | tail -n +2 | grep -qv -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/Library/'; then
  fail "porthole-tile links only system libraries"
else pass "porthole-tile links only system libraries"; fi
"$TILE" >/dev/null 2>&1
expect "porthole-tile refuses to run without arguments" "$?" "2"

for app in "$HOST" "$VIEW"; do
  if codesign --verify --deep --strict "$app" 2>/dev/null; then pass "codesign --verify --deep --strict $app"; else fail "codesign --verify --deep --strict $app"; fi
done

if [ "$failures" -eq 0 ]; then echo; echo "Bundle checks passed."; else echo; echo "$failures bundle check(s) failed."; fi
[ "$failures" -eq 0 ]
