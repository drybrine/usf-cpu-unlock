#!/system/bin/sh
# usf-cpu-unlock core — reversibly disable the Transsion USF skin-thermal
# CPU cluster cap.
#
# Mechanism (verified against com.transsion.usf 26.08.05.001):
#   1. Copy the stock tran_thermal.xml and zero ONLY the cpu/clusterCpu0/1/2
#      attributes of every <temp_config> row (USF's own "no CPU limit"
#      encoding — its applyCpuLimit releases the PowerHAL thermal handle for
#      an all-zero row).
#   2. Bind-mount the patched copy over the original path (original file on
#      the partition is never written; the mount is runtime-only and is gone
#      after a reboot).
#   3. Restart com.transsion.usf (persistent app, restarted automatically by
#      the framework) so it reloads the patched config.
#
# NOT touched: kernel thermal zones/trip points, junction protection,
# skin-control TJ targets, charging policy, GPU/brightness/FP policy.
#
# Commands: apply | restore | status | toggle | restart-usf
#           profile <name> | profile-status | watch <on|off|status>
#           screenoff <powersave|balance|keep>
#           games <add|remove|list> [package]

case "$0" in
  */*) MODDIR=${0%/*} ;;
  *)   MODDIR=/data/adb/modules/usf-cpu-unlock ;;
esac

KSU_BB=/data/adb/ksu/bin/busybox
[ -x "$KSU_BB" ] || KSU_BB=""

XML_TR_PRODUCT=/tr_product/etc/vconfig/tranusf/config/thermal/tran_thermal.xml
XML_SYSTEM_EXT=/system_ext/etc/vconfig/tranusf/config/thermal/tran_thermal.xml

SRC=""
[ -f "$XML_TR_PRODUCT" ] && SRC="$XML_TR_PRODUCT"
[ -z "$SRC" ] && [ -f "$XML_SYSTEM_EXT" ] && SRC="$XML_SYSTEM_EXT"

BACKUP_DIR="$MODDIR/backup"
PATCHED_DIR="$MODDIR/patched"
BACKUP="$BACKUP_DIR/tran_thermal.xml"
PATCHED="$PATCHED_DIR/tran_thermal.xml"
LOG="$MODDIR/apply.log"

CONFIG_DIR=${USF_CONFIG_DIR:-/data/adb/.config/usf-cpu-unlock}
GAMELIST="$CONFIG_DIR/gamelist.txt"
HOLDFILE="$CONFIG_DIR/manual_hold"
SCREENOFF_FILE="$CONFIG_DIR/watcher.screen_off"
WATCHER="$MODDIR/scripts/usf_watcher.sh"
PROFILER="$MODDIR/scripts/usf_profiler.sh"

run_awk() {
  if [ -n "$KSU_BB" ]; then "$KSU_BB" awk "$@"; else awk "$@"; fi
}

do_mount() {
  if [ -n "$KSU_BB" ]; then "$KSU_BB" mount "$@"; else mount "$@"; fi
}
do_umount() {
  if [ -n "$KSU_BB" ]; then "$KSU_BB" umount "$@"; else umount "$@"; fi
}

ui() { printf '%s\n' "$*"; }
log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
  ui "$*"
}

# PIDs whose /proc/PID/cmdline is exactly the USF package (no wildcards).
usf_pids() {
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$c" in
      com.transsion.usf|com.transsion.usf\ *) printf '%s\n' "${d#/proc/}" ;;
    esac
  done
}

is_mounted() { cut -d' ' -f2 /proc/mounts 2>/dev/null | grep -qxF "$1"; }

engine_state() {
  # dumpsys can block on a wedged service; a timeout keeps `status` from
  # hanging (or looking empty) instead of reporting what it already knows.
  if command -v timeout >/dev/null 2>&1; then
    timeout 6 dumpsys activity service com.transsion.usf.UsfMainService -thermal thermal_engine state 2>/dev/null
  else
    dumpsys activity service com.transsion.usf.UsfMainService -thermal thermal_engine state 2>/dev/null
  fi
}

state_field() {
  engine_state | sed -n "$1" | head -n 1
}

wait_restart() { # wait_restart <oldpid> — prints new pid on success
  old=$1
  i=0
  while [ "$i" -lt 30 ]; do
    p=$(usf_pids | head -n 1)
    if [ -n "$p" ] && [ "$p" != "$old" ]; then
      printf '%s\n' "$p"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

restart_usf() {
  pids=$(usf_pids | tr '\n' ' ')
  old=$(usf_pids | head -n 1)
  if [ -z "$old" ]; then
    log "USF is not running; nothing to restart"
    return 0
  fi
  for p in $pids; do
    # Re-read cmdline immediately before the kill: PID reuse between the
    # scan and here must never send the signal to a recycled PID.
    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    case "$c" in
      com.transsion.usf|com.transsion.usf\ *) kill -9 "$p" 2>/dev/null ;;
    esac
  done
  log "USF stopped (was: ${pids}); waiting for the framework to restart it..."
  if wait_restart "$old"; then
    log "USF restarted (pid $(usf_pids | head -n 1))"
  else
    log "WARN: USF did not restart within 30s (persistent app; it should return on its own)"
  fi
}

print_freqs() {
  for d in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -r "$d/scaling_max_freq" ] || continue
    ui "  $(basename "$d"): max=$(cat "$d/scaling_max_freq" 2>/dev/null) hw=$(cat "$d/cpuinfo_max_freq" 2>/dev/null)"
  done
}

trim_log() {
  [ -f "$LOG" ] || return 0
  size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
  [ -n "$size" ] && [ "$size" -gt 204800 ] && : > "$LOG"
}

# Serialize apply/restore so a service.sh auto-apply racing a manual Action
# tap cannot stack two identical bind mounts.
LOCK="$MODDIR/.lock"
lock_acquire() {
  n=0
  while [ "$n" -lt 15 ]; do
    mkdir "$LOCK" 2>/dev/null && return 0
    sleep 1
    n=$((n + 1))
  done
  return 1
}
lock_release() { rmdir "$LOCK" 2>/dev/null; }

apply_locked() {
  trim_log
  if [ -z "$SRC" ]; then
    log "ERROR: tran_thermal.xml not found (unsupported build?)"
    return 1
  fi
  if is_mounted "$SRC"; then
    log "Already applied: patched config is mounted over $SRC"
    log "Run 'restore' first if you want to re-apply from scratch"
    return 0
  fi
  grep -q temp_config "$SRC" 2>/dev/null || {
    log "ERROR: $SRC contains no temp_config (unexpected format; aborting, nothing changed)"
    return 1
  }

  mkdir -p "$BACKUP_DIR" "$PATCHED_DIR" || return 1
  cp -f "$SRC" "$BACKUP" || { log "ERROR: backup copy failed"; return 1; }

  run_awk -f "$MODDIR/patch_xml.awk" "$SRC" > "$PATCHED.tmp" 2>/dev/null || {
    rm -f "$PATCHED.tmp"
    log "ERROR: XML patch failed; aborting, nothing changed"
    return 1
  }
  run_awk -f "$MODDIR/verify_xml.awk" "$PATCHED.tmp" 2>/dev/null || {
    rm -f "$PATCHED.tmp"
    log "ERROR: patched XML failed verification; aborting, nothing changed"
    return 1
  }
  n_orig=$(grep -o '<temp_config' "$SRC" | wc -l | tr -d ' ')
  n_new=$(grep -o '<temp_config' "$PATCHED.tmp" | wc -l | tr -d ' ')
  if [ "$n_orig" != "$n_new" ] || [ "$n_orig" -eq 0 ]; then
    rm -f "$PATCHED.tmp"
    log "ERROR: temp_config count mismatch ($n_orig -> $n_new); aborting, nothing changed"
    return 1
  fi
  mv -f "$PATCHED.tmp" "$PATCHED" || return 1

  # Match owner/mode/SELinux label of the original so USF can read the mount.
  owner=$(stat -c '%u:%g' "$SRC" 2>/dev/null)
  mode=$(stat -c '%a' "$SRC" 2>/dev/null)
  label=$(stat -c '%C' "$SRC" 2>/dev/null)
  if [ -z "$label" ]; then
    label=$(ls -Z "$SRC" 2>/dev/null | sed -n '1s/^ *\([^ ]*\) .*/\1/p')
  fi
  if [ -n "$owner" ]; then chown "$owner" "$PATCHED" 2>/dev/null; fi
  if [ -n "$mode" ]; then chmod "$mode" "$PATCHED" 2>/dev/null; else chmod 644 "$PATCHED"; fi
  if [ -n "$label" ]; then
    chcon "$label" "$PATCHED" 2>/dev/null || log "WARN: chcon '$label' failed (SELinux may block USF reads)"
  else
    log "WARN: could not read SELinux label of the original file"
  fi

  do_mount -o bind "$PATCHED" "$SRC" 2>/dev/null || do_mount --bind "$PATCHED" "$SRC" 2>/dev/null || {
    log "ERROR: bind mount failed; aborting, nothing changed"
    return 1
  }
  do_mount -o remount,bind,ro "$SRC" 2>/dev/null || log "WARN: could not remount the bind read-only"

  if [ "${MOUNT_ONLY:-0}" = "1" ]; then
    log "MOUNT-ONLY: patched config mounted over $SRC before USF starts; it will load the patched file at its first config read"
    return 0
  fi

  log "Patched config mounted over $SRC; restarting USF to reload it"
  restart_usf

  # Ground truth is the engine's own current-config row (clusterCpu0=0) plus
  # the live cpufreq ceilings. The PowerHAL handle itself is NOT a reliable
  # success signal: depending on its previous state, USF may legitimately
  # hold a handle locked at 100% hardware max for an all-zero row.
  i=0
  ok=0
  while [ "$i" -lt 45 ]; do
    c=$(state_field 's/.*clusterCpu0=\([0-9][0-9]*\).*/\1/p')
    if [ -n "$c" ] && [ "$c" -eq 0 ]; then
      ok=1
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  h=$(state_field 's/.*Thermal CPU handle: \([0-9][0-9]*\).*/\1/p')
  if [ "$ok" -eq 1 ]; then
    log "APPLIED: USF CPU thermal cap disabled (active config clusterCpu0=0; handle=${h:-unknown})"
  else
    log "APPLIED (mounted + USF restarted) but engine state was not confirmed within 45s."
    log "If 'status' shows 'Current temp config: null', the config failed to parse - run 'restore'."
  fi
  print_freqs
}

