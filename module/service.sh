#!/system/bin/sh
# Auto-apply when the module is loaded AFTER boot — this is the stage that
# fires with GhostLock temporary root (ksud loads modules in late-load mode,
# where post-fs-data.sh is replaced by the late-load stage; service.sh still
# runs). Mounts the patched config and restarts USF so it reloads.
# In the standard permanent-root boot flow, post-fs-data.sh has already
# mounted the config before USF started, so this is a no-op ("already
# applied"). Disable with a file named "disable-auto" in this directory.
MODDIR=${0%/*}
[ -f "$MODDIR/disable-auto" ] && exit 0
(
  . "$MODDIR/usfcpu.sh"
  do_apply
) >> "$MODDIR/apply.log" 2>&1 &
exit 0
