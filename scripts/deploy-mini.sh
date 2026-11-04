#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

MINI_HOST=${MINI_HOST:-100.101.102.103}
MINI_USER=${MINI_USER:-user}
MINI_KEY=${MINI_KEY:-$HOME/.ssh/id_ed25519}
LOCK=/tmp/porthole-build.lock
APP="Porthole.app"
DRY=0
BUILD=1

usage() {
  cat <<EOF
usage: scripts/deploy-mini.sh [--dry-run] [--no-build]
  Builds dist/$APP (SWIFT_JOBS=3, under $LOCK), copies it to /Applications on
  $MINI_USER@$MINI_HOST with Share this Mac on, starts it (through its watchdog, or
  in place of an old Porthole Host.app, whose watchdog it takes over), waits for /hello,
  removes the old Porthole Host.app and prints porthole doctor from the mini.
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
APP="/Applications/Porthole.app"
OLD="/Applications/Porthole Host.app"
NEW="$HOME/porthole-deploy/new/Porthole.app"
BACK="$HOME/porthole-deploy/rollback.tar"
PREV="$HOME/porthole-deploy/previous.tar"
SUPPORT="$HOME/Library/Application Support/Porthole"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
forget() { "$LSREG" -u "$1" >/dev/null 2>&1 || true; }
LABEL=io.github.muhammademanaftab.porthole.watchdog
BUNDLE_ID=io.github.muhammademanaftab.porthole
DOMAIN="gui/$(id -u)"
hosts() { pgrep -f "/Applications/Porthole( Host)?\.app/Contents/MacOS/porthole-host\$" || true; }
new_hosts() { pgrep -f "^$APP/Contents/MacOS/porthole-host\$" || true; }
die() { echo "deploy-mini: $*" >&2; exit 1; }
[ -d "$NEW" ] || die "the copied bundle is missing on the mini"
xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true
codesign --verify --deep --strict "$NEW" || die "the copied bundle fails codesign --verify; nothing was changed"
echo "signature ok"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$NEW/Contents/Info.plist")" = "$BUNDLE_ID" ] || die "the copied bundle doesn't have the id $BUNDLE_ID; nothing was changed"
watched=0
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then watched=1; fi
echo "watchdog agent loaded: $watched"
had_old=0; [ -d "$OLD" ] && had_old=1
had_app=0; [ -d "$APP" ] && had_app=1
echo "old Porthole Host.app installed: $had_old; Porthole.app installed: $had_app"
port=$(plutil -extract httpPort raw -o - "$SUPPORT/config.json" 2>/dev/null || echo 7878)
livekits() { pgrep -f "livekit-server --config $SUPPORT/livekit.yaml" || true; }
stop_livekit() {
  [ -n "$(livekits)" ] || return 0
  echo "stopping leftover livekit-server ($(livekits | tr '\n' ' '))"
  for pid in $(livekits); do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 20); do [ -z "$(livekits)" ] && return 0; sleep 0.25; done
  for pid in $(livekits); do kill -KILL "$pid" 2>/dev/null || true; done
}
stop_host() {
  stop_host_only || return 1
  stop_livekit
}
stop_host_only() {
  [ -n "$(hosts)" ] || return 0
  echo "quitting the running Porthole ($(hosts | tr '\n' ' '))"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do [ -z "$(hosts)" ] && return 0; sleep 0.25; done
  for pid in $(hosts); do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 20); do [ -z "$(hosts)" ] && return 0; sleep 0.25; done
  echo "Porthole ignored SIGTERM; killing it"
  for pid in $(hosts); do kill -KILL "$pid" 2>/dev/null || true; done
  for _ in $(seq 1 20); do [ -z "$(hosts)" ] && return 0; sleep 0.25; done
  echo "deploy-mini: could not stop Porthole" >&2
  return 1
}
wait_hello() {
  for i in $(seq 1 60); do
    if curl -fsS -m 2 "http://127.0.0.1:$port/hello" >/dev/null 2>&1; then echo "/hello answered after ${i}s"; return 0; fi
    sleep 1
  done
  return 1
}
start_app() {
  local app=$1 kick=$2
  if [ "$kick" = 1 ]; then
    echo "restarting the watchdog agent with the installed binary"
    launchctl kickstart -k "$DOMAIN/$LABEL" || true
  else
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 && echo "booted out the old app's watchdog agent; $(basename "$app") registers its own" || true
  fi
  sleep 1
  [ -n "$(hosts)" ] || open "$app"
  wait_hello
}
MARKER="$SUPPORT/exit-marker"
hold_watchdog() { mkdir -p "$(dirname "$MARKER")"; printf quit > "$MARKER"; }
old_pids=" $(hosts | tr '\n' ' ')"
restore() {
  trap - ERR
  echo "deploy-mini: rolling back to the previous apps" >&2
  [ -f "$BACK" ] || { echo "deploy-mini: no rollback copy; Porthole is left as it is" >&2; exit 1; }
  hold_watchdog
  stop_host || true
  hold_watchdog
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -rf "$HOME/porthole-deploy/restore"; mkdir -p "$HOME/porthole-deploy/restore"
  if tar -C "$HOME/porthole-deploy/restore" -xf "$BACK"; then
    if [ "$had_app" = 1 ]; then rsync -a --delete "$HOME/porthole-deploy/restore/Porthole.app/" "$APP/"; else forget "$APP"; rm -rf "$APP"; fi
    if [ "$had_old" = 1 ]; then mkdir -p "$OLD"; rsync -a --delete "$HOME/porthole-deploy/restore/Porthole Host.app/" "$OLD/"; fi
    for a in "$HOME/porthole-deploy/restore/"*.app; do forget "$a"; done
    rm -rf "$HOME/porthole-deploy/restore"
    rm -f "$SUPPORT/watchdog-bundle"
    target="$APP"; [ "$had_old" = 1 ] && target="$OLD"
    [ -d "$target" ] || { echo "deploy-mini: nothing to roll back to" >&2; exit 1; }
    "$LSREG" -f "$target" >/dev/null 2>&1 || true
    codesign --verify --deep --strict "$target" || echo "deploy-mini: the restored bundle fails codesign --verify" >&2
    if start_app "$target" 0; then echo "rolled back to $(basename "$target")" >&2; else echo "the previous app did not answer either" >&2; fi
  else
    echo "deploy-mini: restoring failed; the previous bundles are kept in $BACK" >&2
  fi
  exit 1
}
hold_watchdog
stop_host || die "could not stop Porthole; nothing was changed"
hold_watchdog
for stale in "$APP.rollback" "$APP.previous" "$OLD.rollback" "$OLD.previous" "$HOME/porthole-deploy/rollback/"*.app "$HOME/porthole-deploy/previous/"*.app; do
  [ -e "$stale" ] || continue; forget "$stale"; rm -rf "$stale"
