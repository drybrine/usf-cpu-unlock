#!/system/bin/sh
# Restore stock behavior before the module files are removed.
MODDIR=${0%/*}

# Stop the watcher first so it cannot re-apply a profile mid-teardown.
CONFIG_DIR=${USF_CONFIG_DIR:-/data/adb/.config/usf-cpu-unlock}
old=$(cat "$CONFIG_DIR/watcher.pid" 2>/dev/null)
if [ -n "$old" ] && [ -d "/proc/$old" ]; then
  case "$(tr -d '\0' < "/proc/$old/cmdline" 2>/dev/null)" in
    *usf_watcher*) kill "$old" 2>/dev/null ;;
  esac
fi
rm -f "$CONFIG_DIR/watcher.pid" 2>/dev/null

if [ -f "$MODDIR/usfcpu.sh" ]; then
  . "$MODDIR/usfcpu.sh"
  do_restore
fi
exit 0