restore_locked() {
  trim_log
  if [ -z "$SRC" ]; then
    ui "ERROR: tran_thermal.xml not found"
    return 1
  fi
  if ! is_mounted "$SRC"; then
    log "Not applied (no bind mount active); stock behavior already in place"
    return 0
  fi
  do_umount "$SRC" 2>/dev/null || do_umount -l "$SRC" 2>/dev/null || {
    log "ERROR: umount failed; try again, or reboot (mounts do not survive reboot)"
    return 1
  }
  log "Bind mount removed; restarting USF to reload the stock config"
  restart_usf
  i=0
  while [ "$i" -lt 45 ]; do
    c=$(state_field 's/.*clusterCpu0=\([0-9][0-9]*\).*/\1/p')
    [ -n "$c" ] && break
    sleep 1
    i=$((i + 1))
  done
  c=$(state_field 's/.*clusterCpu0=\([0-9][0-9]*\).*/\1/p')
  log "RESTORED: stock USF policy reloaded (engine responding; clusterCpu0=${c:-unknown}; 0 is normal when skin is cool)"
  print_freqs
}

do_apply() {
  lock_acquire || { log "ERROR: another apply/restore is already running"; return 1; }
  apply_locked
  rc=$?
  lock_release
  return $rc
}

do_restore() {
  lock_acquire || { log "ERROR: another apply/restore is already running"; return 1; }
  restore_locked
  rc=$?
  lock_release
  return $rc
}

