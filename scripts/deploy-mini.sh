#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MINI_HOST=${MINI_HOST:-100.101.102.103}
MINI_USER=${MINI_USER:-user}
MINI_KEY=${MINI_KEY:-$HOME/.ssh/id_ed25519}
LOCK=/tmp/porthole-build.lock
APP="Porthole Host.app"
DRY=0
BUILD=1

usage() {
  cat <<EOF
usage: scripts/deploy-mini.sh [--dry-run] [--no-build]
  Builds dist/$APP (SWIFT_JOBS=3, under $LOCK), copies it to /Applications on
  $MINI_USER@$MINI_HOST, restarts Porthole Host through its watchdog, waits for /hello
  and prints porthole doctor from the mini.
  --dry-run   print every step without building, copying or contacting the mini
  --no-build  install the dist/$APP that is already built
  MINI_HOST, MINI_USER and MINI_KEY override the target.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --no-build) BUILD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "deploy-mini: unknown option $arg" >&2; usage >&2; exit 2 ;;
  esac
done

SSH=(ssh -i "$MINI_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 "$MINI_USER@$MINI_HOST")

step() { echo "==> $*"; }
show() { printf '    %q' "$@"; echo; }
run() { if [ "$DRY" = 1 ]; then show "$@"; else "$@"; fi }

read -r -d '' REMOTE <<'REMOTE_SCRIPT' || true
set -euo pipefail
APP="/Applications/Porthole Host.app"
NEW="$HOME/porthole-deploy/new/Porthole Host.app"
LABEL=io.github.muhammademanaftab.porthole.watchdog
DOMAIN="gui/$(id -u)"
hosts() { pgrep -f "Porthole Host.app/Contents/MacOS/porthole-host\$" || true; }
[ -d "$NEW" ] || { echo "deploy-mini: the copied bundle is missing on the mini" >&2; exit 1; }
watched=0
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then watched=1; fi
echo "watchdog agent loaded: $watched"
if [ -n "$(hosts)" ]; then
  echo "quitting the running Porthole Host ($(hosts | tr '\n' ' '))"
  osascript -e 'tell application id "io.github.muhammademanaftab.porthole" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do [ -z "$(hosts)" ] && break; sleep 0.25; done
  for pid in $(hosts); do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 20); do [ -z "$(hosts)" ] && break; sleep 0.25; done
fi
rm -rf "$APP.previous"
[ -d "$APP" ] && mv "$APP" "$APP.previous"
mv "$NEW" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP" && echo "signature ok"
if [ "$watched" = 1 ]; then
  echo "restarting the watchdog agent with the new binary"
  launchctl kickstart -k "$DOMAIN/$LABEL"
fi
sleep 1
[ -n "$(hosts)" ] || open "$APP"
port=$(plutil -extract httpPort raw -o - "$HOME/Library/Application Support/Porthole/config.json" 2>/dev/null || echo 7878)
for i in $(seq 1 60); do
  if curl -fsS -m 2 "http://127.0.0.1:$port/hello" >/dev/null 2>&1; then echo "/hello answered after ${i}s"; break; fi
  sleep 1
  [ "$i" = 60 ] && { echo "deploy-mini: Porthole Host did not answer /hello within 60 s" >&2; exit 1; }
done
sleep 3
n=$(hosts | grep -c . || true)
echo "Porthole Host instances running: $n"
[ "$n" = 1 ] || { echo "deploy-mini: expected exactly one Porthole Host, found $n" >&2; exit 1; }
rm -rf "$HOME/porthole-deploy/new"
echo
"$APP/Contents/MacOS/porthole" doctor || true
REMOTE_SCRIPT

step "check that the mini answers SSH ($MINI_USER@$MINI_HOST)"
if [ "$DRY" = 1 ]; then
  show "${SSH[@]}" true
else
  if ! "${SSH[@]}" true 2>/dev/null; then
    echo "deploy-mini: the Mac mini ($MINI_HOST) is offline or not answering SSH with $MINI_KEY. Nothing was built or changed." >&2
    exit 3
  fi
fi

if [ "$BUILD" = 1 ]; then
  step "build dist/$APP (release, SWIFT_JOBS=3, under $LOCK)"
  run /usr/bin/lockf "$LOCK" env SWIFT_JOBS=3 scripts/bundle.sh
fi
if [ "$DRY" = 0 ] && [ ! -d "dist/$APP" ]; then
  echo "deploy-mini: dist/$APP is missing; run without --no-build" >&2
  exit 1
fi

step "copy dist/$APP to ~/porthole-deploy/new on the mini (tar over ssh)"
if [ "$DRY" = 1 ]; then
  show tar -C dist -czf - "$APP"
  echo "    | ssh ... 'rm -rf ~/porthole-deploy/new && mkdir -p ~/porthole-deploy/new && tar -C ~/porthole-deploy/new -xzf -'"
else
  tar -C dist -czf - "$APP" | "${SSH[@]}" 'rm -rf ~/porthole-deploy/new && mkdir -p ~/porthole-deploy/new && tar -C ~/porthole-deploy/new -xzf -'
fi

step "install into /Applications, restart through the watchdog, wait for /hello, run porthole doctor"
if [ "$DRY" = 1 ]; then
  show "${SSH[@]}" bash -s
  echo "    remote script:"
  printf '%s\n' "$REMOTE" | sed 's/^/      | /'
  echo
  echo "dry run: nothing was built, copied or changed."
else
  printf '%s\n' "$REMOTE" | "${SSH[@]}" bash -s
fi
