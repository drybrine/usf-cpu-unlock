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

# Write one value into one node.
#
# This runs hundreds of times per profile switch, synchronously behind a
# button tap, so it must not fork. `chmod` is a process spawn (3-5ms on a
# phone) and it was the single biggest cost here - 43 of the 60 forks a
# `performance` apply made. As root the node is already writable on virtually
# every sysfs/proc node, so only chmod when the write would otherwise fail.
_put() { # _put <value> <node>
    [ -n "$2" ] || return 1
    if [ "$DRYRUN" = "1" ]; then
        printf '[dry] %s <- %s\n' "$2" "$1"
        return 0
    fi
    [ -e "$2" ] || return 1
    if [ -w "$2" ]; then
        printf '%s\n' "$1" > "$2" 2>/dev/null
        return 0
    fi
    chmod 644 "$2" >/dev/null 2>&1
    printf '%s\n' "$1" > "$2" 2>/dev/null
}

apply() { _put "$1" "$2"; }
write() { _put "$1" "$2"; }

# Read one line into RF without forking: $(cat file) spawns a subshell AND cat.
RF=""
rd() {
    RF=""
    [ -r "$1" ] || return 1
    read -r RF < "$1" 2>/dev/null
    return 0
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

# Frequency tables. Each helper sets RF instead of printing: a function
# called in $(...) forks a subshell, and `tr | sort | head` forked three more,
# so the old form cost ~4 forks per lookup - on the button-tap path.
_freq_scan() { # _freq_scan <file> — fills _F_VALS (space separated) and _F_COUNT
    _F_VALS=""
    _F_COUNT=0
    [ -r "$1" ] || return 1
    while IFS= read -r _fl || [ -n "$_fl" ]; do
        for _fv in $_fl; do
            case "$_fv" in ''|*[!0-9]*) continue ;; esac
            _F_VALS="$_F_VALS $_fv"
            _F_COUNT=$((_F_COUNT + 1))
        done
    done < "$1"
    [ "$_F_COUNT" -gt 0 ]
}

freq_max() { # freq_max <file> -> RF
    RF=""
    if _freq_scan "$1"; then
        for _fv in $_F_VALS; do
            if [ -z "$RF" ] || [ "$_fv" -gt "$RF" ]; then RF=$_fv; fi
        done
        return 0
    fi
    [ "$DRYRUN" = "1" ] && { RF=999999; return 0; }
    return 1
}

freq_min() { # freq_min <file> -> RF
    RF=""
    if _freq_scan "$1"; then
        for _fv in $_F_VALS; do
            if [ -z "$RF" ] || [ "$_fv" -lt "$RF" ]; then RF=$_fv; fi
        done
        return 0
    fi
    [ "$DRYRUN" = "1" ] && { RF=999999; return 0; }
    return 1
}

freq_mid() { # freq_mid <file> -> RF (nth-highest, n = ceil(count/2))
    RF=""
    if ! _freq_scan "$1"; then
        [ "$DRYRUN" = "1" ] && { RF=999999; return 0; }
        return 1
    fi
    _k=$(((_F_COUNT + 1) / 2))
    _need=$((_k - 1))          # values that must be greater than the pick
    for _fv in $_F_VALS; do
        _greater=0
        for _fw in $_F_VALS; do
            [ "$_fw" -gt "$_fv" ] && _greater=$((_greater + 1))
        done
        [ "$_greater" -eq "$_need" ] && { RF=$_fv; return 0; }
    done
    freq_min "$1"
}

# Compat wrappers for the call sites that still consume stdout.
which_maxfreq() { freq_max "$1" && printf '%s\n' "$RF"; }
which_minfreq() { freq_min "$1" && printf '%s\n' "$RF"; }
which_midfreq() { freq_mid "$1" && printf '%s\n' "$RF"; }

mtk_gpufreq_minfreq_index() { awk -F'[][]' '{print $2}' "$1" 2>/dev/null | tail -n 1; }

