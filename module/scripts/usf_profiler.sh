#!/system/bin/sh
#
# Portions Copyright (C) 2024-2026 Rem01Gaming (Encore Tweaks, Apache-2.0)
# Adapted and trimmed for usf-cpu-unlock by drybrine.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Device performance profiler for usf-cpu-unlock. Ported from Encore Tweaks'
# encore_profiler.sh so this module gets Encore's tweak set WITHOUT Encore's
# ceiling problem: this module removes the Transsion USF skin-thermal CPU cap
# (see usfcpu.sh), the profiler handles everything else.
#
# Profiles: performance | performance_lite | balance | powersave | perfcommon
# Dry run:  USF_PROFILER_DRYRUN=1 prints every action instead of writing
#           (used by the host-side test suite).

# shellcheck disable=SC2317

###################################
# Variables
###################################

MODULE_CONFIG="/data/adb/.config/usf-cpu-unlock"
DRYRUN=${USF_PROFILER_DRYRUN:-0}

# SoC recognition: 1=MTK 2=QCom 3=Exynos 4=Unisoc 5=Tensor 6=Tegra
# An exported SOC wins (host test hook); else the config file; else detection.
if [ -z "${SOC:-}" ]; then
    if [ -r "$MODULE_CONFIG/soc_recognition" ]; then
        SOC=$(cat "$MODULE_CONFIG/soc_recognition" 2>/dev/null)
    else
        case "$(getprop ro.board.platform 2>/dev/null)" in
            mt*) SOC=1 ;;
            *)   SOC=1 ;;  # default: MediaTek (this module targets Transsion MTK)
        esac
    fi
fi

# Default CPU governor (restored by balance/powersave; set by service.sh
# from the boot-time governor, falls back to schedutil).
DEFAULT_CPU_GOV=${DEFAULT_CPU_GOV:-schedutil}
POWERSAVE_GOV=${POWERSAVE_GOV:-powersave}

###################################
# Common functions
###################################

log() {
    printf '[profiler] %s\n' "$*"
}

# Structural existence check. In DRYRUN the host has none of the device's
# nodes, so /proc, /sys and /dev paths are treated as present and every
# guarded branch is exercised (this is what makes the whole surface
# host-testable); on device the check is real.
have() {
    if [ "$DRYRUN" = "1" ]; then
        case "$1" in
            /proc/*|/sys/*|/dev/*) return 0 ;;
        esac
    fi
    [ -e "$1" ]
}

# DRYRUN-aware write: value, node, [must-exist]
apply() {
    [ -n "$2" ] || return 1
    if [ "$DRYRUN" = "1" ]; then
        printf '[dry] %s <- %s\n' "$2" "$1"
        return 0
    fi
    [ -f "$2" ] || return 1
    chmod 644 "$2" >/dev/null 2>&1
    echo "$1" > "$2" 2>/dev/null
}

write() {
    [ -n "$2" ] || return 1
    if [ "$DRYRUN" = "1" ]; then
        printf '[dry] %s <- %s\n' "$2" "$1"
        return 0
    fi
    [ -f "$2" ] || return 1
    chmod 644 "$2" >/dev/null 2>&1
    echo "$1" > "$2" 2>/dev/null
}

change_cpu_gov() {
    if [ "$DRYRUN" = "1" ]; then
        printf '[dry] scaling_governor (all policies) <- %s\n' "$1"
        return 0
    fi
    chmod 644 /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null
    chmod 644 /sys/devices/system/cpu/cpufreq/policy*/scaling_governor 2>/dev/null
    for p in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor \
             /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$p" ] && echo "$1" > "$p" 2>/dev/null
    done
}

###################################
# Frequency fetching
###################################

