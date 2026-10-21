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
#   USF_NOW               freezes "now" (epoch seconds) for hold-expiry tests
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
run_watch() { # run_watch <fg> <screen> <gamelist> [state] [hold] [now] [screenoff-mode]
  _fg=$1; _scr=$2; _games=$3; _state=${4:-}; _hold=${5:-}; _now=${6:-}; _soff=${7:-}
  mkdir -p "$TMP/cfg"
  printf '%s\n' "$_games" > "$TMP/cfg/gamelist.txt"
  rm -f "$TMP/cfg/watcher.state" "$TMP/cfg/manual_hold" "$TMP/cfg/watcher.screen_off"
  [ -n "$_state" ] && printf '%s\n' "$_state" > "$TMP/cfg/watcher.state"
  [ -n "$_hold" ] && printf '%s\n' "$_hold" > "$TMP/cfg/manual_hold"
  [ -n "$_soff" ] && printf '%s\n' "$_soff" > "$TMP/cfg/watcher.screen_off"
  USF_CONFIG_DIR="$TMP/cfg" \
  USF_FG_PACKAGE="$_fg" \
  USF_SCREEN_STATE="$_scr" \
  USF_WATCHER_DRYRUN=1 \
  USF_WATCHER_ONCE=1 \
  USF_NO_SPAWN=1 \
  USF_NOW="$_now" \
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

t_screenoff_default_powersave() {
  # no config file -> historic behaviour: screen off means powersave
  out=$(run_watch com.mobile.legends off "com.mobile.legends" performance)
  echo "$out" | grep -q 'profile=powersave' || { bad w-soff-default "got: $out"; return; }
  ok w-soff-default
}

t_screenoff_keep() {
  # user opted out: screen off must NOT change the profile at all
  out=$(run_watch com.mobile.legends off "com.mobile.legends" performance "" "" keep)
  echo "$out" | grep -q 'profile=powersave' && { bad w-soff-keep "still forced powersave: $out"; return; }
  echo "$out" | grep -q 'action=apply' && { bad w-soff-keep "applied something: $out"; return; }
  echo "$out" | grep -q 'action=skip' || { bad w-soff-keep "not skipped: $out"; return; }
  echo "$out" | grep -q 'screenoff=keep' || { bad w-soff-keep "mode not reported: $out"; return; }
  ok w-soff-keep
}

t_screenoff_balance() {
  # middle ground: screen off drops to balance instead of powersave
  out=$(run_watch com.mobile.legends off "com.mobile.legends" performance "" "" balance)
  echo "$out" | grep -q 'profile=balance' || { bad w-soff-bal "got: $out"; return; }
  echo "$out" | grep -q 'profile=powersave' && { bad w-soff-bal "still powersave: $out"; return; }
  ok w-soff-bal
}

t_screenoff_keep_respects_hold() {
  # keep mode + an active hold: nothing may be applied on screen off
  out=$(run_watch com.mobile.legends off "com.mobile.legends" performance \
        "1000000|com.mobile.legends" 1000005 keep)
  echo "$out" | grep -q 'action=apply' && { bad w-soff-hold "applied: $out"; return; }
  ok w-soff-hold
}

t_screen_state_is_cheap() {
  # screen detection must not shell out to dumpsys when a backlight node is
  # readable: that call is what made unlocking feel laggy
  grep -q 'backlight' "$WATCH" || { bad w-cheap "no backlight fast path"; return; }
  # dumpsys must appear AFTER the backlight attempt in the function body
  bl=$(grep -n 'backlight' "$WATCH" | head -n 1 | cut -d: -f1)
  ds=$(grep -n 'dumpsys power' "$WATCH" | head -n 1 | cut -d: -f1)
  [ -n "$bl" ] && [ -n "$ds" ] || { bad w-cheap "missing detection paths"; return; }
  [ "$bl" -lt "$ds" ] || { bad w-cheap "dumpsys still tried before backlight"; return; }
  ok w-cheap
}

t_screen_dim_not_mistaken_for_off() {
  # brightness 0 (dimmed / AOD) must be confirmed with the power service
  # before being treated as "screen off", otherwise the profile flips while
  # the user is still looking at the screen
  grep -q 'confirm_screen' "$WATCH" || { bad w-dim "no transition confirm"; return; }
  # and the confirm must not run on every poll: only on a state change
  grep -q 'LAST_SCREEN' "$WATCH" || { bad w-dim "no last-state cache"; return; }
  ok w-dim
}

t_unlock_wake_is_fast() {
  # while the screen is off the watcher must poll cheaply and often, so the
  # profile is already back by the time the lock screen lifts
  grep -q 'wait_screen_on' "$WATCH" || { bad w-wake "no wake fast-path"; return; }
  ok w-wake
}

t_manual_hold_same_app() {
  # user tapped a profile in the WebUI while this app was foreground:
  # the watcher must NOT stomp it, even though the decision is "balance"
  out=$(run_watch com.android.chrome on "com.mobile.legends" balance \
        "1000000|com.android.chrome" 1000005)
  echo "$out" | grep -q 'action=skip' || { bad w-hold "hold ignored: $out"; return; }
  echo "$out" | grep -q 'override' || { bad w-hold "no override log line: $out"; return; }
  ok w-hold
}

t_manual_hold_app_changed() {
  # hold belongs to another app -> override is released and auto resumes
  # (state says performance, decision is balance, so it must apply)
  out=$(run_watch com.android.chrome on "com.mobile.legends" performance \
        "1000000|com.mobile.legends" 1000005)
  echo "$out" | grep -q 'action=apply' || { bad w-hold-change "hold not released: $out"; return; }
  echo "$out" | grep -q 'profile=balance' || { bad w-hold-change "wrong profile: $out"; return; }
  [ -f "$TMP/cfg/manual_hold" ] && { bad w-hold-change "stale hold file kept"; return; }
  ok w-hold-change
}

t_manual_hold_expired() {
  # safety net: a stale hold must expire so a wedged fg detector cannot pin
  # a profile forever
  out=$(run_watch com.android.chrome on "com.mobile.legends" performance \
        "1000000|com.android.chrome" 1080001)
  echo "$out" | grep -q 'action=apply' || { bad w-hold-ttl "expired hold still honored: $out"; return; }
  [ -f "$TMP/cfg/manual_hold" ] && { bad w-hold-ttl "expired hold file kept"; return; }
  ok w-hold-ttl
}

t_manual_hold_home_screen() {
  # pick a profile, press Home: no foreground package must NOT release the
  # hold (that is the "tapped Max, went home, it flipped back" bug)
  out=$(run_watch "" on "com.mobile.legends" performance \
        "1000000|com.android.chrome" 1000005)
  echo "$out" | grep -q 'action=skip' || { bad w-hold-home "hold dropped on home screen: $out"; return; }
  [ -f "$TMP/cfg/manual_hold" ] || { bad w-hold-home "hold file removed"; return; }
  ok w-hold-home
}

t_manual_hold_survives_screen_off() {
  # screen off still wins over a hold: powersave is a safety behaviour
  out=$(run_watch com.android.chrome off "com.mobile.legends" balance \
        "1000000|com.android.chrome" 1000005)
  echo "$out" | grep -q 'profile=powersave' || { bad w-hold-off "screen-off ignored: $out"; return; }
  echo "$out" | grep -q 'action=apply' || { bad w-hold-off "powersave not applied: $out"; return; }
  ok w-hold-off
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
t_screenoff_default_powersave
t_screenoff_keep
t_screenoff_balance
t_screenoff_keep_respects_hold
t_screen_state_is_cheap
t_screen_dim_not_mistaken_for_off
t_unlock_wake_is_fast
t_manual_hold_same_app
t_manual_hold_app_changed
t_manual_hold_expired
t_manual_hold_home_screen
t_manual_hold_survives_screen_off

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
