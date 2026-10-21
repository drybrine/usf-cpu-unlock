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
  echo "$out" | grep -q 'governor    :' || { bad cli-pstatus "governor line missing"; return; }
  ok cli-profile-status
}

t_cli_profile_writes_hold() {
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  out=$(cli profile performance)
  echo "$out" | grep -q 'profile applied: performance' || { bad cli-hold "not confirmed: $out"; return; }
  [ -f "$TMP/cfg/manual_hold" ] || { bad cli-hold "no manual hold written"; return; }
  hold=$(head -n 1 "$TMP/cfg/manual_hold")
  ts=${hold%%|*}
  case "$ts" in ''|*[!0-9]*) bad cli-hold "hold timestamp not numeric: $hold"; return ;; esac
  case "$hold" in *'|'*) : ;; *) bad cli-hold "hold has no package field: $hold"; return ;; esac
  # state kept in sync so the watcher's next poll does not re-apply blindly
  [ "$(cat "$TMP/cfg/watcher.state" 2>/dev/null)" = "performance" ] \
    || { bad cli-hold "watcher.state not synced"; return; }
  [ "$(cat "$TMP/cfg/manual_profile" 2>/dev/null)" = "performance" ] \
    || { bad cli-hold "manual_profile not written"; return; }
  echo "$out" | grep -q 'manual hold' || { bad cli-hold "hold not announced: $out"; return; }
  ok cli-profile-hold
}

t_cli_watch_clears_hold() {
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  printf '1000000|com.android.chrome\n' > "$TMP/cfg/manual_hold"
  out=$(cli watch on)
  [ -f "$TMP/cfg/manual_hold" ] && { bad cli-hold-clear "watch on kept the hold"; return; }
  printf '1000000|com.android.chrome\n' > "$TMP/cfg/manual_hold"
  cli watch off >/dev/null
  [ -f "$TMP/cfg/manual_hold" ] && { bad cli-hold-clear "watch off kept the hold"; return; }
  ok cli-watch-clears-hold
}

t_cli_profile_status_shows_hold() {
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  printf '1000000|com.mobile.legends\n' > "$TMP/cfg/manual_hold"
  printf 'performance\n' > "$TMP/cfg/watcher.state"
  out=$(cli profile-status)
  echo "$out" | grep -q 'manual hold : com.mobile.legends' \
    || { bad cli-hold-status "hold not shown: $out"; return; }
  ok cli-profile-status-hold
}

t_cli_screenoff() {
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  # default
  out=$(cli profile-status)
  echo "$out" | grep -q 'screenoff   : powersave' || { bad cli-soff "default wrong: $out"; return; }

  out=$(cli screenoff keep)
  echo "$out" | grep -q 'profile left untouched' || { bad cli-soff "keep not confirmed: $out"; return; }
  [ "$(cat "$TMP/cfg/watcher.screen_off" 2>/dev/null)" = "keep" ] \
    || { bad cli-soff "mode not persisted"; return; }
  out=$(cli profile-status)
  echo "$out" | grep -q 'screenoff   : keep' || { bad cli-soff "status not updated: $out"; return; }

  cli screenoff balance >/dev/null
  [ "$(cat "$TMP/cfg/watcher.screen_off")" = "balance" ] || { bad cli-soff "balance not persisted"; return; }

  # invalid mode is rejected and leaves the file alone
  out=$(cli screenoff turbo); rc=$?
  [ "$rc" -eq 2 ] || { bad cli-soff "invalid mode exit $rc"; return; }
  [ "$(cat "$TMP/cfg/watcher.screen_off")" = "balance" ] \
    || { bad cli-soff "invalid mode overwrote the setting"; return; }
  ok cli-screenoff
}

t_cli_profile_bad() {
  out=$(cli profile turbo); rc=$?
  [ "$rc" -eq 2 ] || { bad cli-profile "exit $rc, expected 2"; return; }
  echo "$out" | grep -q 'usage: ' || { bad cli-profile "no usage"; return; }
  ok cli-profile-bad
}

t_webui_fast() {
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  printf 'performance\n' > "$TMP/cfg/watcher.state"
  printf 'keep\n' > "$TMP/cfg/watcher.screen_off"
  printf 'com.mobile.legends\n# c\n\ncom.garena.game.codm\n' > "$TMP/cfg/gamelist.txt"

  # dumpsys stub: webui-fast must never touch it (it is the slow path)
  mkdir -p "$TMP/nodump"
  printf '#!/bin/sh\necho called >> "$DUMPLOG"\nexit 0\n' > "$TMP/nodump/dumpsys"
  chmod +x "$TMP/nodump/dumpsys"
  export DUMPLOG="$TMP/dump.log"; : > "$DUMPLOG"

  out=$(PATH="$TMP/nodump:$PATH" USF_CONFIG_DIR="$TMP/cfg" USF_NO_SPAWN=1 \
        sh "$MOD/usfcpu.sh" webui-fast 2>&1)
  [ -s "$DUMPLOG" ] && { bad webui-fast "called dumpsys (slow path)"; return; }

  # one call must carry the whole card
  for needle in 'module      : usf-cpu-unlock' 'watcher     :' 'profile     : performance' \
                'gamelist    : 2 package' 'screenoff   : keep' 'governor    :' \
                'cpufreq caps'; do
    echo "$out" | grep -qF "$needle" || { bad webui-fast "missing: $needle"; return; }
  done
  # and nothing slow
  echo "$out" | grep -q 'engine state' && { bad webui-fast "includes the engine dump"; return; }
  ok webui-fast
}

