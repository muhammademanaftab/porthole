#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f scripts/deploy.local ] && . scripts/deploy.local
DEPLOY_HOST=${DEPLOY_HOST:-}
DEPLOY_USER=${DEPLOY_USER:-$(id -un)}
DEPLOY_KEY=${DEPLOY_KEY:-}
DEPLOY_SIGNER=${DEPLOY_SIGNER:-Porthole Dev}
LOCK=/tmp/porthole-build.lock
APP="Porthole.app"
DRY=0
BUILD=1
PRINT_REMOTE=0

usage() {
  cat <<EOF
usage: scripts/deploy.sh [--dry-run] [--no-build]
  Builds dist/$APP, copies it to /Applications on another Mac over SSH with
  Share this Mac on, starts it through its watchdog, waits for /hello, checks that
  the watchdog relaunches a killed host and prints porthole doctor from that Mac.
  Any failure before that rolls back. The steps run there under nohup
  (log: ~/porthole-deploy/deploy.log), so a dropped SSH connection doesn't stop them halfway.
  --print-remote  print the script that runs on the other Mac
  --dry-run   print every step without building, copying or connecting
  --no-build  install the dist/$APP that is already built
  Settings, from the environment or scripts/deploy.local:
    DEPLOY_HOST    the other Mac's name or address (required)
    DEPLOY_USER    its user (default: yours)
    DEPLOY_KEY     an SSH key file (default: ssh's own choice)
    DEPLOY_SIGNER  the signing identity a replacement must carry (default: Porthole Dev)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --print-remote) PRINT_REMOTE=1 ;;
    --dry-run) DRY=1 ;;
    --no-build) BUILD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "deploy: unknown option $arg" >&2; usage >&2; exit 2 ;;
  esac
done

SSH=(ssh ${DEPLOY_KEY:+-i "$DEPLOY_KEY"} -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 "$DEPLOY_USER@$DEPLOY_HOST")

RUN_REMOTE='cd ~/porthole-deploy && : > deploy.log || exit 1; nohup bash deploy.sh > deploy.log 2>&1 < /dev/null & pid=$!; tail -n +1 -f ~/porthole-deploy/deploy.log & t=$!; wait $pid; rc=$?; sleep 1; kill $t 2>/dev/null; exit $rc'

step() { echo "==> $*"; }
show() { printf '    %q' "$@"; echo; }
run() { if [ "$DRY" = 1 ]; then show "$@"; else "$@"; fi }

read -r -d '' REMOTE <<'REMOTE_SCRIPT' || true
set -euo pipefail
trap '' HUP PIPE
APP="/Applications/Porthole.app"
DEPLOY="$HOME/porthole-deploy"
NEW="$DEPLOY/new/Porthole.app"
BACK="$DEPLOY/rollback.tar"
PREV="$DEPLOY/previous.tar"
SUPPORT="$HOME/Library/Application Support/Porthole"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
LABEL=io.github.muhammademanaftab.porthole.watchdog
BUNDLE_ID=io.github.muhammademanaftab.porthole
SIGNER="__SIGNER__"
DOMAIN="gui/$(id -u)"
MARKER="$SUPPORT/exit-marker"
phase=check
forget() { "$LSREG" -u "$1" >/dev/null 2>&1 || true; }
hosts() { pgrep -f "^$APP/Contents/MacOS/porthole-host\$" || true; }
die() { echo "deploy: $*" >&2; exit 1; }
exe_of() { lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }
agent_pid() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '$1 == "pid" && $2 == "=" { print $3; exit }'; }
agent_program() { local p; p=$(agent_pid); [ -n "$p" ] || return 1; exe_of "$p"; }
app_watchdog() {
  local p
  for p in $(pgrep -f "porthole-host watchdog" || true); do
    [ "$(exe_of "$p")" = "$APP/Contents/MacOS/porthole-host" ] && { echo "$p"; return 0; }
  done
  return 1
}
dr() { codesign -d -r- "$1" 2>/dev/null | sed -n 's/^designated => //p'; }
authority() { codesign -dvv "$1" 2>&1 | sed -n 's/^Authority=//p' | head -1; }
stamp() { date +%Y%m%d-%H%M%S; }
rotate() {
  [ -f "$1" ] || return 0
  local base; base="${1%.tar}"
  mv -f "$1" "$base-$(stamp).tar"
  ls -1t "$base"-*.tar 2>/dev/null | tail -n +6 | while read -r f; do rm -f "$f"; done || true
}

