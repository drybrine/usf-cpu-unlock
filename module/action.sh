#!/system/bin/sh
# KernelSU Action button: toggle the USF CPU cap patch on/off.
MODDIR=${0%/*}
. "$MODDIR/usfcpu.sh"
if [ -n "$SRC" ] && is_mounted "$SRC"; then
  do_restore
else
  do_apply
fi
