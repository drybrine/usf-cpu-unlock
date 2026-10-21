#!/bin/sh
# Host-side tests for module/patch_xml.awk and module/verify_xml.awk.
# POSIX sh + awk; run: sh tests/run_tests.sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MOD=$ROOT/module
FIX=$ROOT/tests/fixtures
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

count_tc() { grep -o '<temp_config' "$1" | wc -l | tr -d ' '; }

t_common() { # t_common <name> <fixture> — returns 1 on failure
  name=$1
  fx=$FIX/$2
  awk -f "$MOD/patch_xml.awk" "$fx" > "$TMP/out" 2> "$TMP/err" \
    || { bad "$name" "patcher exited nonzero: $(cat "$TMP/err")"; return 1; }
  awk -f "$MOD/verify_xml.awk" "$TMP/out" 2>> "$TMP/err" \
    || { bad "$name" "verifier rejected patched output: $(cat "$TMP/err")"; return 1; }
  [ "$(count_tc "$fx")" = "$(count_tc "$TMP/out")" ] \
    || { bad "$name" "temp_config count changed"; return 1; }
  grep -q 'clusterCpu0="[1-9]' "$TMP/out" && { bad "$name" "clusterCpu0 not zeroed"; return 1; }
  grep -q 'clusterCpu1="[1-9]' "$TMP/out" && { bad "$name" "clusterCpu1 not zeroed"; return 1; }
  grep -q 'clusterCpu2="[1-9]' "$TMP/out" && { bad "$name" "clusterCpu2 not zeroed"; return 1; }
  # (nonzero cpu inside temp_config is enforced by verify_xml.awk; the decoy
  #  element legitimately keeps cpu="7", so no broad cpu= grep here)
  grep -q 'cpu="0"' "$TMP/out" || { bad "$name" "zeroed cpu attribute missing"; return 1; }
  grep -q 'clusterCpu0="0"' "$TMP/out" || { bad "$name" "zeroed clusterCpu0 missing"; return 1; }
  grep -q 'decoy_element cpu="7"' "$TMP/out" || { bad "$name" "decoy cpu attribute was modified"; return 1; }
  grep -q 'cpu_enable="true"' "$TMP/out" || { bad "$name" "cpu_enable was modified"; return 1; }
  grep -q 'cluster0_percent="100"' "$TMP/out" || { bad "$name" "cpu_level percents were modified"; return 1; }
  ok "$name"
}

t_pretty()   { t_common pretty pretty.xml; }
t_minified() { t_common minified minified.xml; }
t_partial() {
  if ! t_common partial partial.xml; then return; fi
  # spaced and single-quoted forms must be normalized away
  grep -q 'cpu = "' "$TMP/out" && { bad partial 'spaced cpu="..." survived'; return; }
  grep -q "clusterCpu0='" "$TMP/out" && { bad partial "single-quoted clusterCpu0 survived"; return; }
  grep -q "cpu='" "$TMP/out" && { bad partial "single-quoted cpu survived"; return; }
  ok partial-normalization
}
t_crlf() {
  sed 's/$/\r/' "$FIX/pretty.xml" > "$TMP/crlf.xml"
  awk -f "$MOD/patch_xml.awk" "$TMP/crlf.xml" > "$TMP/out" 2> "$TMP/err" \
    || { bad crlf "patcher exited nonzero"; return; }
  awk -f "$MOD/verify_xml.awk" "$TMP/out" 2>> "$TMP/err" \
    || { bad crlf "verifier rejected patched output"; return; }
  [ "$(count_tc "$TMP/crlf.xml")" = "$(count_tc "$TMP/out")" ] \
    || { bad crlf "temp_config count changed"; return; }
  ok crlf
}
t_idempotent() {
  awk -f "$MOD/patch_xml.awk" "$FIX/pretty.xml" > "$TMP/a" 2>/dev/null \
    && awk -f "$MOD/patch_xml.awk" "$TMP/a" > "$TMP/b" 2>/dev/null \
    && cmp -s "$TMP/a" "$TMP/b" \
    || { bad idempotent "patch(patch(x)) != patch(x)"; return; }
  ok idempotent
}
t_no_temp_config() {
  awk -f "$MOD/patch_xml.awk" "$FIX/empty.xml" > "$TMP/out" 2>/dev/null \
    && { bad no-temp-config "patcher accepted input without temp_config"; return; }
  awk -f "$MOD/verify_xml.awk" "$FIX/empty.xml" >/dev/null 2>&1 \
    && { bad no-temp-config "verifier accepted input without temp_config"; return; }
  ok no-temp-config
}
t_verifier_catches_leftover() {
  awk -f "$MOD/verify_xml.awk" "$FIX/bad_leftover.xml" >/dev/null 2>&1 \
    && { bad verifier-leftover "verifier accepted nonzero clusterCpu1"; return; }
  ok verifier-leftover
}

