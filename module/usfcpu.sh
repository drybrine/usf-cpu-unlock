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
  dumpsys activity service com.transsion.usf.UsfMainService -thermal thermal_engine state 2>/dev/null
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
  engine_state | sed -n '/=== Thermal Engine State ===/,/=== End of Thermal Engine State ===/p' \
    | grep -E 'MTK thermal CPU limit support|Thermal CPU handle|Current temp config|tempLevel=|^ *cpu=|clusterCpu[012]='
  ui "cpufreq caps (max vs hardware max):"
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

# Dispatch only when executed directly. Callers that source this file as a
# library (action.sh / service.sh / uninstall.sh) invoke do_* functions
# themselves; "$0" there is the caller's path, not this script's.
case "$0" in
*usfcpu.sh)
  case "${1:-}" in
  apply)        do_apply ;;
  restore)      do_restore ;;
  status)       do_status ;;
  changelog)    do_changelog ;;
  toggle)
    if [ -n "$SRC" ] && is_mounted "$SRC"; then do_restore; else do_apply; fi
    ;;
  restart-usf)  restart_usf ;;
  *)
    ui "usage: $0 {apply|restore|status|toggle|changelog|restart-usf}"
    ui "action.sh/service.sh/uninstall.sh source this file as a library."
    exit 2
    ;;
  esac
  ;;
esac
