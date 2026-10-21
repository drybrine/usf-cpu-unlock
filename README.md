# usf-cpu-unlock

A **KernelSU module** that reversibly disables the **Transsion USF skin-temperature CPU cap** on XOS devices (Infinix / Tecno / itel) — without touching any other thermal protection.

Built and verified on an **Infinix Note 60 (X6879, Dimensity 7400, USF 26.08.05.001)**.

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

## Install

Flash `usf-cpu-unlock-*.zip` from [Releases](../../releases) in your KernelSU manager. The installer checks for the Transsion config and mounts the patched file immediately.

**Temporary root (GhostLock):** install → **soft reboot**. The kernel (and with it root + the bind mount) stays alive; USF restarts with the framework and loads the patched config on its own.

**Permanent root (KernelSU at boot):** nothing else to do — `post-fs-data.sh` mounts the patch before USF ever starts.

## Usage

```sh
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh status'   # state + live ceilings
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh apply'    # mount + reload USF
su -c 'sh /data/adb/modules/usf-cpu-unlock/usfcpu.sh restore'  # back to stock
```

The **Action** button in the manager toggles apply/restore. Auto-apply on module load can be disabled with a `disable-auto` file in the module directory. `uninstall.sh` restores stock behavior before removal.

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
- Does **not** lock frequencies — governors behave normally, idle still idles

The device **can run hotter** under sustained load than XOS intends, and battery drain under load increases. That is the entire point — use your head and watch temperatures during long gaming sessions.

## Safety engineering

- The patcher (`patch_xml.awk`) refuses input it cannot rewrite safely (unterminated tags, `>` inside quoted values); nothing is mounted unless the patched file passes a separate verifier (`verify_xml.awk`) **and** a `<temp_config>` count check
- Process restarts target only PIDs whose `/proc/PID/cmdline` is exactly `com.transsion.usf` (re-read immediately before each kill)
- apply/restore are serialized with a lockfile; a second apply is a no-op
- Host-side test suite: `sh tests/run_tests.sh` (11 tests: pretty/minified/CRLF/single-quoted XML, decoy attribute names, idempotency, negative gates)

## Compatibility

Anything running a Transsion USF build that ships `tran_thermal.xml` under `/tr_product/etc/vconfig/tranusf/config/thermal/` or `/system_ext/etc/vconfig/tranusf/config/thermal/`. Verified end-to-end on USF 26.08.05.001 / Infinix Note 60 X6879. Other builds: the installer aborts safely if the config is missing, and the patch gates abort without changes if the XML differs from the expected shape.

## License

MIT — see [LICENSE](LICENSE). Provided as-is; you are responsible for your own device.