t_decoy_names() {
  awk -f "$MOD/patch_xml.awk" "$FIX/decoy_names.xml" > "$TMP/out" 2> "$TMP/err" \
    || { bad decoy-names "patcher exited nonzero: $(cat "$TMP/err")"; return; }
  awk -f "$MOD/verify_xml.awk" "$TMP/out" 2>> "$TMP/err" \
    || { bad decoy-names "verifier rejected output"; return; }
  grep -q 'temp_configExtra cpu="7"' "$TMP/out" || { bad decoy-names "similar element name was modified"; return; }
  grep -q 'bigcpu="1900000"' "$TMP/out" || { bad decoy-names "bigcpu attribute was modified"; return; }
  grep -q 'cpu="0"' "$TMP/out" || { bad decoy-names "real cpu not zeroed"; return; }
  grep -q 'clusterCpu1="0"' "$TMP/out" || { bad decoy-names "clusterCpu1 not zeroed"; return; }
  grep -q "note=\"keep clusterCpu0=' untouched outside temp_config\"" "$TMP/out" \
    || { bad decoy-names "element outside temp_config was modified"; return; }
  ok decoy-names
}
t_gt_in_value() {
  awk -f "$MOD/patch_xml.awk" "$FIX/gt_in_value.xml" > "$TMP/out" 2>/dev/null \
    && { bad gt-in-value "patcher accepted '>' inside a quoted value"; return; }
  [ -s "$TMP/out" ] && { bad gt-in-value "wrote output despite error"; return; }
  awk -f "$MOD/verify_xml.awk" "$FIX/gt_in_value.xml" >/dev/null 2>&1 \
    && { bad gt-in-value "verifier accepted '>' inside a quoted value"; return; }
  ok gt-in-value
}
t_apostrophe_value() {
  awk -f "$MOD/patch_xml.awk" "$FIX/apostrophe.xml" > "$TMP/out" 2>/dev/null \
    || { bad apostrophe "patcher rejected a legal apostrophe value"; return; }
  awk -f "$MOD/verify_xml.awk" "$TMP/out" 2>/dev/null \
    || { bad apostrophe "verifier rejected patched output"; return; }
  grep -q "note=\"it's a&gt;b\"" "$TMP/out" || { bad apostrophe "apostrophe/entity value was mangled"; return; }
  grep -q 'clusterCpu0="0"' "$TMP/out" || { bad apostrophe "clusterCpu0 not zeroed"; return; }
  ok apostrophe-value
}


# --- CLI surface: profiles / watcher / gamelist ---------------------------
cli() { # cli <args...> — run usfcpu.sh with an isolated config dir
  USF_CONFIG_DIR="$TMP/cfg" USF_NO_SPAWN=1 sh "$MOD/usfcpu.sh" "$@" 2>&1
}

t_cli_usage() {
  out=$(cli bogus-subcommand); rc=$?
  [ "$rc" -eq 2 ] || { bad cli-usage "exit $rc, expected 2"; return; }
  echo "$out" | grep -q 'usage:' || { bad cli-usage "no usage text"; return; }
  echo "$out" | grep -q 'profile {' || { bad cli-usage "profile usage line missing"; return; }
  echo "$out" | grep -q 'games {' || { bad cli-usage "games usage line missing"; return; }
  ok cli-usage
}

t_cli_games() {
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  out=$(cli games add com.mobile.legends)
  echo "$out" | grep -q 'added: com.mobile.legends' || { bad cli-games "add not confirmed"; return; }
  grep -qxF 'com.mobile.legends' "$TMP/cfg/gamelist.txt" || { bad cli-games "package not written"; return; }

  # idempotent
  cli games add com.mobile.legends >/dev/null
  n=$(grep -cxF 'com.mobile.legends' "$TMP/cfg/gamelist.txt")
  [ "$n" -eq 1 ] || { bad cli-games "duplicate entry ($n lines)"; return; }

  cli games add com.garena.game.codm >/dev/null
  out=$(cli games list)
  echo "$out" | grep -q 'com.mobile.legends' || { bad cli-games "list missing entry"; return; }
  echo "$out" | grep -q '(2 package(s))' || { bad cli-games "list count wrong: $out"; return; }

  out=$(cli games remove com.mobile.legends)
  echo "$out" | grep -q 'removed: com.mobile.legends' || { bad cli-games "remove not confirmed"; return; }
  grep -qxF 'com.mobile.legends' "$TMP/cfg/gamelist.txt" && { bad cli-games "entry survived removal"; return; }
  grep -qxF 'com.garena.game.codm' "$TMP/cfg/gamelist.txt" || { bad cli-games "removal dropped a sibling"; return; }
  ok cli-games
}

t_cli_watch_toggle() {
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  out=$(cli watch off)
  echo "$out" | grep -q 'watcher disabled' || { bad cli-watch "off not confirmed: $out"; return; }
  [ -f "$TMP/cfg/watcher.disabled" ] || { bad cli-watch "disabled marker not created"; return; }

  out=$(cli watch on)
  echo "$out" | grep -q 'watcher enabled' || { bad cli-watch "on not confirmed: $out"; return; }
  [ -f "$TMP/cfg/watcher.disabled" ] && { bad cli-watch "disabled marker survived"; return; }
  ok cli-watch-toggle
}

t_cli_profile_status() {
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  printf 'performance\n' > "$TMP/cfg/watcher.state"
  printf 'com.mobile.legends\ncom.garena.game.codm\n' > "$TMP/cfg/gamelist.txt"
  out=$(cli profile-status)
  echo "$out" | grep -q 'watcher     : on' || { bad cli-pstatus "watcher line missing: $out"; return; }
  echo "$out" | grep -q 'profile     : performance' || { bad cli-pstatus "profile line missing"; return; }
  echo "$out" | grep -q 'gamelist    : 2 package' || { bad cli-pstatus "gamelist count wrong"; return; }
  ok cli-profile-status
}

t_cli_profile_bad() {
  out=$(cli profile turbo); rc=$?
  [ "$rc" -eq 2 ] || { bad cli-profile "exit $rc, expected 2"; return; }
  echo "$out" | grep -q 'usage: ' || { bad cli-profile "no usage"; return; }
  ok cli-profile-bad
}

t_pretty
t_minified
t_partial
t_crlf
t_idempotent
t_no_temp_config
t_verifier_catches_leftover
t_decoy_names
t_gt_in_value
t_apostrophe_value
t_cli_usage
t_cli_games
t_cli_watch_toggle
t_cli_profile_status
t_cli_profile_bad

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
