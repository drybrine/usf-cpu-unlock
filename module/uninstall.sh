#!/system/bin/sh
# Restore stock behavior before the module files are removed.
MODDIR=${0%/*}
if [ -f "$MODDIR/usfcpu.sh" ]; then
  . "$MODDIR/usfcpu.sh"
  do_restore
fi
exit 0