# Freq-table readers. In DRYRUN an unreadable table yields a placeholder so
# the dry-run output stays clean (nothing is ever written in dry-run anyway).
_whichfreq() {  # _whichfreq <sort-order> <file>
    if [ -r "$2" ]; then
        tr ' ' '\n' < "$2" | grep -v '^[[:space:]]*$' | sort "$1" | head -n 1
    elif [ "$DRYRUN" = "1" ]; then
        printf '999999\n'
    fi
}
which_maxfreq() { _whichfreq -nr "$1"; }
which_minfreq() { _whichfreq -n "$1"; }
which_midfreq() {
    total_opp=$(wc -w < "$1" 2>/dev/null)
    [ -n "$total_opp" ] && [ "$total_opp" -gt 0 ] || { which_minfreq "$1"; return; }
    mid_opp=$(((total_opp + 1) / 2))
    mid=$(tr ' ' '\n' < "$1" | grep -v '^[[:space:]]*$' | sort -nr | head -n "$mid_opp" | tail -n 1)
    [ -n "$mid" ] && { printf '%s\n' "$mid"; return; }
    which_minfreq "$1"
}

mtk_gpufreq_minfreq_index() { awk -F'[][]' '{print $2}' "$1" 2>/dev/null | tail -n 1; }

###################################
# CPU frequency profiles
###################################

cpufreq_ppm_max_perf() {
    cluster=-1
    for path in /sys/devices/system/cpu/cpufreq/policy*; do
        cluster=$((cluster + 1))
        cpu_maxfreq=$(cat "$path/cpuinfo_max_freq" 2>/dev/null) || continue
        write "$cluster $cpu_maxfreq" /proc/ppm/policy/hard_userlimit_max_cpu_freq

        if [ "$LITE_MODE" -eq 1 ]; then
            cpu_midfreq=$(which_midfreq "$path/scaling_available_frequencies")
            write "$cluster $cpu_midfreq" /proc/ppm/policy/hard_userlimit_min_cpu_freq
        else
            write "$cluster $cpu_maxfreq" /proc/ppm/policy/hard_userlimit_min_cpu_freq
        fi
    done
}

cpufreq_max_perf() {
    for path in /sys/devices/system/cpu/cpu*/cpufreq; do
        [ -f "$path/cpuinfo_max_freq" ] || continue
        cpu_maxfreq=$(cat "$path/cpuinfo_max_freq")
        apply "$cpu_maxfreq" "$path/scaling_max_freq"
        if [ "$LITE_MODE" -eq 1 ]; then
            cpu_midfreq=$(which_midfreq "$path/scaling_available_frequencies" 2>/dev/null)
            [ -n "$cpu_midfreq" ] || cpu_midfreq=$(cat "$path/cpuinfo_min_freq" 2>/dev/null)
            [ -n "$cpu_midfreq" ] && apply "$cpu_midfreq" "$path/scaling_min_freq"
        else
            apply "$cpu_maxfreq" "$path/scaling_min_freq"
        fi
    done
}

cpufreq_ppm_unlock() {
    cluster=0
    for path in /sys/devices/system/cpu/cpufreq/policy*; do
        cpu_maxfreq=$(cat "$path/cpuinfo_max_freq" 2>/dev/null) || continue
        cpu_minfreq=$(cat "$path/cpuinfo_min_freq" 2>/dev/null)
        write "$cluster $cpu_maxfreq" /proc/ppm/policy/hard_userlimit_max_cpu_freq
        write "$cluster $cpu_minfreq" /proc/ppm/policy/hard_userlimit_min_cpu_freq
        cluster=$((cluster + 1))
    done
}

cpufreq_unlock() {
    for path in /sys/devices/system/cpu/cpu*/cpufreq; do
        [ -f "$path/cpuinfo_max_freq" ] || continue
        write "$(cat "$path/cpuinfo_max_freq")" "$path/scaling_max_freq"
        write "$(cat "$path/cpuinfo_min_freq")" "$path/scaling_min_freq"
    done
}

###################################
# devfreq helpers
###################################

