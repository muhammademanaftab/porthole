#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Porthole.app"
if [ ! -d "$APP" ]; then echo "$APP not found; run scripts/bundle.sh first" >&2; exit 2; fi
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
MIN=$(plutil -extract LSMinimumSystemVersion raw -o - "$APP/Contents/Info.plist")

too_new=0
while IFS= read -r -d '' f; do
  for v in $(vtool -show-build "$f" 2>/dev/null | awk '$1 == "minos" { print $2 }'); do
    if [ "$(printf '%s\n%s\n' "$v" "$MIN" | sort -V | tail -1)" != "$MIN" ]; then
      echo "${f#"$APP"/} needs macOS $v, but the app says it runs on macOS $MIN" >&2
      too_new=1
    fi
  done
done < <(find "$APP" -type f -perm -u+x -print0)
if [ "$too_new" = 1 ]; then
  echo "Not packaged. A livekit-server from Homebrew is built for the macOS it was installed on; build one that runs on older versions with scripts/build-livekit.sh and pass its path as LIVEKIT_SERVER to scripts/bundle.sh." >&2
  exit 1
fi

NAME="Porthole-$VERSION.zip"
rm -f "dist/$NAME" "dist/$NAME.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$NAME"
(cd dist && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "Packaged: dist/$NAME (runs on macOS $MIN and later)"
cat "dist/$NAME.sha256"