# Locate a platform directory ONCE. `find` is a fork AND a tree walk, and the
# same path was looked up several times per profile switch. Glob expansion is
# built into the shell. Result goes to RF.
MALI_CACHE=""
mali_path() {
    RF=""
    [ -n "$MALI_CACHE" ] && { RF=$MALI_CACHE; return 0; }
    for _d in /sys/devices/platform/*.mali /sys/devices/platform/*/*.mali \
              /sys/devices/platform/*.gpu /sys/devices/platform/*/*.gpu; do
        [ -e "$_d" ] || continue
        MALI_CACHE=$_d
        RF=$_d
        return 0
    done
    return 1
}

GPU_DEVFREQ_CACHE=""
gpu_devfreq_path() {
    RF=""
    [ -n "$GPU_DEVFREQ_CACHE" ] && { RF=$GPU_DEVFREQ_CACHE; return 0; }
    for _d in /sys/class/devfreq/*.gpu /sys/class/devfreq/*gpu*; do
        [ -d "$_d" ] || continue
        GPU_DEVFREQ_CACHE=$_d
        RF=$_d
        return 0
    done
    return 1
}

# Second character of $1 -> SC (the PPM policy index in "[0] PWR_THRO ...").
_second_char() {
    _r=${1#?}
    SC=${_r%"${_r#?}"}
}

# PPM policy rows, matched in shell instead of `grep | while read` (2 forks).
# The whole file is snapshotted BEFORE writing: /proc/ppm/policy_status is the
# same node being written, and streaming it while writing could end the loop
# early (shellcheck SC2094).
ppm_policy_off() { # ppm_policy_off <0|1>
    [ -r /proc/ppm/policy_status ] || return 0
    _rows=""
    while IFS= read -r _row || [ -n "$_row" ]; do
        _rows="$_rows$_row
"
    done < /proc/ppm/policy_status
    [ -n "$_rows" ] || return 0

    _saved_ifs=$IFS
    IFS='
'
    for _row in $_rows; do
        case "$_row" in
            *PWR_THRO*|*THERMAL*)
                _second_char "$_row"
                apply "$SC $1" /proc/ppm/policy_status
                ;;
        esac
    done
    IFS=$_saved_ifs
}

###################################
# CPU frequency profiles
###################################

cpufreq_ppm_max_perf() {
    cluster=-1
    for path in /sys/devices/system/cpu/cpufreq/policy*; do
        cluster=$((cluster + 1))
        rd "$path/cpuinfo_max_freq" || continue
        cpu_maxfreq=$RF
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
        rd "$path/cpuinfo_max_freq" || continue
        cpu_maxfreq=$RF
        apply "$cpu_maxfreq" "$path/scaling_max_freq"
        if [ "$LITE_MODE" -eq 1 ]; then
            cpu_midfreq=$(which_midfreq "$path/scaling_available_frequencies" 2>/dev/null)
            [ -n "$cpu_midfreq" ] || { rd "$path/cpuinfo_min_freq" && cpu_midfreq=$RF; }
            [ -n "$cpu_midfreq" ] && apply "$cpu_midfreq" "$path/scaling_min_freq"
        else
            apply "$cpu_maxfreq" "$path/scaling_min_freq"
        fi
    done
}

cpufreq_ppm_unlock() {
    cluster=0
    for path in /sys/devices/system/cpu/cpufreq/policy*; do
        rd "$path/cpuinfo_max_freq" || continue
        cpu_maxfreq=$RF
        rd "$path/cpuinfo_min_freq" || continue
        cpu_minfreq=$RF
        write "$cluster $cpu_maxfreq" /proc/ppm/policy/hard_userlimit_max_cpu_freq
        write "$cluster $cpu_minfreq" /proc/ppm/policy/hard_userlimit_min_cpu_freq
        cluster=$((cluster + 1))
    done
}

cpufreq_unlock() {
    for path in /sys/devices/system/cpu/cpu*/cpufreq; do
        [ -f "$path/cpuinfo_max_freq" ] || continue
        rd "$path/cpuinfo_max_freq" || continue
        _mx=$RF
        rd "$path/cpuinfo_min_freq" || continue
        write "$_mx" "$path/scaling_max_freq"
        write "$RF" "$path/scaling_min_freq"
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
        ppm_policy_off 0
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
    mali_path && apply always_on "$RF/power_policy"

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

    mali_path && apply always_on "$RF/power_policy"

    if [ -z "${USF_NO_DDR_TWEAK:-}" ]; then
        for path in /sys/class/devfreq/*devfreq_mif*; do
            [ -e "$path" ] || continue
            if [ "$LITE_MODE" -eq 1 ]; then devfreq_mid_perf "$path"; else devfreq_max_perf "$path"; fi
        done
    fi
}

unisoc_performance() {
    gpu_devfreq_path || return 0
    if [ "$LITE_MODE" -eq 0 ]; then devfreq_max_perf "$RF"; else devfreq_unlock "$RF"; fi
}

tensor_performance() {
    mali_path || return 0
    _gp=$RF
    max_freq=$(which_maxfreq "$_gp/available_frequencies")
    apply "$max_freq" "$_gp/scaling_max_freq"
    if [ "$LITE_MODE" -eq 0 ]; then
        apply "$max_freq" "$gpu_path/scaling_min_freq"
    else
        apply "$(which_minfreq "$_gp/available_frequencies")" "$_gp/scaling_min_freq"
    fi
    apply always_on "$_gp/power_policy"
}

###################################
# Device-specific balance profiles
###################################

mediatek_normal() {
    if have /proc/ppm; then
        ppm_policy_off 1
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

    if mali_path; then
        _pol=coarse_demand
        rd "$RF/power_policy" && case "$RF" in *adaptive*) _pol=adaptive ;; esac
        apply "$_pol" "$MALI_CACHE/power_policy"
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

    if mali_path; then
        _pol=coarse_demand
        rd "$RF/power_policy" && case "$RF" in *adaptive*) _pol=adaptive ;; esac
        apply "$_pol" "$MALI_CACHE/power_policy"
    fi

    if [ -z "${USF_NO_DDR_TWEAK:-}" ]; then
        for path in /sys/class/devfreq/*devfreq_mif*; do
            have "$path" && devfreq_unlock "$path"
        done
    fi
}

unisoc_normal() {
    gpu_devfreq_path && devfreq_unlock "$RF"
}

tensor_normal() {
    mali_path || return 0
    _gp=$RF
    freq_max "$_gp/available_frequencies" && write "$RF" "$_gp/scaling_max_freq"
    freq_min "$_gp/available_frequencies" && write "$RF" "$_gp/scaling_min_freq"
    _pol=coarse_demand
    rd "$_gp/power_policy" && case "$RF" in *adaptive*) _pol=adaptive ;; esac
    apply "$_pol" "$_gp/power_policy"
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
    mali_path && apply coarse_demand "$RF/power_policy"
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
    gpu_devfreq_path && devfreq_min_perf "$RF"
}

tensor_powersave() {
    mali_path || return 0
    _gp=$RF
    freq_min "$_gp/available_frequencies" || return 0
    _mn=$RF
    apply "$_mn" "$_gp/scaling_min_freq"
    apply "$_mn" "$_gp/scaling_max_freq"
    apply coarse_demand "$_gp/power_policy"
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
    if rd /proc/sys/net/ipv4/tcp_available_congestion_control; then
        _avail=" $RF "
        for algo in bbr3 bbr2 bbrplus bbr westwood cubic; do
            case "$_avail" in
                *" $algo "*) apply "$algo" /proc/sys/net/ipv4/tcp_congestion_control; break ;;
            esac
        done
    fi

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
        if rd /sys/module/battery_saver/parameters/enabled && case "$RF" in *[0-9]*) true ;; *) false ;; esac; then
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
        if rd /sys/module/battery_saver/parameters/enabled && case "$RF" in *[0-9]*) true ;; *) false ;; esac; then
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

main() {
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
}

# Only dispatch when executed, not when sourced: the host suite sources this
# file to unit-test individual helpers (apply, freq_*).
case "$0" in
    *usf_profiler.sh) main "$@" ;;
esac