[ -d "$NEW" ] || die "the copied bundle is missing; nothing was changed"
xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true
codesign --verify --deep --strict "$NEW" || die "the copied bundle fails codesign --verify; nothing was changed"
echo "signature ok"
[ "$(plutil -extract CFBundleIdentifier raw -o - "$NEW/Contents/Info.plist")" = "$BUNDLE_ID" ] || die "the copied bundle doesn't have the id $BUNDLE_ID; nothing was changed"
watched=0
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then watched=1; fi
echo "watchdog agent loaded: $watched"
had_app=0; [ -d "$APP" ] && had_app=1
echo "Porthole.app installed: $had_app"
installed=""
if [ "$had_app" = 1 ] && [ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ]; then installed="$APP"; fi
new_dr=$(dr "$NEW")
new_by=$(authority "$NEW")
[ -n "$new_dr" ] || die "could not read the copied bundle's designated requirement; nothing was changed"
if [ -z "$installed" ]; then
  echo "first install of $BUNDLE_ID, signed by ${new_by:-an ad hoc signature}"
elif [ "$new_dr" = "$(dr "$installed")" ]; then
  echo "designated requirement matches the installed Porthole.app"
elif [ "$new_by" = "$SIGNER" ]; then
  echo "signed by $SIGNER (the designated requirement differs from the installed Porthole.app)"
else
  die "the copied bundle is signed by '${new_by:-nobody}', not $SIGNER, and its designated requirement doesn't match the installed app's; nothing was changed"
fi
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
  echo "deploy: could not stop Porthole" >&2
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
  fi
  sleep 1
  [ -n "$(hosts)" ] || open "$app"
  wait_hello
}
hold_watchdog() { mkdir -p "$(dirname "$MARKER")"; printf quit > "$MARKER"; }
wait_watchdog() {
  local deadline=$((SECONDS + 150)) program dog
  while [ "$SECONDS" -lt "$deadline" ]; do
    program=$(agent_program || true)
    dog=$(app_watchdog || true)
    case "$program" in
      "$APP/"*) if [ -n "$dog" ]; then echo "watchdog agent runs $program (pid $dog) after $((150 - deadline + SECONDS))s"; return 0; fi ;;
    esac
    sleep 3
  done
  echo "deploy: after 150 s the watchdog agent runs '${program:-nothing}' and no watchdog from $APP is running" >&2
  return 1
}
crash_test() {
  local before now deadline
  before=$(hosts | head -1)
  [ -n "$before" ] || { echo "deploy: no Porthole from $APP to test the watchdog with" >&2; return 1; }
  echo "killing the host ($before) with SIGKILL to check that the watchdog relaunches it"
  kill -9 "$before"
  deadline=$((SECONDS + 20))
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 1
    now=$(hosts | head -1)
    if [ -n "$now" ] && [ "$now" != "$before" ] && curl -fsS -m 1 "http://127.0.0.1:$port/hello" >/dev/null 2>&1; then
      echo "the watchdog relaunched the host as $now, answering /hello"
      return 0
    fi
  done
  echo "deploy: the watchdog did not relaunch a host answering /hello within 20 s of the kill" >&2
  return 1
}
resume_old() {
  set +e
  trap - EXIT
  echo "deploy: nothing was installed; starting the previous app again" >&2
  rm -f "$MARKER"
  target=""
  if [ -d "$APP" ]; then target="$APP"; fi
  if [ -z "$target" ]; then echo "deploy: there was no previous app to start" >&2; exit 1; fi
  [ "$watched" = 1 ] && launchctl kickstart "$DOMAIN/$LABEL" >/dev/null 2>&1
  sleep 1
  [ -n "$(hosts)" ] || open "$target"
  if wait_hello; then echo "the previous $(basename "$target") is running again" >&2; else echo "deploy: the previous $(basename "$target") did not answer /hello" >&2; fi
  exit 1
}
restore() {
  set +e
  trap - EXIT ERR
  echo "deploy: rolling back to the previous app" >&2
  hold_watchdog
  stop_host
  hold_watchdog
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
  if [ -f "$BACK" ]; then
    rm -rf "$DEPLOY/restore"; mkdir -p "$DEPLOY/restore"
    if tar -C "$DEPLOY/restore" -xf "$BACK"; then
      if [ "$had_app" = 1 ]; then rsync -a --delete "$DEPLOY/restore/Porthole.app/" "$APP/" || echo "deploy: restoring $APP failed" >&2
      else forget "$APP"; rm -rf "$APP"; fi
      for a in "$DEPLOY/restore/"*.app; do forget "$a"; done
      rm -rf "$DEPLOY/restore"
    else
      echo "deploy: unpacking $BACK failed; starting whatever is installed" >&2
    fi
  else
    echo "deploy: no rollback copy; starting whatever is installed" >&2
  fi
  rm -f "$SUPPORT/watchdog-bundle"
  target=""
  if [ -d "$APP" ]; then target="$APP"; fi
  if [ -z "$target" ]; then echo "deploy: nothing is installed to start" >&2; exit 1; fi
  "$LSREG" -f "$target" >/dev/null 2>&1
  codesign --verify --deep --strict "$target" || echo "deploy: the restored bundle fails codesign --verify" >&2
  if start_app "$target" 0; then echo "rolled back to $(basename "$target")" >&2; else echo "deploy: the previous app did not answer either" >&2; fi
  exit 1
}
on_exit() {
  case "$phase" in
    stopped) resume_old ;;
    installing) restore ;;
  esac
}
trap on_exit EXIT
fail() { echo "deploy: $*" >&2; exit 1; }

