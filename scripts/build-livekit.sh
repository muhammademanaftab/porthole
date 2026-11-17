#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=v1.13.11
COMMIT=385aa40f9292fe1db8caad87301e4b285b7c198a
SRC="$PWD/.build/livekit/src"
OUT="$PWD/.build/livekit/livekit-server"
if ! command -v go >/dev/null; then echo "go not found: brew install go" >&2; exit 1; fi
rm -rf "$SRC"
git clone --quiet --depth 1 --branch "$VERSION" https://github.com/livekit/livekit.git "$SRC" >&2
if [ "$(git -C "$SRC" rev-parse HEAD)" != "$COMMIT" ]; then
  echo "livekit $VERSION is no longer commit $COMMIT; not building it" >&2
  exit 1
fi
(cd "$SRC" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o "$OUT" ./cmd/server) >&2
echo "$OUT"
