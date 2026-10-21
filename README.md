# usf-cpu-unlock

A **KernelSU module** that reversibly disables the **Transsion USF skin-temperature CPU cap** on XOS devices (Infinix / Tecno / itel) — and then actually *uses* the unlocked clocks with **Encore-style performance profiles** and an **auto game watcher**. No other thermal protection is touched.

Built and verified on an **Infinix Note 60 (X6879, Dimensity 7400, USF 26.08.05.001)**.

> Encore Tweaks is great, but on these devices its clock pinning fights the USF cap and loses. This module removes the cap *and* ships Encore's tweak set, so the two stop contradicting each other.

## The problem

XOS's `com.transsion.usf` thermal engine caps CPU cluster ceilings based on **virtual skin temperature**, long before the SoC itself is hot. On the Note 60, the stock ladder (`tran_thermal.xml`, default scene) steps the big cluster down like this:

| Skin temp | little / big (stock) |
|---|---|
| ≤ 36 °C | 2.0 / 2.6 GHz (hardware max) |
| 39–40 °C | 1.9 / 2.3 GHz |
| 41–42 °C | 1.8 / 2.2 GHz |
| 43–44 °C | 1.7 / 2.1 GHz |
| ≥ 45 °C | 1.6 / 2.0 GHz |

In a ~32 °C ambient that means the phone almost never holds its advertised clocks. This module removes that ladder.

## How it works

1. Copies the stock `tran_thermal.xml` and zeroes **only** the `cpu` / `clusterCpu0` / `clusterCpu1` / `clusterCpu2` attributes of every `<temp_config>` row. An all-zero row is USF's own "no CPU limit" encoding — its `applyCpuLimit()` releases the MediaTek PowerHAL thermal handle for such rows (verified by decompiling USF 26.08.05.001).
2. **Bind-mounts** the patched copy over the original path (remounted read-only). The original file on the partition is **never modified**.
3. USF is reloaded so it parses the patched config through its normal code path — either automatically at a soft reboot, via `kill -9` + framework restart (persistent app), or before USF even starts on permanent-root boot.

Everything else in the config — skin-control TJ targets, brightness/HBM, charging, GPU, FPS, kernel thermal zones, junction protection — is left byte-identical.

## Performance profiles (ported from Encore)