done
rm -f "$BACK"
saved=()
[ "$had_old" = 1 ] && saved+=("Porthole Host.app")
[ "$had_app" = 1 ] && saved+=("Porthole.app")
if [ "${#saved[@]}" -gt 0 ]; then tar -C /Applications -cf "$BACK" "${saved[@]}"; fi
trap restore ERR
mkdir -p "$APP"
rsync -a --delete "$NEW/" "$APP/"
codesign --verify --deep --strict "$APP"
forget "$NEW"
rm -rf "$HOME/porthole-deploy/new"
"$LSREG" -f "$APP" >/dev/null 2>&1 || true
defaults write "$BUNDLE_ID" hosting -bool true
echo "Share this Mac: on"
kick=$watched; [ "$had_old" = 1 ] && kick=0
start_app "$APP" "$kick" || { echo "deploy-mini: the new Porthole did not answer /hello within 60 s" >&2; restore; }
[ -n "$(new_hosts)" ] || { echo "deploy-mini: /hello answered, but not from $APP" >&2; restore; }
trap - ERR
for p in $(hosts); do case "$old_pids" in *" $p "*) echo "deploy-mini: the old Porthole ($p) is still the one running" >&2; restore ;; esac; done
if [ "$had_old" = 1 ]; then
  echo "removing the old $OLD"
  forget "$OLD"
  rm -rf "$OLD"
fi
sleep 8
n=$(hosts | grep -c . || true)
echo "Porthole instances running: $n"
[ "$n" = 1 ] || die "expected exactly one Porthole, found $n (the previous apps are kept as $BACK)"
if launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "$APP/"; then echo "watchdog agent runs from $APP"; else echo "deploy-mini: warning: the watchdog agent isn't running from $APP yet (it retries for a minute); check porthole doctor" >&2; fi
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
