#!/system/bin/sh
# Auto-apply when the module is loaded AFTER boot — this is the stage that
# fires with GhostLock temporary root (ksud loads modules in late-load mode,
# where post-fs-data.sh is replaced by the late-load stage; service.sh still
# runs). Mounts the patched config, restarts USF so it reloads, then starts
# the performance watcher (Encore-style: game detected -> performance
# profile, else balance).
# In the standard permanent-root boot flow, post-fs-data.sh has already
# mounted the config before USF started, so the mount step is a no-op
# ("already applied"). Disable the USF patch with a file named "disable-auto"
# in this directory; disable only the profiler with "disable-profiler".
MODDIR=${0%/*}
[ -f "$MODDIR/disable-auto" ] && exit 0
(
  . "$MODDIR/usfcpu.sh"
  do_apply

  [ -f "$MODDIR/disable-profiler" ] && exit 0

  CONFIG_DIR=${USF_CONFIG_DIR:-/data/adb/.config/usf-cpu-unlock}
  mkdir -p "$CONFIG_DIR" 2>/dev/null
  [ -f "$CONFIG_DIR/gamelist.txt" ] || : > "$CONFIG_DIR/gamelist.txt"

  # A manual profile pick is only a starting point: the watcher owns the
  # profile from here on.
  [ -f "$CONFIG_DIR/watcher.disabled" ] && exit 0

  old=$(cat "$CONFIG_DIR/watcher.pid" 2>/dev/null)
  if [ -n "$old" ] && [ -d "/proc/$old" ]; then
    case "$(tr -d '\0' < "/proc/$old/cmdline" 2>/dev/null)" in
      *usf_watcher*) exit 0 ;;
    esac
  fi

  MODULE_DIR="$MODDIR" nohup sh "$MODDIR/scripts/usf_watcher.sh" \
    >> "$MODDIR/watcher.log" 2>&1 &
) >> "$MODDIR/apply.log" 2>&1 &
exit 0