devfreq_max_perf() {
    have "$1/available_frequencies" || return 1
    max_freq=$(which_maxfreq "$1/available_frequencies")
    apply "$max_freq" "$1/max_freq"
    apply "$max_freq" "$1/min_freq"
}

devfreq_mid_perf() {
    have "$1/available_frequencies" || return 1
    apply "$(which_maxfreq "$1/available_frequencies")" "$1/max_freq"
    apply "$(which_midfreq "$1/available_frequencies")" "$1/min_freq"
}

devfreq_unlock() {
    have "$1/available_frequencies" || return 1
    write "$(which_maxfreq "$1/available_frequencies")" "$1/max_freq"
    write "$(which_minfreq "$1/available_frequencies")" "$1/min_freq"
}

devfreq_min_perf() {
    have "$1/available_frequencies" || return 1
    freq=$(which_minfreq "$1/available_frequencies")
    apply "$freq" "$1/min_freq"
    apply "$freq" "$1/max_freq"
}

###################################
# Device-specific performance profiles
###################################

mediatek_performance() {
    # PPM thermal/power policies off (the clamp lives here on old kernels)
    if have /proc/ppm; then
        grep -E 'PWR_THRO|THERMAL' /proc/ppm/policy_status 2>/dev/null | while read -r row; do
            apply "$(printf %s "$row" | cut -c2) 0" /proc/ppm/policy_status
        done
    fi

    # FPSGO forced off
    apply 0 /sys/kernel/fpsgo/common/force_onoff

    # MTK CCI + power mode
    apply 1 /proc/cpufreq/cpufreq_cci_mode
    apply 3 /proc/cpufreq/cpufreq_power_mode

    # DDR boost
    apply 1 /sys/devices/platform/boot_dramboost/dramboost/dramboost

    # GED KPI off
    apply 0 /sys/module/sspm_v3/holders/ged/parameters/is_GED_KPI_enabled

    # GPU: fix to max OPP
    apply -1 /proc/gpufreqv2/fix_target_opp_index
    if have /proc/gpufreqv2; then
        apply 0 /proc/gpufreqv2/fix_target_opp_index
    else
        gpu_freq=$(sed -n 's/.*freq = \([0-9]\{1,\}\).*/\1/p' /proc/gpufreq/gpufreq_opp_dump 2>/dev/null | head -n 1)
        [ -n "$gpu_freq" ] && apply "$gpu_freq" /proc/gpufreq/gpufreq_opp_freq
    fi

    # GPU power limiter off
    have /proc/gpufreq/gpufreq_power_limited && {
        for setting in ignore_batt_oc ignore_batt_percent ignore_low_batt ignore_thermal_protect ignore_pbm_limited; do
            apply "$setting 1" /proc/gpufreq/gpufreq_power_limited
        done
    }

    # Mali power policy
    mali_sysfs=$(find /sys/devices/platform/ -iname '*.mali' -print -quit 2>/dev/null)
    [ -n "$mali_sysfs" ] && apply always_on "$mali_sysfs/power_policy"

    # Battery over-current throttle: stop
    apply 'stop 1' /proc/mtk_batoc_throttling/battery_oc_protect_stop

    # DRAM / DVFS
    if [ -z "${USF_NO_DDR_TWEAK:-}" ]; then
        apply 0 /sys/kernel/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp
        for path in /sys/devices/platform/*.dvfsrc; do
            [ -e "$path" ] && apply 0 "$path/helio-dvfsrc/dvfsrc_req_ddr_opp"
        done
        if [ "$LITE_MODE" -eq 0 ]; then
            devfreq_max_perf /sys/class/devfreq/mtk-dvfsrc-devfreq
        else
            devfreq_mid_perf /sys/class/devfreq/mtk-dvfsrc-devfreq
        fi
    fi

    # Eara thermal off
    apply 0 /sys/kernel/eara_thermal/enable
}

snapdragon_performance() {
    if [ -z "${USF_NO_DDR_TWEAK:-}" ]; then
        for path in /sys/class/devfreq/*memlat* /sys/class/devfreq/*latfloor* /sys/class/devfreq/*ddr-lat*; do
            [ -e "$path" ] || continue
            if [ "$LITE_MODE" -eq 0 ]; then devfreq_max_perf "$path"; else devfreq_mid_perf "$path"; fi
        done
        for component in DDR LLCC L3; do
            path="/sys/devices/system/cpu/bus_dcvs/$component"
            [ -d "$path" ] || continue
            if [ "$LITE_MODE" -eq 0 ]; then
                devfreq_max_perf "$path"
            else
                devfreq_mid_perf "$path"
            fi
        done
    fi

    gpu_path=/sys/class/kgsl/kgsl-3d0/devfreq
    if [ "$LITE_MODE" -eq 0 ]; then
        devfreq_max_perf "$gpu_path"
        apply 0 /sys/class/kgsl/kgsl-3d0/min_pwrlevel
        apply 0 /sys/class/kgsl/kgsl-3d0/max_pwrlevel
    else
        devfreq_unlock "$gpu_path"
    fi

    apply 0 /sys/class/kgsl/kgsl-3d0/bus_split
    apply 1 /sys/class/kgsl/kgsl-3d0/force_clk_on
}

exynos_performance() {
    gpu_path=/sys/kernel/gpu
    have "$gpu_path" || return 0
    freq_node=""
    [ -f "$gpu_path/gpu_available_frequencies" ] && freq_node="$gpu_path/gpu_available_frequencies"
    [ -z "$freq_node" ] && [ -f "$gpu_path/gpu_freq_table" ] && freq_node="$gpu_path/gpu_freq_table"
    [ -n "$freq_node" ] || return 0
    max_freq=$(which_maxfreq "$freq_node")
    apply "$max_freq" "$gpu_path/gpu_max_clock"
    if [ "$LITE_MODE" -eq 0 ]; then
        apply "$max_freq" "$gpu_path/gpu_min_clock"
    else
        apply "$(which_minfreq "$freq_node")" "$gpu_path/gpu_min_clock"
    fi

    mali_sysfs=$(find /sys/devices/platform/ -iname '*.mali' -print -quit 2>/dev/null)
    [ -n "$mali_sysfs" ] && apply always_on "$mali_sysfs/power_policy"

    if [ -z "${USF_NO_DDR_TWEAK:-}" ]; then
        for path in /sys/class/devfreq/*devfreq_mif*; do
            [ -e "$path" ] || continue
            if [ "$LITE_MODE" -eq 1 ]; then devfreq_mid_perf "$path"; else devfreq_max_perf "$path"; fi
        done
    fi
}

unisoc_performance() {
    gpu_path=$(find /sys/class/devfreq/ -type d -iname '*.gpu' -print -quit 2>/dev/null)
    [ -n "$gpu_path" ] || return 0
    if [ "$LITE_MODE" -eq 0 ]; then devfreq_max_perf "$gpu_path"; else devfreq_unlock "$gpu_path"; fi
}

tensor_performance() {
    gpu_path=$(find /sys/devices/platform/ -type d -iname '*.mali' -print -quit 2>/dev/null)
    [ -n "$gpu_path" ] || return 0
    max_freq=$(which_maxfreq "$gpu_path/available_frequencies")
    apply "$max_freq" "$gpu_path/scaling_max_freq"
    if [ "$LITE_MODE" -eq 0 ]; then
        apply "$max_freq" "$gpu_path/scaling_min_freq"
    else
        apply "$(which_minfreq "$gpu_path/available_frequencies")" "$gpu_path/scaling_min_freq"
    fi
    apply always_on "$gpu_path/power_policy"
}

###################################
# Device-specific balance profiles
###################################

mediatek_normal() {
    if have /proc/ppm; then
        grep -E 'PWR_THRO|THERMAL' /proc/ppm/policy_status 2>/dev/null | while read -r row; do
            apply "$(printf %s "$row" | cut -c2) 1" /proc/ppm/policy_status
        done
    fi

    apply 2 /sys/kernel/fpsgo/common/force_onoff
    apply 0 /proc/cpufreq/cpufreq_cci_mode
    apply 0 /proc/cpufreq/cpufreq_power_mode
    apply 0 /sys/devices/platform/boot_dramboost/dramboost/dramboost
    apply 2 /sys/devices/system/cpu/eas/enable
    apply 1 /sys/module/sspm_v3/holders/ged/parameters/is_GED_KPI_enabled

    write 0 /proc/gpufreq/gpufreq_opp_freq
    write -1 /proc/gpufreqv2/fix_target_opp_index
    if have /proc/gpufreqv2; then
        min_oppfreq=$(mtk_gpufreq_minfreq_index /proc/gpufreqv2/gpu_working_opp_table)
    else
        min_oppfreq=$(mtk_gpufreq_minfreq_index /proc/gpufreq/gpufreq_opp_dump)
    fi
    [ -n "$min_oppfreq" ] && apply "$min_oppfreq" /sys/kernel/ged/hal/custom_boost_gpu_freq

    have /proc/gpufreq/gpufreq_power_limited && {
        for setting in ignore_batt_oc ignore_batt_percent ignore_low_batt ignore_thermal_protect ignore_pbm_limited; do
            apply "$setting 0" /proc/gpufreq/gpufreq_power_limited
        done
    }

    mali_sysfs=$(find /sys/devices/platform/ -iname '*.mali' -print -quit 2>/dev/null)
    if grep -q adaptive "$mali_sysfs/power_policy" 2>/dev/null; then
        apply adaptive "$mali_sysfs/power_policy"
    else
        apply coarse_demand "$mali_sysfs/power_policy"
    fi

    apply 'stop 0' /proc/mtk_batoc_throttling/battery_oc_protect_stop

    if [ -z "${USF_NO_DDR_TWEAK:-}" ]; then
        for path in /sys/devices/platform/*.dvfsrc; do
            [ -e "$path" ] && apply -1 "$path/helio-dvfsrc/dvfsrc_req_ddr_opp"
        done
        write -1 /sys/kernel/helio-dvfsrc/dvfsrc_force_vcore_dvfs_opp
        devfreq_unlock /sys/class/devfreq/mtk-dvfsrc-devfreq
    fi

    apply 1 /sys/kernel/eara_thermal/enable
}

snapdragon_normal() {
    if [ -z "${USF_NO_DDR_TWEAK:-}" ]; then
        for path in /sys/class/devfreq/*memlat* /sys/class/devfreq/*latfloor* /sys/class/devfreq/*ddr-lat*; do
            [ -e "$path" ] && devfreq_unlock "$path"
        done
        for component in DDR LLCC L3; do
            devfreq_unlock "/sys/devices/system/cpu/bus_dcvs/$component"
        done
    fi
    devfreq_unlock /sys/class/kgsl/kgsl-3d0/devfreq
    apply 1 /sys/class/kgsl/kgsl-3d0/bus_split
    apply 0 /sys/class/kgsl/kgsl-3d0/force_clk_on
}

exynos_normal() {
    gpu_path=/sys/kernel/gpu
    have "$gpu_path" || return 0
    freq_node=""
    [ -f "$gpu_path/gpu_available_frequencies" ] && freq_node="$gpu_path/gpu_available_frequencies"
    [ -z "$freq_node" ] && [ -f "$gpu_path/gpu_freq_table" ] && freq_node="$gpu_path/gpu_freq_table"
    [ -n "$freq_node" ] || return 0
    write "$(which_maxfreq "$freq_node")" "$gpu_path/gpu_max_clock"
    write "$(which_minfreq "$freq_node")" "$gpu_path/gpu_min_clock"

    mali_sysfs=$(find /sys/devices/platform/ -iname '*.mali' -print -quit 2>/dev/null)
    if grep -q adaptive "$mali_sysfs/power_policy" 2>/dev/null; then
        apply adaptive "$mali_sysfs/power_policy"
    else
        apply coarse_demand "$mali_sysfs/power_policy"
    fi

    if [ -z "${USF_NO_DDR_TWEAK:-}" ]; then
        for path in /sys/class/devfreq/*devfreq_mif*; do
            have "$path" && devfreq_unlock "$path"
        done
    fi
}

unisoc_normal() {
    gpu_path=$(find /sys/class/devfreq/ -type d -iname '*.gpu' -print -quit 2>/dev/null)
    [ -n "$gpu_path" ] && devfreq_unlock "$gpu_path"
}

tensor_normal() {
    gpu_path=$(find /sys/devices/platform/ -type d -iname '*.mali' -print -quit 2>/dev/null)
    [ -n "$gpu_path" ] || return 0
    write "$(which_maxfreq "$gpu_path/available_frequencies")" "$gpu_path/scaling_max_freq"
    write "$(which_minfreq "$gpu_path/available_frequencies")" "$gpu_path/scaling_min_freq"
    if grep -q adaptive "$gpu_path/power_policy" 2>/dev/null; then
        apply adaptive "$gpu_path/power_policy"
    else
        apply coarse_demand "$gpu_path/power_policy"
    fi
}

###################################
# Device-specific powersave profiles
###################################

mediatek_powersave() {
    apply 1 /proc/cpufreq/cpufreq_power_mode
    if have /proc/gpufreqv2; then
        idx=$(mtk_gpufreq_minfreq_index /proc/gpufreqv2/gpu_working_opp_table)
        [ -n "$idx" ] && apply "$idx" /proc/gpufreqv2/fix_target_opp_index
    else
        gpu_freq=$(sed -n 's/.*freq = \([0-9]\{1,\}\).*/\1/p' /proc/gpufreq/gpufreq_opp_dump 2>/dev/null | tail -n 1)
        [ -n "$gpu_freq" ] && apply "$gpu_freq" /proc/gpufreq/gpufreq_opp_freq
    fi
    mali_sysfs=$(find /sys/devices/platform/ -iname '*.mali' -print -quit 2>/dev/null)
    [ -n "$mali_sysfs" ] && apply coarse_demand "$mali_sysfs/power_policy"
}