Removing the cap only raises the ceiling; the governor still has to climb to
it. The bundled profiler (`scripts/usf_profiler.sh`, adapted from
[Encore Tweaks](https://github.com/Rem01Gaming/encore), Apache-2.0) does the
climbing:

| Profile | What it does |
|---|---|
| `performance` | Governor pinned to `performance`, PPM min/max locked to hardware max, FPSGO off, DDR boost on, GPU fixed to max OPP, battery-OC throttle stopped, eara thermal off |
| `performance_lite` | Same, but pins the *mid* OPP instead of max — cooler and more efficient for lighter games |
| `balance` | Stock governor, PPM limits released, FPSGO back to 2, eara thermal re-enabled |
| `powersave` | Balance + battery saver + GPU to minimum OPP |
| `perfcommon` | Runs with every boost: I/O, TCP (bbr3 → cubic), scheduler/VM latency knobs, `sched_lib_name` for game engines |

MediaTek paths are the primary target (PPM, `policy_status`, `gpufreqv2`,
`mtk-dvfsrc`, GED, `eara_thermal`); Snapdragon, Exynos, Unisoc and Tensor
branches are carried over from Encore and selected by SoC detection.

### Auto game watcher

`scripts/usf_watcher.sh` replaces Encore's `encored` daemon with plain sh, so
it also runs under GhostLock temporary root:

- polls the foreground package (top-app cpuset + `oom_score_adj`, no dumpsys
  on the hot path)
- game in the list → `performance`; anything else → `balance`; screen off →
  `powersave`
- state-file driven, so it never re-applies the same profile twice
- a **manual pick wins**: choosing a profile from the WebUI or the CLI pins it
  while the current app stays in front (the pin expires after 2 h as a safety
  net). Switching to another app hands control back to the watcher, and
  `watch on|off` clears the pin immediately
- **screen-off behaviour is configurable** — `Saver` (default), `Balance`, or
  `Keep`. Use `Keep` if the powersave governor makes unlocking stutter:
  `su -c '... usfcpu.sh screenoff keep'`
- screen state is read from the backlight sysfs node, not `dumpsys power`, and
  the power service is only consulted on a transition — so the watcher is
  cheap enough to poll every 2 s and the profile is back before the lock
  screen is usable

```sh
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh games add com.mobile.legends'
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh games list'
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh profile performance'
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh watch off'
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh profile-status'
```

Config lives in `/data/adb/.config/usf-cpu-unlock` (`gamelist.txt`,
`watcher.state`, `watcher.disabled`, `watcher.interval`). Opt out of the
profiler entirely with a `disable-profiler` file in the module directory.

## Install

Flash `usf-cpu-unlock-*.zip` from [Releases](../../releases) in your KernelSU manager. The installer checks for the Transsion config and mounts the patched file immediately.

**The patch applies itself in every flow — there is no Apply button:**

| Flow | What happens |
|---|---|
| Install (any root) | `customize.sh` mounts the patched config immediately |
| Soft reboot after install | Kernel stays alive: root + mount persist, USF reloads the patched config |
| Full reboot, permanent root | `post-fs-data.sh` + `service.sh` re-apply at boot, before/around USF start |
| Full reboot, temporary root (GhostLock) | Re-run GhostLock; `service.sh` auto-applies when ksud loads the module |

The **Restore** action in the WebUI/CLI is the single escape hatch back to stock. Auto-apply can be disabled with a `disable-auto` file in the module directory.

## Usage

```sh
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh status'   # state + live ceilings
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh restore'  # back to stock
```

The manager **Action** button toggles apply/restore. `uninstall.sh` stops the
watcher and restores stock behavior before removal.

### WebUI

The module ships a WebUI — open it from the module's page in the manager
(KernelSU / APatch / MMRL). **Restore** / **Restart USF** one-tap actions, a
live status card (patch state, per-cluster ceilings vs hardware max, engine
level, USF pid), a **performance card** (segmented profile picker, watcher
switch, game-list count and add field) and a copyable command log behind a
toggle. There is no Apply action — the patch applies itself on install and on
every module load; the card paints instantly from a sysfs-only quick status
while engine details (dumpsys) fill in afterwards without blocking. Single
self-contained `webroot/index.html` — no bundler, no network access.

A working apply looks like this:

```text
Thermal CPU handle: 0
Current temp config: tempLevel=43 cpu=0 clusterCpu0=0 clusterCpu1=0 ...
policy0: max=2000000 hw=2000000
policy4: max=2600000 hw=2600000
```

Note the `tempLevel=43`: the skin is already in a band whose stock caps would be 1.7/2.1 GHz — and the ceilings stay at hardware max.

## Reboot behavior

| | Soft reboot | Full reboot |
|---|---|---|
| Root (GhostLock) | kept | lost — re-run GhostLock |
| Bind mount | kept | gone |
| After | USF reads patched config | stock behavior; module auto-applies when root returns |

The module writes **no persistent state**: no `persist.*` properties, no partition writes. Its files live in `/data/adb/modules/usf-cpu-unlock` and are inert without root.

## What it does NOT do

- Does **not** disable kernel thermal zones, trip points or junction protection
- Does **not** stop `thermal_core`, `thermald` or `vendor.thermal-mediatek`
- Does **not** touch charging, GPU, brightness or skin-control TJ policy
- Does **not** disable kernel thermal zones from the profiler — `performance` sets the least intrusive `step_wise` governor and turns off MediaTek's *userspace* limiters (PPM, FPSGO, eara) only while a game is in the foreground; `balance` turns them back on
- Does **not** lock frequencies permanently — the watcher returns to `balance` when the game closes

The device **can run hotter** under sustained load than XOS intends, and battery drain under load increases. That is the entire point — use your head and watch temperatures during long gaming sessions.

## Safety engineering

- The patcher (`patch_xml.awk`) refuses input it cannot rewrite safely (unterminated tags, `>` inside quoted values); nothing is mounted unless the patched file passes a separate verifier (`verify_xml.awk`) **and** a `<temp_config>` count check
- Process restarts target only PIDs whose `/proc/PID/cmdline` is exactly `com.transsion.usf` (re-read immediately before each kill)
- apply/restore are serialized with a lockfile; a second apply is a no-op
- Host-side test suite: `sh tests/run_tests.sh` (16 tests: pretty/minified/CRLF/single-quoted XML, decoy attribute names, idempotency, negative gates, CLI surface), `sh tests/test_profiler.sh` (12, profiler in dry-run mode), `sh tests/test_watcher.sh` (10, watcher decision logic via env hooks), `node tests/test_webui.js` (37 assertions against the WebUI's actual script with a stubbed `ksu` bridge)

## Compatibility

Anything running a Transsion USF build that ships `tran_thermal.xml` under `/tr_product/etc/vconfig/tranusf/config/thermal/` or `/system_ext/etc/vconfig/tranusf/config/thermal/`. Verified end-to-end on USF 26.08.05.001 / Infinix Note 60 X6879. Other builds: the installer aborts safely if the config is missing, and the patch gates abort without changes if the XML differs from the expected shape.

## License

MIT — see [LICENSE](LICENSE). Provided as-is; you are responsible for your own device.