do_status() {
  ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
  ui "module      : usf-cpu-unlock ${ver:-unknown}"
  ui "module dir  : $MODDIR"
  ui "active xml  : ${SRC:-not found}"
  if [ -n "$SRC" ]; then
    if is_mounted "$SRC"; then
      ui "patch mount: ACTIVE (USF CPU cap disabled)"
    else
      ui "patch mount: inactive (stock behavior)"
    fi
  fi
  pids=$(usf_pids | tr '\n' ' ')
  ui "usf pid(s) : ${pids:-not running}"
  ui "engine state (excerpt):"
  excerpt=$(engine_state | sed -n '/=== Thermal Engine State ===/,/=== End of Thermal Engine State ===/p' \
    | grep -E 'MTK thermal CPU limit support|Thermal CPU handle|Current temp config|tempLevel=|^ *cpu=|clusterCpu[012]=')
  if [ -n "$excerpt" ]; then
    ui "$excerpt"
  else
    ui "  (engine dump unavailable - dumpsys did not respond; mount state above is still valid)"
  fi
  ui "cpufreq caps (max vs hardware max):"
  print_freqs
}

# Fast path for the WebUI: version + mount state + cpufreq ceilings only.
# No dumpsys, no /proc scan — returns in milliseconds so the page can paint
# immediately; the full engine detail is filled in by `status` afterwards.
do_quick() {
  ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
  ui "module      : usf-cpu-unlock ${ver:-unknown}"
  if [ -n "$SRC" ]; then
    if is_mounted "$SRC"; then
      ui "patch mount: ACTIVE (USF CPU cap disabled)"
    else
      ui "patch mount: inactive (stock behavior)"
    fi
  fi
  print_freqs
}