snapdragon_powersave() {
    [ -z "${USF_QCOM_NO_GPU_POWERSAVE:-}" ] && devfreq_min_perf /sys/class/kgsl/kgsl-3d0/devfreq
}

exynos_powersave() {
    gpu_path=/sys/kernel/gpu
    have "$gpu_path" || return 0
    freq_node=""
    [ -f "$gpu_path/gpu_available_frequencies" ] && freq_node="$gpu_path/gpu_available_frequencies"
    [ -z "$freq_node" ] && [ -f "$gpu_path/gpu_freq_table" ] && freq_node="$gpu_path/gpu_freq_table"
    [ -n "$freq_node" ] || return 0
    freq=$(which_minfreq "$freq_node")
    apply "$freq" "$gpu_path/gpu_min_clock"
    apply "$freq" "$gpu_path/gpu_max_clock"
}

unisoc_powersave() {
    gpu_path=$(find /sys/class/devfreq/ -type d -iname '*.gpu' -print -quit 2>/dev/null)
    [ -n "$gpu_path" ] && devfreq_min_perf "$gpu_path"
}

tensor_powersave() {
    gpu_path=$(find /sys/devices/platform/ -type d -iname '*.mali' -print -quit 2>/dev/null)
    [ -n "$gpu_path" ] || return 0
    freq=$(which_minfreq "$gpu_path/available_frequencies")
    apply "$freq" "$gpu_path/scaling_min_freq"
    apply "$freq" "$gpu_path/scaling_max_freq"
    apply coarse_demand "$gpu_path/power_policy"
}