mkdir -p "$DEPLOY"
rotate "$BACK"
saved=()
[ "$had_app" = 1 ] && saved+=("Porthole.app")
if [ "${#saved[@]}" -gt 0 ]; then
  tar -C /Applications -cf "$BACK.partial" "${saved[@]}" || { rm -f "$BACK.partial"; die "could not save a rollback copy; nothing was changed"; }
  mv -f "$BACK.partial" "$BACK"
  echo "rollback copy: $BACK (${saved[*]})"
fi
for stale in "$APP.rollback" "$APP.previous" "$DEPLOY/rollback/"*.app "$DEPLOY/previous/"*.app; do
  [ -e "$stale" ] || continue; forget "$stale"; rm -rf "$stale"
done

phase=stopped
hold_watchdog
stop_host || fail "could not stop Porthole"
hold_watchdog

phase=installing
mkdir -p "$APP"
rsync -a --delete "$NEW/" "$APP/"
codesign --verify --deep --strict "$APP"
forget "$NEW"
rm -rf "$DEPLOY/new"
"$LSREG" -f "$APP" >/dev/null 2>&1 || true
defaults write "$BUNDLE_ID" hosting -bool true
echo "Share this Mac: on"
start_app "$APP" "$watched" || fail "the new Porthole did not answer /hello within 60 s"
[ -n "$(hosts)" ] || fail "/hello answered, but not from $APP"
wait_watchdog || fail "the watchdog isn't running from $APP"
crash_test || fail "the watchdog from $APP doesn't relaunch the host"
sleep 3
n=$(hosts | grep -c . || true)
echo "Porthole instances running: $n"
[ "$n" = 1 ] || fail "expected exactly one Porthole, found $n"

phase=finishing
if [ -f "$BACK" ]; then rotate "$PREV"; mv -f "$BACK" "$PREV"; echo "previous app kept in $PREV"; fi
phase=done
echo
echo "watchdog agent program: $(agent_program || echo 'not running')"
"$APP/Contents/MacOS/porthole" doctor || true
REMOTE_SCRIPT

REMOTE=${REMOTE/__SIGNER__/$DEPLOY_SIGNER}

if [ "$PRINT_REMOTE" = 1 ]; then printf '%s\n' "$REMOTE"; exit 0; fi

if [ -z "$DEPLOY_HOST" ]; then echo "deploy: set DEPLOY_HOST (in the environment or scripts/deploy.local) to the Mac to install on." >&2; exit 2; fi

step "check that $DEPLOY_USER@$DEPLOY_HOST answers SSH"
if [ "$DRY" = 1 ]; then
  show "${SSH[@]}" true
else
  if ! "${SSH[@]}" true 2>/dev/null; then
    echo "deploy: $DEPLOY_HOST is offline or not answering SSH as $DEPLOY_USER. Nothing was built or changed." >&2
    exit 3
  fi
fi

if [ "$BUILD" = 1 ]; then
  step "build dist/$APP (release)"
  run /usr/bin/lockf "$LOCK" env SWIFT_JOBS="${SWIFT_JOBS:-3}" scripts/bundle.sh
fi
if [ "$DRY" = 0 ] && [ ! -d "dist/$APP" ]; then
  echo "deploy: dist/$APP is missing; run without --no-build" >&2
  exit 1
fi

step "copy dist/$APP to ~/porthole-deploy/new on $DEPLOY_HOST (tar over ssh)"
if [ "$DRY" = 1 ]; then
  show tar -C dist -czf - "$APP"
  echo "    | ssh ... 'rm -rf ~/porthole-deploy/new && mkdir -p ~/porthole-deploy/new && tar -C ~/porthole-deploy/new -xzf -'"
else
  tar -C dist -czf - "$APP" | "${SSH[@]}" 'rm -rf ~/porthole-deploy/new && mkdir -p ~/porthole-deploy/new && tar -C ~/porthole-deploy/new -xzf -'
fi

step "install into /Applications, restart through the watchdog, wait for /hello, run porthole doctor"
if [ "$DRY" = 1 ]; then
  show "${SSH[@]}" "cat > ~/porthole-deploy/deploy.sh"
  show "${SSH[@]}" "$RUN_REMOTE"
  echo "    remote script:"
  printf '%s\n' "$REMOTE" | sed 's/^/      | /'
  echo
  echo "dry run: nothing was built, copied or changed."
else
  printf '%s\n' "$REMOTE" | "${SSH[@]}" 'mkdir -p ~/porthole-deploy && cat > ~/porthole-deploy/deploy.sh'
  "${SSH[@]}" "$RUN_REMOTE"
fi