do_changelog() {
  v=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
  ui "usf-cpu-unlock ${v:-unknown}"
  ui ""
  if [ -f "$MODDIR/CHANGELOG.md" ]; then
    cat "$MODDIR/CHANGELOG.md"
  else
    ui "CHANGELOG.md not found in the module directory."
    ui "Latest: https://github.com/drybrine/usf-cpu-unlock/releases"
  fi
}

# --- performance profiles (ported from Encore Tweaks) ----------------------

# Foreground package, same cheap signal the watcher uses (top-app cpuset +
# oom_score_adj). Used to scope a manual profile pick to the current app.
current_fg() {
  # Word splitting is intended: cgroup.procs is a whitespace list of PIDs.
  # shellcheck disable=SC2013
  for p in $(cat /dev/cpuset/top-app/cgroup.procs 2>/dev/null); do
    adj=$(cat "/proc/$p/oom_score_adj" 2>/dev/null)
    [ "$adj" = "0" ] || continue
    c=$(tr -d '\0' < "/proc/$p/cmdline" 2>/dev/null)
    case "$c" in ''|*:*|*/*) continue ;; esac
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

do_profile() {
  p=${1:-}
  case "$p" in
    performance|performance_lite|balance|powersave|perfcommon) ;;
    *) ui "usage: $0 profile {performance|performance_lite|balance|powersave}"; return 2 ;;
  esac
  if [ ! -f "$PROFILER" ]; then
    ui "ERROR: profiler script missing ($PROFILER)"
    return 1
  fi
  sh "$PROFILER" "$p" >/dev/null 2>&1
  mkdir -p "$CONFIG_DIR" 2>/dev/null
  printf '%s\n' "$p" > "$CONFIG_DIR/manual_profile" 2>/dev/null
  # Keep the watcher's idea of the current profile in sync, and pin a manual
  # hold to this app so the next poll does not immediately undo the pick.
  printf '%s\n' "$p" > "$CONFIG_DIR/watcher.state" 2>/dev/null
  fg=$(current_fg 2>/dev/null) || fg=""
  printf '%s|%s\n' "$(date +%s)" "$fg" > "$HOLDFILE" 2>/dev/null
  ui "profile applied: $p"
  if [ -n "$fg" ]; then
    ui "manual hold : active while $fg stays foreground"
  else
    ui "manual hold : active (foreground app not detected)"
  fi
  print_freqs
}

do_profile_status() {
  cur=$(cat "$CONFIG_DIR/watcher.state" 2>/dev/null)
  man=$(cat "$CONFIG_DIR/manual_profile" 2>/dev/null)
  if [ -f "$CONFIG_DIR/watcher.disabled" ]; then
    wstate=off
  else
    wpid=$(cat "$CONFIG_DIR/watcher.pid" 2>/dev/null)
    if [ -n "$wpid" ] && [ -d "/proc/$wpid" ]; then wstate="on (pid $wpid)"; else wstate="on (not running)"; fi
  fi
  ui "watcher     : $wstate"
  ui "profile     : ${cur:-unknown (watcher has not run yet)}"
  [ -n "$man" ] && ui "manual pick : $man"
  n=0
  [ -r "$GAMELIST" ] && n=$(grep -cvE '^[[:space:]]*(#|$)' "$GAMELIST" 2>/dev/null)
  if [ -r "$HOLDFILE" ]; then
    hold=$(head -n 1 "$HOLDFILE" 2>/dev/null)
    ui "manual hold : ${hold#*|} (until the foreground app changes)"
  fi
  ui "gamelist    : ${n:-0} package(s) -> $GAMELIST"
  gov=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)
  ui "screenoff   : $(screenoff_mode)"
  ui "governor    : ${gov:-unknown} (policy0)"
  ppm=$(cat /proc/ppm/policy/hard_userlimit_max_cpu_freq 2>/dev/null | tr '\n' ';' | sed 's/;$//')
  [ -n "$ppm" ] && ui "ppm max lim : $ppm"
  ui "cpufreq caps (max vs hardware max):"
  print_freqs
}

do_watch() {
  case "${1:-status}" in
    on|enable)
      rm -f "$CONFIG_DIR/watcher.disabled" "$HOLDFILE" 2>/dev/null
      mkdir -p "$CONFIG_DIR" 2>/dev/null
      if [ ! -f "$WATCHER" ]; then
        ui "ERROR: watcher script missing ($WATCHER)"; return 1
      fi
      if [ -n "${USF_NO_SPAWN:-}" ]; then
        ui "watcher enabled (not spawned)"
        return 0
      fi
      old=$(cat "$CONFIG_DIR/watcher.pid" 2>/dev/null)
      if [ -n "$old" ] && [ -d "/proc/$old" ]; then
        case "$(tr -d '\0' < "/proc/$old/cmdline" 2>/dev/null)" in
          *usf_watcher*) ui "watcher already running (pid $old)"; return 0 ;;
        esac
      fi
      MODULE_DIR="$MODDIR" nohup sh "$WATCHER" >> "$MODDIR/watcher.log" 2>&1 &
      sleep 1
      ui "watcher started (pid $(cat "$CONFIG_DIR/watcher.pid" 2>/dev/null))"
      ;;
    off|disable)
      mkdir -p "$CONFIG_DIR" 2>/dev/null
      : > "$CONFIG_DIR/watcher.disabled"
      rm -f "$HOLDFILE" 2>/dev/null
      old=$(cat "$CONFIG_DIR/watcher.pid" 2>/dev/null)
      if [ -n "$old" ] && [ -d "/proc/$old" ]; then
        case "$(tr -d '\0' < "/proc/$old/cmdline" 2>/dev/null)" in
          *usf_watcher*) kill "$old" 2>/dev/null ;;
        esac
      fi
      rm -f "$CONFIG_DIR/watcher.pid" 2>/dev/null
      ui "watcher disabled (profile stays at $(cat "$CONFIG_DIR/watcher.state" 2>/dev/null || echo unknown))"
      ;;
    status)
      do_profile_status
      ;;
    *)
      ui "usage: $0 watch {on|off|status}"; return 2 ;;
  esac
}

do_screenoff() {
  mode=${1:-}
  case "$mode" in
    powersave|balance|keep) ;;
    '')
      ui "screen-off profile: $(screenoff_mode 2>/dev/null || echo powersave)"
      ui "usage: $0 screenoff {powersave|balance|keep}"
      return 0
      ;;
    *)
      ui "usage: $0 screenoff {powersave|balance|keep}"
      return 2
      ;;
  esac
  mkdir -p "$CONFIG_DIR" 2>/dev/null
  printf '%s\n' "$mode" > "$SCREENOFF_FILE" 2>/dev/null
  case "$mode" in
    keep)      ui "screen off: profile left untouched (no powersave stutter on unlock)" ;;
    balance)   ui "screen off: drop to balance" ;;
    powersave) ui "screen off: drop to powersave" ;;
  esac
  ui "takes effect on the watcher's next poll (<= 2s)"
}

# Effective screen-off mode, same precedence the watcher uses.
screenoff_mode() {
  m=$(head -n 1 "$SCREENOFF_FILE" 2>/dev/null | tr -d '\r' | tr -d ' ')
  case "$m" in
    powersave|balance|keep) printf '%s\n' "$m" ;;
    *) printf 'powersave\n' ;;
  esac
}

do_games() {
  mkdir -p "$CONFIG_DIR" 2>/dev/null
  [ -f "$GAMELIST" ] || : > "$GAMELIST"
  case "${1:-list}" in
    add)
      pkg=${2:-}
      if [ -z "$pkg" ]; then ui "usage: $0 games add <package>"; return 2; fi
      if grep -qxF "$pkg" "$GAMELIST" 2>/dev/null; then
        ui "$pkg already in the gamelist"
        return 0
      fi
      printf '%s\n' "$pkg" >> "$GAMELIST"
      ui "added: $pkg"
      ;;
    remove|rm)
      pkg=${2:-}
      if [ -z "$pkg" ]; then ui "usage: $0 games remove <package>"; return 2; fi
      if ! grep -qxF "$pkg" "$GAMELIST" 2>/dev/null; then
        ui "$pkg is not in the gamelist"
        return 0
      fi
      tmp="$GAMELIST.tmp.$$"
      grep -vxF "$pkg" "$GAMELIST" > "$tmp" 2>/dev/null
      mv -f "$tmp" "$GAMELIST" 2>/dev/null
      ui "removed: $pkg"
      ;;
    list)
      n=0
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        ui "$line"
        n=$((n + 1))
      done < "$GAMELIST"
      ui "($n package(s))"
      ;;
    *)
      ui "usage: $0 games {add|remove|list} [package]"; return 2 ;;
  esac
}

# Dispatch only when executed directly. Callers that source this file as a
# library (action.sh / service.sh / uninstall.sh) invoke do_* functions
# themselves; "$0" there is the caller's path, not this script's.
case "$0" in
*usfcpu.sh)
  case "${1:-}" in
  apply)        do_apply ;;
  restore)      do_restore ;;
  status)       do_status ;;
  webui-quick)  do_quick ;;
  changelog)    do_changelog ;;
  profile)      do_profile "${2:-}" ;;
  profile-status) do_profile_status ;;
  watch)        do_watch "${2:-status}" ;;
  screenoff)    do_screenoff "${2:-}" ;;
  games)        do_games "${2:-list}" "${3:-}" ;;
  toggle)
    if [ -n "$SRC" ] && is_mounted "$SRC"; then do_restore; else do_apply; fi
    ;;
  restart-usf)  restart_usf ;;
  *)
    ui "usage: $0 {apply|restore|status|webui-quick|toggle|changelog|restart-usf}"
    ui "       $0 profile {performance|performance_lite|balance|powersave}"
    ui "       $0 profile-status | watch {on|off|status}"
    ui "       $0 screenoff {powersave|balance|keep}"
    ui "       $0 games {add|remove|list} [package]"
    ui "action.sh/service.sh/uninstall.sh source this file as a library."
    exit 2
    ;;
  esac
  ;;
esac
