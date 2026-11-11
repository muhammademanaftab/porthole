#!/bin/bash
set -euo pipefail
usage() { echo "usage: scripts/install-cli.sh [--dir DIR] [--uninstall]" >&2; exit 2; }
DIR=""
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || usage; DIR=$2; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) usage ;;
  esac
done
if [ -z "$DIR" ]; then
  if [ -d "$HOME/bin" ]; then DIR="$HOME/bin"
  elif [ -w /usr/local/bin ]; then DIR=/usr/local/bin
  else echo "No ~/bin and /usr/local/bin isn't writable; pass --dir DIR (a folder on your PATH)." >&2; exit 1; fi
fi
LINK="$DIR/porthole"
if [ "$UNINSTALL" = 1 ]; then
  if [ -L "$LINK" ]; then rm "$LINK"; echo "Removed $LINK"; else echo "$LINK isn't a symlink; left alone."; fi
  exit 0
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET=""
for c in "/Applications/Porthole.app/Contents/MacOS/porthole" "$ROOT/dist/Porthole.app/Contents/MacOS/porthole"; do
  if [ -x "$c" ]; then TARGET=$c; break; fi
done
if [ -z "$TARGET" ]; then echo "No porthole binary found in /Applications or dist/; run scripts/bundle.sh first." >&2; exit 1; fi
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then echo "$LINK exists and isn't a symlink; not replacing it." >&2; exit 1; fi
mkdir -p "$DIR"
ln -sfn "$TARGET" "$LINK"
echo "$LINK -> $TARGET"
case ":$PATH:" in *":$DIR:"*) ;; *) echo "Note: $DIR isn't on your PATH." ;; esac
