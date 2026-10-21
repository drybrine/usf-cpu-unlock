# Changelog

## v2.2.0 (versionCode 24)

Performance pass on the WebUI and on the profiler — same features, far less
work per interaction.

- **A refresh is one bridge call instead of three.** `webui-fast` returns the
  whole card (mount state, per-cluster ceilings, profile, watcher, screen-off
  mode, governor, gamelist count) from sysfs and state files only. Measured on
  a page with phone-like latencies: the card settles at **122 ms instead of
  1623 ms**, in 1 render instead of 3.
- **The engine dump is cached.** It runs `dumpsys` (1-6 s) and only feeds one
  detail row. It is fetched lazily, reused for 60 s, and never blocks a
  repaint. `usfcpu.sh engine` exposes it for the CLI.
- **A tap is one bridge call instead of four.** Every action now prints a full
  status block, so the card is repainted from the action's own output. The old
  flow re-ran `webui-quick` + `profile-status` + `status` after every tap.
- **The profiler stopped forking.** `chmod` is only attempted when the node is
  not already writable (43 of the 60 forks a `performance` apply used to make),
  frequency tables are parsed in shell instead of `tr | sort | head`, GPU paths
  are globbed once instead of `find`-ed per call, and the PPM/congestion loops
  match in shell instead of `grep`. Non-chmod forks per apply: **17 → 2**.
- **Fixed**: with no Mali node present the balance/powersave profiles wrote to
  a bare `/power_policy` (built from an empty variable). Writes now require a
  real GPU path.
- The profiler is now sourceable, so its helpers are unit-tested directly
  (`apply`, `freq_max/min/mid`); the host suite also gates the fork budget.
- Tests: 24 shell + 17 profiler + 22 watcher + 58 webui.

## v2.1.1 (versionCode 23)

Fixes the WebUI getting stuck on its busy label after a profile switch.

- **The bridge call now has a timeout (20 s).** `ksu.exec` is not guaranteed to
  call back — the profiler writes dozens of sysfs nodes, and a slow or busy
  manager can swallow the callback. The promise never settled, so `busy`
  stayed true forever: the hero sat on "Applying balance…", every button
  stayed disabled and no refresh ever ran.
- **A busy label can no longer survive the action.** Clearing the busy flag now
  repaints the hero from the last known state instead of leaving whatever text
  the spinner had.
- **Taps paint immediately.** The profile pill, the segment highlight and the
  governor hint update the moment you tap, before the shell command answers,
  then reconcile with real status. Same for the screen-off picker and the
  watcher switch. The progress spinner is preserved across those repaints.
- **The card refreshes itself** when the page becomes visible again and every
  20 s while it is on screen, so a background watcher switch shows up without
  pressing Refresh.
- WebUI harness now mirrors real DOM semantics for `textContent`/`innerHTML`
  (assigning one clears the other), so stale-markup bugs are actually caught.

## v2.1.0 (versionCode 22)

- **Screen-off behaviour is now a setting**: `Saver` (default), `Balance`, or
  `Keep`. `Keep` leaves the profile untouched when the panel turns off, which
  removes the powersave-governor stutter when unlocking.
  CLI: `usfcpu.sh screenoff {powersave|balance|keep}`; also a picker in the
  WebUI performance card and a `screenoff` line in `profile-status`.
- **Faster unlock**: the watcher no longer runs `dumpsys power` on every poll
  (that call competes with the system exactly while the lock screen lifts).
  Screen state now comes from the backlight sysfs node, and the power service
  is only consulted once per transition - which also stops a dimmed panel or
  AOD from being mistaken for "screen off".
- While the panel is off the watcher polls that cheap node once a second, so
  the profile is already back before the lock screen is usable, instead of up
  to a full interval later. Default poll interval is now 2 s (was 5 s).
- `status` no longer comes back empty: the engine dump is wrapped in a 6 s
  timeout and reports why it is missing instead of printing nothing.
- Value rows in the WebUI no longer break mid-word (`performan` / `ce`).

## v2.0.1 (versionCode 21)

Fixes manual profile switching from the WebUI.

- **A profile tap now actually sticks.** The watcher used to re-apply its own
  decision (usually `balance`) on the next poll — about 5 s after the tap — so
  the card snapped straight back. A manual pick now writes a hold scoped to
  the foreground app: the watcher leaves it alone while that app stays in
  front, and hands control back when you switch to another app. Screen-off
  still forces `powersave` (safety, not preference), and the hold expires
  after 2 h so a wedged foreground detector cannot pin a profile forever.
  `watch on` / `watch off` clear the hold immediately.
- **The card repaints after an action.** `action()` called `refresh()` while
  the busy flag was still set, and `refresh()` bails out while busy — so the
  card kept showing the previous profile until you pressed Refresh yourself.