###################################
# perfcommon — applies in every performance run
###################################

perfcommon() {
    # I/O: no statistics accounting, no random spice
    for dir in /sys/block/*; do
        apply 0 "$dir/queue/iostats"
        apply 0 "$dir/queue/add_random"
    done

    # Networking: best available congestion control for gaming
    for algo in bbr3 bbr2 bbrplus bbr westwood cubic; do
        if grep -q "$algo" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            apply "$algo" /proc/sys/net/ipv4/tcp_congestion_control
            break
        fi
    done

    apply 1 /proc/sys/net/ipv4/tcp_low_latency
    apply 1 /proc/sys/net/ipv4/tcp_ecn
    apply 3 /proc/sys/net/ipv4/tcp_fastopen
    apply 1 /proc/sys/net/ipv4/tcp_sack
    apply 0 /proc/sys/net/ipv4/tcp_timestamps

    # Scheduler latency tweaks
    apply 3 /proc/sys/kernel/perf_cpu_time_max_percent
    apply 0 /proc/sys/kernel/sched_schedstats
    apply 0 /proc/sys/kernel/sched_autogroup_enabled
    apply 1 /proc/sys/kernel/sched_child_runs_first
    apply 32 /proc/sys/kernel/sched_nr_migrate
    apply 50000 /proc/sys/kernel/sched_migration_cost_ns
    apply 1000000 /proc/sys/kernel/sched_min_granularity_ns
    apply 1500000 /proc/sys/kernel/sched_wakeup_granularity_ns

    # VM
    apply 0 /proc/sys/vm/page-cluster
    apply 15 /proc/sys/vm/stat_interval
    apply 0 /proc/sys/vm/compaction_proactiveness

    apply 0 /sys/module/mmc_core/parameters/use_spi_crc

    # Report max CPU capability to game engines
    apply 'libunity.so, libil2cpp.so, libmain.so, libUE4.so, libgodot_android.so, libgdx.so, libgdx-box2d.so, libminecraftpe.so, libLive2DCubismCore.so' /proc/sys/kernel/sched_lib_name
    apply 255 /proc/sys/kernel/sched_lib_mask_force

    # Thermal governor step_wise on every zone (least intrusive)
    for dir in /sys/class/thermal/thermal_zone*; do
        apply step_wise "$dir/policy"
    done
}

###################################
# Main profiles
###################################

performance_profile() {
    LITE_MODE=0
    [ "$1" = lite ] && LITE_MODE=1

    # Common gaming tweaks first (Encore's daemon did this before the profile)
    perfcommon

    # Battery saver off while gaming
    have /sys/module/battery_saver/parameters/enabled && {
        if grep -qo '[0-9]\+' /sys/module/battery_saver/parameters/enabled 2>/dev/null; then
            apply 0 /sys/module/battery_saver/parameters/enabled
        else
            apply N /sys/module/battery_saver/parameters/enabled
        fi
    }

    apply 0 /proc/sys/kernel/split_lock_mitigate

    have /sys/kernel/debug/sched_features && {
        apply NEXT_BUDDY /sys/kernel/debug/sched_features
        apply NO_TTWU_QUEUE /sys/kernel/debug/sched_features
    }

    have /dev/stune && {
        apply 1 /dev/stune/top-app/schedtune.prefer_idle
        apply 1 /dev/stune/top-app/schedtune.boost
    }

    # Oppo/Oplus/Realme touchpanel gaming switches
    have /proc/touchpanel && {
        apply 1 /proc/touchpanel/game_switch_enable
        apply 0 /proc/touchpanel/oplus_tp_limit_enable
        apply 0 /proc/touchpanel/oppo_tp_limit_enable
    }

    apply 80 /proc/sys/vm/vfs_cache_pressure

    # Governor: performance (unless lite)
    if [ "$LITE_MODE" -eq 0 ] && [ -z "${USF_NO_PERFORMANCE_CPUGOV:-}" ]; then
        change_cpu_gov performance
    else
        change_cpu_gov "$DEFAULT_CPU_GOV"
    fi

    # Pin CPU frequency: highest possible
    if have /proc/ppm; then
        cpufreq_ppm_max_perf
    else
        cpufreq_max_perf
    fi

    # I/O latency tweaks
    for dir in /sys/block/mmcblk0 /sys/block/mmcblk1 /sys/block/sd*; do
        [ -e "$dir" ] || continue
        apply 32 "$dir/queue/read_ahead_kb"
        apply 32 "$dir/queue/nr_requests"
    done

    case $SOC in
        1) mediatek_performance ;;
        2) snapdragon_performance ;;
        3) exynos_performance ;;
        4) unisoc_performance ;;
        5) tensor_performance ;;
    esac

    [ "$DRYRUN" = "1" ] || echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    log "profile applied: performance (LITE_MODE=$LITE_MODE)"
}

balance_profile() {
    apply 1 /proc/sys/kernel/split_lock_mitigate

    have /sys/kernel/debug/sched_features && {
        apply NEXT_BUDDY /sys/kernel/debug/sched_features
        apply TTWU_QUEUE /sys/kernel/debug/sched_features
    }

    have /dev/stune && {
        apply 0 /dev/stune/top-app/schedtune.prefer_idle
        apply 0 /dev/stune/top-app/schedtune.boost
    }

    have /proc/touchpanel && {
        apply 0 /proc/touchpanel/game_switch_enable
        apply 1 /proc/touchpanel/oplus_tp_limit_enable
        apply 1 /proc/touchpanel/oppo_tp_limit_enable
    }

    apply 120 /proc/sys/vm/vfs_cache_pressure

    # Restore stock governor + freq range (USF cap is already removed by
    # usfcpu.sh, so scaling_max stays at hardware max without our help)
    change_cpu_gov "$DEFAULT_CPU_GOV"

    if have /proc/ppm; then
        cpufreq_ppm_unlock
    else
        cpufreq_unlock
    fi

    for dir in /sys/block/mmcblk0 /sys/block/mmcblk1 /sys/block/sd*; do
        [ -e "$dir" ] || continue
        apply 128 "$dir/queue/read_ahead_kb"
        apply 64 "$dir/queue/nr_requests"
    done

    case $SOC in
        1) mediatek_normal ;;
        2) snapdragon_normal ;;
        3) exynos_normal ;;
        4) unisoc_normal ;;
        5) tensor_normal ;;
    esac
    log "profile applied: balance"
}

powersave_profile() {
    balance_profile

    [ -d /dev/stune/ ] && apply 1 /dev/stune/top-app/schedtune.prefer_idle

    have /sys/module/battery_saver/parameters/enabled && {
        if grep -qo '[0-9]\+' /sys/module/battery_saver/parameters/enabled 2>/dev/null; then
            apply 1 /sys/module/battery_saver/parameters/enabled
        else
            apply Y /sys/module/battery_saver/parameters/enabled
        fi
    }

    change_cpu_gov "$POWERSAVE_GOV"

    case $SOC in
        1) mediatek_powersave ;;
        2) snapdragon_powersave ;;
        3) exynos_powersave ;;
        4) unisoc_powersave ;;
        5) tensor_powersave ;;
    esac
    log "profile applied: powersave"
}

###################################
# Dispatch
###################################

case "${1:-}" in
    perfcommon)        perfcommon ;;
    performance)       performance_profile ;;
    performance_lite)  performance_profile lite ;;
    balance)           balance_profile ;;
    powersave)         powersave_profile ;;
    *)
        log "usage: $0 {perfcommon|performance|performance_lite|balance|powersave}"
        exit 2
        ;;
esac

exit 0
