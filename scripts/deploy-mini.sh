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
BACK="$HOME/porthole-deploy/rollback.tar"
PREV="$HOME/porthole-deploy/previous.tar"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
forget() { "$LSREG" -u "$1" >/dev/null 2>&1 || true; }
LABEL=io.github.muhammademanaftab.porthole.watchdog
DOMAIN="gui/$(id -u)"
hosts() { pgrep -f "Porthole Host.app/Contents/MacOS/porthole-host\$" || true; }
die() { echo "deploy-mini: $*" >&2; exit 1; }
[ -d "$NEW" ] || die "the copied bundle is missing on the mini"
xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true
codesign --verify --deep --strict "$NEW" || die "the copied bundle fails codesign --verify; nothing was changed"
echo "signature ok"
watched=0
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then watched=1; fi
echo "watchdog agent loaded: $watched"
port=$(plutil -extract httpPort raw -o - "$HOME/Library/Application Support/Porthole/config.json" 2>/dev/null || echo 7878)
livekits() { pgrep -f "livekit-server --config $HOME/Library/Application Support/Porthole/livekit.yaml" || true; }
stop_livekit() {
  [ -n "$(livekits)" ] || return 0
  echo "stopping leftover livekit-server ($(livekits | tr '\n' ' '))"
  for pid in $(livekits); do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 20); do [ -z "$(livekits)" ] && return 0; sleep 0.25; done
  for pid in $(livekits); do kill -KILL "$pid" 2>/dev/null || true; done
}
stop_host() {
  stop_host_only
  stop_livekit
}
stop_host_only() {
  [ -n "$(hosts)" ] || return 0
  echo "quitting the running Porthole Host ($(hosts | tr '\n' ' '))"
  osascript -e 'tell application id "io.github.muhammademanaftab.porthole" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do [ -z "$(hosts)" ] && return 0; sleep 0.25; done
  for pid in $(hosts); do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 20); do [ -z "$(hosts)" ] && return 0; sleep 0.25; done
  echo "Porthole Host ignored SIGTERM; killing it"
  for pid in $(hosts); do kill -KILL "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 20); do [ -z "$(hosts)" ] && return 0; sleep 0.25; done
  die "could not stop Porthole Host"
}
start_host() {
  if [ "$watched" = 1 ]; then
    echo "restarting the watchdog agent with the installed binary"
    launchctl kickstart -k "$DOMAIN/$LABEL"
  fi
  sleep 1
  [ -n "$(hosts)" ] || open "$APP"
  for i in $(seq 1 60); do
    if curl -fsS -m 2 "http://127.0.0.1:$port/hello" >/dev/null 2>&1; then echo "/hello answered after ${i}s"; return 0; fi
    sleep 1
  done
  return 1
}
stop_host
for stale in "$APP.rollback" "$APP.previous" "$HOME/porthole-deploy/rollback/Porthole Host.app" "$HOME/porthole-deploy/previous/Porthole Host.app"; do forget "$stale"; rm -rf "$stale"; done
rm -f "$BACK"
if [ -d "$APP" ]; then tar -C /Applications -cf "$BACK" "Porthole Host.app"; fi
mkdir -p "$APP"
rsync -a --delete "$NEW/" "$APP/"
forget "$NEW"
rm -rf "$HOME/porthole-deploy/new"
"$LSREG" -f "$APP" >/dev/null 2>&1 || true
if ! start_host; then
  echo "deploy-mini: the new Porthole Host did not answer /hello within 60 s; rolling back" >&2
  if [ -f "$BACK" ]; then
    stop_host
    rm -rf "$HOME/porthole-deploy/restore"; mkdir -p "$HOME/porthole-deploy/restore"
    tar -C "$HOME/porthole-deploy/restore" -xf "$BACK"
    rsync -a --delete "$HOME/porthole-deploy/restore/Porthole Host.app/" "$APP/"
    forget "$HOME/porthole-deploy/restore/Porthole Host.app"
    rm -rf "$HOME/porthole-deploy/restore" "$BACK"
    if start_host; then echo "rolled back to the previous Porthole Host" >&2; else echo "the previous Porthole Host did not answer either" >&2; fi
  fi
  exit 1
fi
sleep 3
n=$(hosts | grep -c . || true)
echo "Porthole Host instances running: $n"
[ "$n" = 1 ] || die "expected exactly one Porthole Host, found $n (the previous one is kept as $BACK)"
if [ -f "$BACK" ]; then mv -f "$BACK" "$PREV"; fi
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