t_engine_command() {
  out=$(USF_CONFIG_DIR="$TMP/cfg" sh "$MOD/usfcpu.sh" engine 2>&1)
  echo "$out" | grep -q 'engine state' || { bad engine "no engine header: $out"; return; }
  # must degrade gracefully when dumpsys yields nothing
  echo "$out" | grep -q 'unavailable' || { bad engine "no fallback message"; return; }
  ok engine-command
}

t_action_emits_status() {
  # a profile switch must print the whole status block, so the WebUI can
  # render from the action's own response (no extra bridge round trip)
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  out=$(USF_CONFIG_DIR="$TMP/cfg" USF_NO_SPAWN=1 sh "$MOD/usfcpu.sh" profile performance 2>&1)
  echo "$out" | grep -q 'profile applied: performance' || { bad action-status "no confirmation"; return; }
  for needle in 'profile     : performance' 'watcher     :' 'screenoff   :' 'governor    :'; do
    echo "$out" | grep -qF "$needle" || { bad action-status "missing $needle"; return; }
  done
  # the same for the screen-off picker
  out=$(USF_CONFIG_DIR="$TMP/cfg" USF_NO_SPAWN=1 sh "$MOD/usfcpu.sh" screenoff keep 2>&1)
  echo "$out" | grep -qF 'screenoff   : keep' || { bad action-status "screenoff does not report"; return; }
  echo "$out" | grep -qF 'profile     :' || { bad action-status "screenoff has no status block"; return; }
  ok action-emits-status
}

t_update_json_paths() {
  uj="$ROOT/update.json"
  [ -f "$uj" ] || { bad update-json "update.json missing"; return; }
  # version/versionCode must agree with module.prop (an updater compares codes)
  uver=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$uj")
  ucode=$(sed -n 's/.*"versionCode": \([0-9]*\).*/\1/p' "$uj")
  pver=$(sed -n 's/^version=//p' "$MOD/module.prop")
  pcode=$(sed -n 's/^versionCode=//p' "$MOD/module.prop")
  [ "$uver" = "$pver" ] || { bad update-json "version $uver != module.prop $pver"; return; }
  [ "$ucode" = "$pcode" ] || { bad update-json "versionCode $ucode != module.prop $pcode"; return; }

  # every raw.githubusercontent URL must point at a real file in the repo:
  # a 404 here is what made the manager fail to fetch the changelog
  for url in $(sed -n 's/.*"\(changelog\|zipUrl\)": "\(https:[^"]*\)".*/\1 \2/p' "$uj" | grep raw.githubusercontent || true); do :; done
  cl=$(sed -n 's/.*"changelog": "\([^"]*\)".*/\1/p' "$uj")
  case "$cl" in
    *raw.githubusercontent.com/*/main/*)
      rel=${cl#*raw.githubusercontent.com/}
      rel=${rel#*/main/}
      [ -f "$ROOT/$rel" ] || { bad update-json "changelog 404s: no $rel in repo"; return; }
      ;;
  esac
  # the root copy exists so cached update.json files (which pointed at
  # /main/CHANGELOG.md) keep working; it must never drift from the module copy
  if [ -f "$ROOT/CHANGELOG.md" ]; then
    cmp -s "$ROOT/CHANGELOG.md" "$MOD/CHANGELOG.md" \
      || { bad update-json "root CHANGELOG.md drifted from module/CHANGELOG.md"; return; }
  fi

  # zipUrl must name the same version as the release
  zip=$(sed -n 's/.*"zipUrl": "\([^"]*\)".*/\1/p' "$uj")
  case "$zip" in
    *"/$uver/"*"-$uver.zip") : ;;
    *) bad update-json "zipUrl does not match $uver: $zip"; return ;;
  esac
  ok update-json-paths
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
t_update_json_paths
t_webui_fast
t_engine_command
t_action_emits_status
t_cli_usage
t_cli_games
t_cli_watch_toggle
t_cli_profile_status
t_cli_profile_bad
t_cli_screenoff
t_cli_profile_writes_hold
t_cli_watch_clears_hold
t_cli_profile_status_shows_hold

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
