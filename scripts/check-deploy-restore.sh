#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/.."
REMOTE=$(scripts/deploy-mini.sh --print-remote)
FUNCS=$(printf '%s\n' "$REMOTE" | awk '
  /^[a-z_]+\(\) \{.*\}[[:space:]]*$/ { print; next }
  /^[a-z_]+\(\) \{/ { inside = 1 }
  inside { print }
  inside && /^\}/ { inside = 0 }')
failures=0
scenario() {
  local name=$1 fn=$2 expect=$3 stubs=$4
  local out
  out=$(bash -c '
    set -euo pipefail
    APP=/nowhere/Porthole.app; OLD="/nowhere/Porthole Host.app"; DEPLOY=/nowhere/deploy; NEW=$DEPLOY/new/Porthole.app
    BACK=$DEPLOY/rollback.tar; SUPPORT=/nowhere/support; MARKER=/dev/null; LSREG=lsreg
    LABEL=x; BUNDLE_ID=x; DOMAIN=gui/0; port=1; watched=1; had_old=1; had_app=1
    lsreg() { return 1; }
    sleep() { :; }
    rm() { return 1; }
    mkdir() { return 1; }
    rsync() { return 1; }
    tar() { return 1; }
    launchctl() { return 1; }
    osascript() { return 1; }
    codesign() { return 1; }
    curl() { return 1; }
    kill() { return 1; }
    pgrep() { return 1; }
    open() { echo "OPENED $*"; return 1; }
    test() { builtin test "$@"; }
    '"$4"'
    '"$FUNCS"'
    '"$2"'
    echo "REACHED THE END"
  ' 2>&1; echo "STATUS $?")
  if grep -qF -- "$expect" <<<"$out" && ! grep -q "REACHED THE END" <<<"$out" && ! grep -q "^STATUS 0$" <<<"$out"; then echo "PASS  $name"
  else echo "FAIL  $name"; echo "$out" | sed 's/^/      /' | tail -15; failures=$((failures + 1)); fi
}
dirs_exist='[() { case "$*" in *"-d /nowhere/Porthole Host.app"*|*"-d /nowhere/Porthole.app"*|*"-f /nowhere/deploy/rollback.tar"*) return 0 ;; esac; builtin [ "$@"; }'
scenario "restore: every step failing still opens the old Porthole Host.app" restore "OPENED /nowhere/Porthole Host.app" "$dirs_exist"
scenario "restore: no rollback tar still opens what is installed" restore "OPENED /nowhere/Porthole Host.app" '[() { case "$*" in *"-f /nowhere/deploy/rollback.tar"*) return 1 ;; *"-d /nowhere/Porthole Host.app"*) return 0 ;; esac; builtin [ "$@"; }'
scenario "restore: with only Porthole.app it opens that" restore "OPENED /nowhere/Porthole.app" 'had_old=0; [() { case "$*" in *"-d /nowhere/Porthole.app"*|*"-f /nowhere/deploy/rollback.tar"*) return 0 ;; esac; builtin [ "$@"; }'
scenario "restore: exits non-zero after starting the app" 'restore; echo unreachable' "did not answer either" "$dirs_exist"
scenario "restore: a host that won't stop still gets to the start step" restore "the previous app did not answer either" "$dirs_exist; pgrep() { echo 4242; }"
scenario "untouched: a failed stop still starts the old app again" resume_old "OPENED /nowhere/Porthole Host.app" "$dirs_exist"
scenario "exit trap: a failure while installing rolls back" 'phase=installing; trap on_exit EXIT; false' "OPENED /nowhere/Porthole Host.app" "$dirs_exist"
scenario "exit trap: a failure after stopping restarts the old app" 'phase=stopped; trap on_exit EXIT; false' "OPENED /nowhere/Porthole Host.app" "$dirs_exist"
scenario "exit trap: a failed check changes nothing" 'phase=check; trap on_exit EXIT; die "bad signature"' "bad signature" "$dirs_exist"
[ "$failures" = 0 ] && echo "All deploy rollback checks passed." || { echo "$failures deploy rollback check(s) failed"; exit 1; }
