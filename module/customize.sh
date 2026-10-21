#!/system/bin/sh
# shellcheck shell=sh disable=SC2154
# Installer script (KernelSU/Magisk). MODPATH/ui_print/abort are provided.
#
# The install itself applies the patch: customize.sh is the one hook that
# always runs with root at install time (module lifecycle scripts do NOT run
# on hot-install). We mount the patched config in MOUNT_ONLY mode here, so
# the user's flow is simply:  install -> SOFT REBOOT.
# A soft restart keeps the kernel (and with it root + the bind mount) alive
# while the framework restarts com.transsion.usf, which then reads the
# patched config at startup - no kill -9, no manual command.

ui_print "***********************************"
ui_print " usf-cpu-unlock"
ui_print "***********************************"
ui_print "Disables ONLY the Transsion USF"
ui_print "skin-thermal CPU cluster cap."
ui_print " - original tran_thermal.xml untouched"
ui_print " - runtime bind mount + USF reload"
ui_print " - fully reversible (restore/uninstall)"
ui_print " - junction/skin TJ protection kept"
ui_print ""

if [ ! -f /tr_product/etc/vconfig/tranusf/config/thermal/tran_thermal.xml ] \
   && [ ! -f /system_ext/etc/vconfig/tranusf/config/thermal/tran_thermal.xml ]; then
  ui_print "ERROR: tran_thermal.xml not found."
  ui_print "This module targets Transsion XOS builds"
  ui_print "(tested: Infinix Note 60 X6879, USF 26.08.05.001)."
  abort "Unsupported device."
fi

ui_print "Target config found."
ui_print ""

# Release any bind mount left active by a previous version (in-place
# upgrade): it is bound to the OLD module's patched file, which is about to
# be replaced. Without this, the mount would keep serving a deleted inode.
if [ -f /data/adb/modules/usf-cpu-unlock/usfcpu.sh ]; then
  ui_print "Releasing any mount from the previous version..."
  (
    . /data/adb/modules/usf-cpu-unlock/usfcpu.sh
    if [ -n "$SRC" ] && is_mounted "$SRC"; then
      do_restore >/dev/null 2>&1
    fi
  )
fi

ui_print "Mounting the patched config now (install-time apply)..."
MOUNT_ONLY=1
. "$MODPATH/usfcpu.sh"
MODDIR="$MODPATH"
if do_apply; then
  ui_print ""
  ui_print "*** Patch is mounted. NOW DO A SOFT REBOOT ***"
  ui_print "A soft restart keeps root AND the mount alive;"
  ui_print "USF restarts with the framework and loads the"
  ui_print "patched config on its own. No manual command."
  ui_print ""
  ui_print "(No soft reboot? Tap the Action button instead -"
  ui_print "it restarts USF for you.)"
else
  ui_print ""
  ui_print "WARN: install-time mount failed (see log below)."
  ui_print "After install, tap the Action button or run:"
  ui_print "  su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh apply'"
fi
ui_print ""
ui_print "Verify afterwards:"
ui_print "  su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh status'"
ui_print ""
ui_print "Kernel/junction thermal protection is NOT disabled."
ui_print "The device can run hotter under sustained load -"
ui_print "watch your temperatures."
