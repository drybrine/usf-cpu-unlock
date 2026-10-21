#!/system/bin/sh
# Early-boot mount (standard KernelSU boot flow, permanent root): patch +
# bind-mount the config BEFORE com.transsion.usf ever starts, so USF reads
# the patched file at its first config load — no USF restart needed.
#
# NOTE: with GhostLock temporary root this stage never runs — root arrives
# after boot, ksud loads modules in late-load mode, and post-fs-data.sh is
# replaced by the late-load stage. service.sh covers that flow instead
# (mount + USF restart). Both are guarded by the same lock and
# "already applied" check, so they never conflict.
MODDIR=${0%/*}
[ -f "$MODDIR/disable-auto" ] && exit 0
MOUNT_ONLY=1
. "$MODDIR/usfcpu.sh"
do_apply >> "$MODDIR/apply.log" 2>&1
exit 0
