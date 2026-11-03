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
for app in "$HOST" "$VIEW"; do
  if codesign --verify --deep --strict "$app" 2>/dev/null; then pass "codesign --verify --deep --strict $app"; else fail "codesign --verify --deep --strict $app"; fi
done

if [ "$failures" -eq 0 ]; then echo; echo "Bundle checks passed."; else echo; echo "$failures bundle check(s) failed."; fi
[ "$failures" -eq 0 ]
