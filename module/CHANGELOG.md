# Changelog

## v1.1.0 (versionCode 7)

- **In-manager update support**: `module.prop` now carries an `updateJson`
  pointer — KernelSU/Magisk managers can detect and install new versions on
  their own (integer `versionCode` comparison; see `update.json` at the repo
  root).
- **`changelog` command**: prints the current version and the full text of
  `CHANGELOG.md` shipped inside the module.
- **Version reporting**: `status` shows the installed version (v1.0.5+).
- Module `README.md` now documents the update flow and the restore-before-
  upgrade note (a stale bind mount during an in-place upgrade is released
  automatically; the explicit `restore` recommendation remains for safety).
- No behavioral change to the patch itself: same zeroed `temp_config`
  attributes, same bind mount, same USF reload path, same protection scope.

## v1.0.5 (versionCode 6)

- `status` now prints the installed module version — makes version drift
  between an installed module and the latest release immediately visible.

## v1.0.4 (versionCode 5)

- **Install-time apply** via `customize.sh` (mount-only mode): the patched
  config is mounted during installation, so with temporary root (GhostLock)
  the whole flow is *install → soft reboot* — no manual command, no
  `kill -9` (the framework restarts USF and it reads the patched config at
  startup).
- `MOUNT_ONLY=1` mode in the core: mount without touching the running USF.

## v1.0.3 (versionCode 4)

- **`post-fs-data.sh`**: early-boot mount for permanent-root (KernelSU
  boot-time) installs — the config is patched before USF ever starts, so no
  USF restart is needed at all. With GhostLock (late-load) this stage never
  fires and `service.sh` handles it; both share the same lock and
  "already applied" guard.

## v1.0.2 (versionCode 3)

- Hardening from an independent review (no security or logic findings;
  hardening only):
  - awk patcher: exact element-name and attribute-name delimiter matching
    (`bigcpu=`, `<temp_configExtra>` are left untouched); a `>` inside a
    quoted attribute value is now rejected instead of silently truncating
    the tag span.
  - apply/restore serialized with a lockfile (auto-apply racing a manual
    Action tap can no longer stack two bind mounts).
  - `/proc/PID/cmdline` is re-read immediately before each `kill -9`
    (PID-reuse safety).
  - dispatch works when the script is invoked without a directory component.

## v1.0.0 (versionCode 1)

- Initial release. Zeroes the `cpu`/`clusterCpu0/1/2` attributes of every
  `<temp_config>` row in `tran_thermal.xml` (USF's own no-CPU-cap encoding),
  bind-mounts the patched file over the original (read-only) and reloads
  `com.transsion.usf`. Original file untouched, junction/skin-TJ/charging/
  GPU/brightness policy untouched, fully reversible via `restore`/uninstall.