- **The card fills in as data arrives.** Quick status paints first, then
  `profile-status` (sysfs/state file, instant), then the dumpsys-backed
  engine dump. Each response merges into the rendered state instead of
  replacing it, so the slow dumpsys no longer delays the profile pill.
- `profile-status` now reports the live CPU governor and the PPM max limit,
  and the WebUI shows the governor next to the profile name — so a profile
  that did not actually take effect is visible instead of guessed.

## v2.0.0 (versionCode 20)

**Encore Tweaks merged in.** The module no longer just removes the USF CPU
cap — it now carries Encore's tweak set, so the unlocked clocks actually get
*used* instead of idling at a conservative governor.

- **Performance profiles** (ported from Encore, Apache-2.0):
  `performance` / `performance_lite` / `balance` / `powersave` /
  `perfcommon`. Covers MediaTek PPM limits and policy_status, FPSGO, DDR
  boost + dvfsrc, GED KPI, GPU OPP/power-limiter, Mali power policy,
  battery-OC throttle, eara thermal, plus Snapdragon / Exynos / Unisoc /
  Tensor branches.
- **perfcommon** runs with every boost: I/O (iostats, add_random,
  read_ahead, nr_requests), TCP congestion control (bbr3 → cubic fallback),
  TCP low-latency/ECN/fastopen, scheduler latency knobs, VM tuning, and
  `sched_lib_name` so game engines see the full CPU capability.
- **Auto game watcher** (replaces Encore's `encored` daemon, plain sh so it
  works under GhostLock): polls the foreground package, applies
  `performance` while a listed game is on screen, `balance` otherwise,
  `powersave` when the screen is off. State-file driven, so it never
  re-applies the same profile twice.
- **Game list** management: `games add|remove|list` plus an inline field in
  the WebUI. Seeded empty on install.
- **WebUI**: new performance card — segmented profile picker, watcher switch,
  game-list count and add field. Still no Apply button; the USF patch keeps
  applying itself.
- The profiler is opt-out (`disable-profiler` in the module dir) and the
  watcher can be turned off from the WebUI or `watch off`.

Thermal safety is unchanged: only the USF skin-thermal *CPU cluster cap* is
removed. Kernel junction protection, trip points, skin-control TJ targets and
battery/charging policy stay stock.

## v1.5.0 (versionCode 11)

- **Fully automatic apply — the Apply button is gone.** The patch now mounts
  itself in every flow with no user action: install (customize.sh), module
  load (service.sh), and boot (post-fs-data.sh + service.sh). The WebUI's
  remaining actions are Restore / Restart USF / Refresh / log / copy;
  **Restore** is the single escape hatch back to stock. The `apply` CLI
  subcommand stays for the Action toggle and edge cases.
- WebUI: footer text removed for a cleaner card.

## v1.4.0 (versionCode 10)

- **Material-3 WebUI redesign** (Encore Tweaks-inspired): status hero card on
  a secondary-container surface with a circular state icon and ACTIVE/STOCK
  chip, info card as M3 list rows (icon + label + mono value), pill-shaped
  filled/tonal buttons with a Material ripple, log panel restyled to the
  lowest surface container. All M3 color tokens are inlined with Encore's
  dark-pink defaults and every use reads `var(--token, fallback)` — a
  Material-You manager can re-theme the page by overriding the CSS variables.
- Zero functional changes: same ksu.exec bridge (callback + promise
  fallback), same webui-quick → status two-stage load, same status parsing,
  all six actions, busy states, hidden-by-default log. The 23-assertion
  WebUI harness and the 11-test shell suite pass unchanged on the new file.

## v1.3.0 (versionCode 9)

- **Instant WebUI paint**: the page now loads in two stages. A new
  `webui-quick` command (sysfs-only: version, mount state, cpufreq
  ceilings — no dumpsys, no /proc scan) renders the status card in
  milliseconds; the full engine dump (`dumpsys`, the actual slow part)
  follows in the background and only fills in the detail fields.
  Buttons are usable as soon as the quick card lands.
- **Log collapsed by default**: the command log no longer renders on
  open — it sits behind a Show log / Hide log toggle and keeps
  collecting while hidden.
- WebUI harness extended to 23 assertions with staged timing (quick at
  5ms vs full at 40ms) plus log-toggle coverage.

## v1.2.0 (versionCode 8)

- **WebUI**: the module now ships `webroot/index.html` — open it from the
  manager's module page (KernelSU / APatch / MMRL). One-tap Apply / Restore /
  Restart USF, live status card (patch state, per-cluster ceilings vs
  hardware max, USF engine level + pid) and a copyable command log.
  Self-contained single file (no bundler); uses the documented
  `ksu.exec(cmd, optionsJSON, callbackName)` contract with a promise-style
  fallback for managers that return one.
- Host-side WebUI test suite (`node tests/test_webui.js`): runs the page's
  actual script under Node with stubbed `window/ksu/document` against the
  real `status` output format — 15 assertions covering active and stock
  states.

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
