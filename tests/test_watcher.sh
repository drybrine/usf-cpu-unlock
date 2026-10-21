#!/bin/sh
# Host-side tests for module/scripts/usf_watcher.sh (DRYRUN/one-shot mode).
#
# The watcher replaces Encore's `encored` C daemon: it polls the foreground
# package and switches profiles (game -> performance, else -> balance,
# screen off -> powersave). On the host everything device-specific is
# injected through env hooks so the decision logic is fully testable:
#   USF_FG_PACKAGE     overrides foreground-package detection
#   USF_SCREEN_STATE   overrides screen state (on|off)
#   USF_WATCHER_DRYRUN=1  print the chosen profile instead of applying it
#   USF_WATCHER_ONCE=1    run exactly one iteration
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WATCH=$ROOT/module/scripts/usf_watcher.sh
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# run_watch <fg-package> <screen> <gamelist-content> [state-file]
run_watch() {
  _fg=$1; _scr=$2; _games=$3; _state=${4:-}
  mkdir -p "$TMP/cfg"
  printf '%s\n' "$_games" > "$TMP/cfg/gamelist.txt"
  rm -f "$TMP/cfg/watcher.state"
  [ -n "$_state" ] && printf '%s\n' "$_state" > "$TMP/cfg/watcher.state"
  USF_CONFIG_DIR="$TMP/cfg" \
  USF_FG_PACKAGE="$_fg" \
  USF_SCREEN_STATE="$_scr" \
  USF_WATCHER_DRYRUN=1 \
  USF_WATCHER_ONCE=1 \
  USF_NO_SPAWN=1 \
    sh "$WATCH" 2>&1
}

t_choose_performance() {
  out=$(run_watch com.mobile.legends on "com.mobile.legends
com.garena.game.codm")
  echo "$out" | grep -q 'profile=performance' || { bad w-perf "got: $out"; return; }
  ok w-perf
}

t_choose_balance() {
  out=$(run_watch com.android.chrome on "com.mobile.legends")
  echo "$out" | grep -q 'profile=balance' || { bad w-bal "got: $out"; return; }
  ok w-bal
}

t_choose_powersave() {
  # screen off -> powersave regardless of foreground app
  out=$(run_watch com.mobile.legends off "com.mobile.legends")
  echo "$out" | grep -q 'profile=powersave' || { bad w-ps "got: $out"; return; }
  ok w-ps
}

t_exact_package_match() {
  # com.mobile.legends must NOT match com.mobile.legends2
  out=$(run_watch com.mobile.legends2 on "com.mobile.legends")
  echo "$out" | grep -q 'profile=balance' || { bad w-exact "prefix match leaked: $out"; return; }
  ok w-exact
}

t_no_duplicate_apply() {
  # state says performance already applied and app is a game -> no re-apply
  out=$(run_watch com.mobile.legends on "com.mobile.legends" performance)
  echo "$out" | grep -q 'action=skip' || { bad w-skip "expected skip: $out"; return; }
  ok w-skip
}

t_state_change_applies() {
  # state says balance, game starts -> apply
  out=$(run_watch com.mobile.legends on "com.mobile.legends" balance)
  echo "$out" | grep -q 'action=apply' || { bad w-apply "expected apply: $out"; return; }
  ok w-apply
}

t_missing_gamelist() {
  # no gamelist file at all -> must not crash, must pick balance
  mkdir -p "$TMP/nocfg"
  out=$(USF_CONFIG_DIR="$TMP/nocfg" USF_FG_PACKAGE=com.foo USF_SCREEN_STATE=on \
        USF_WATCHER_DRYRUN=1 USF_WATCHER_ONCE=1 USF_NO_SPAWN=1 sh "$WATCH" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { bad w-nolist "exit $rc"; return; }
  echo "$out" | grep -q 'profile=balance' || { bad w-nolist "got: $out"; return; }
  ok w-nolist
}

t_comments_and_blanks_ignored() {
  out=$(run_watch com.mobile.legends on "# a comment

com.mobile.legends
   ")
  echo "$out" | grep -q 'profile=performance' || { bad w-comments "got: $out"; return; }
  ok w-comments
}

t_unknown_fg() {
  # empty foreground package (launcher/system) -> balance, no crash
  out=$(run_watch "" on "com.mobile.legends")
  echo "$out" | grep -q 'profile=balance' || { bad w-empty "got: $out"; return; }
  ok w-empty
}

t_disabled_flag() {
  # watcher disabled marker -> exits immediately, applies nothing
  mkdir -p "$TMP/dis"
  printf 'com.mobile.legends\n' > "$TMP/dis/gamelist.txt"
  : > "$TMP/dis/watcher.disabled"
  out=$(USF_CONFIG_DIR="$TMP/dis" USF_FG_PACKAGE=com.mobile.legends USF_SCREEN_STATE=on \
        USF_WATCHER_DRYRUN=1 USF_WATCHER_ONCE=1 USF_NO_SPAWN=1 sh "$WATCH" 2>&1)
  echo "$out" | grep -q 'disabled' || { bad w-disabled "got: $out"; return; }
  echo "$out" | grep -q 'action=apply' && { bad w-disabled "applied while disabled"; return; }
  ok w-disabled
}

t_choose_performance
t_choose_balance
t_choose_powersave
t_exact_package_match
t_no_duplicate_apply
t_state_change_applies
t_missing_gamelist
t_comments_and_blanks_ignored
t_unknown_fg
t_disabled_flag

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
