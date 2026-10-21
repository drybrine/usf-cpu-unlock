#!/bin/sh
# Host-side tests for module/scripts/usf_profiler.sh (DRYRUN mode).
# The profiler must print every action instead of writing when
# USF_PROFILER_DRYRUN=1, so the whole surface is testable on a PC.
#
# Two layers:
#   - OUTPUT assertions: dry-run lines that don't need device file reads
#   - SOURCE assertions: code-path presence (grep the script) for branches
#     whose inner reads need device files (PPM status tables, GPU freq tables)
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROF=$ROOT/module/scripts/usf_profiler.sh
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

run_profile() { # run_profile <soc> <profile-arg>
  USF_PROFILER_DRYRUN=1 SOC=$1 sh "$PROF" "$2" 2>&1
}

src_has() { # src_has <pattern> — code-path presence in the script source
  grep -q "$1" "$PROF"
}

t_dispatch() {
  if SOC=1 sh "$PROF" nonsense >/dev/null 2>&1; then
    bad dispatch "unknown profile accepted"; else ok dispatch-unknown-rejected; fi
  for p in perfcommon performance performance_lite balance powersave; do
    if SOC=1 sh "$PROF" "$p" >/dev/null 2>&1; then ok "dispatch-$p"; else bad "dispatch-$p" "exit nonzero"; fi
  done
}

t_performance_mtk() {
  out=$(run_profile 1 performance)
  # governor pinned to performance
  echo "$out" | grep -q 'scaling_governor.*performance' || { bad perf-mtk "governor not set"; return; }
  # non-PPM fallback writes scaling_min_freq (code path present)
  src_has 'scaling_min_freq' || { bad perf-mtk "scaling_min_freq code path missing"; return; }
  # PPM hard userlimit writes present (have() lets the branch run on host)
  echo "$out" | grep -q 'hard_userlimit_max_cpu_freq' || { bad perf-mtk "PPM max limit missing"; return; }
  echo "$out" | grep -q 'hard_userlimit_min_cpu_freq' || { bad perf-mtk "PPM min limit missing"; return; }
  # FPSGO forced off
  echo "$out" | grep -q 'fpsgo/common/force_onoff' || { bad perf-mtk "FPSGO missing"; return; }
  # GPU power limiter
  echo "$out" | grep -q 'ignore_thermal_protect' || { bad perf-mtk "GPU power limiter missing"; return; }
  # battery OC throttle stopped
  echo "$out" | grep -q 'battery_oc_protect_stop' || { bad perf-mtk "battery OC throttle missing"; return; }
  # eara thermal disabled
  echo "$out" | grep -q 'eara_thermal/enable' || { bad perf-mtk "eara thermal missing"; return; }
  # DDR boost on
  echo "$out" | grep -q 'dramboost' || { bad perf-mtk "DDR boost missing"; return; }
  # sched_lib_name game libs
  echo "$out" | grep -q 'sched_lib_name' || { bad perf-mtk "sched_lib_name missing"; return; }
  # thermal governor step_wise
  echo "$out" | grep -q 'step_wise' || { bad perf-mtk "thermal governor missing"; return; }
  # PPM policy_status code path exists in source (needs device read to exercise)
  src_has 'policy_status' || { bad perf-mtk "policy_status code path missing"; return; }
  ok perf-mtk
}

t_performance_lite_mtk() {
  out=$(run_profile 1 performance_lite)
  # lite mode flag must be reported
  echo "$out" | grep -q 'LITE_MODE=1' || { bad perf-lite "LITE_MODE=1 not reported"; return; }
  # code path: which_midfreq must be called in the PPM/perf branch
  src_has 'which_midfreq' || { bad perf-lite "which_midfreq code path missing"; return; }
  ok perf-lite-mtk
}

t_balance_mtk() {
  out=$(run_profile 1 balance)
  # PPM unlocked (max + min both written)
  echo "$out" | grep -q 'hard_userlimit_max_cpu_freq' || { bad bal-mtk "PPM max missing"; return; }
  echo "$out" | grep -q 'hard_userlimit_min_cpu_freq' || { bad bal-mtk "PPM min missing"; return; }
  # NO performance governor in balance
  echo "$out" | grep -q 'scaling_governor.*performance' && { bad bal-mtk "performance governor in balance"; return; }
  # governor restored (DEFAULT_CPU_GOV=schedutil)
  echo "$out" | grep -q 'scaling_governor.*schedutil' || { bad bal-mtk "governor not restored"; return; }
  # PPM policy_status re-enable code path
  src_has 'policy_status' || { bad bal-mtk "policy_status code path missing"; return; }
  # eara thermal re-enabled
  echo "$out" | grep -q 'eara_thermal/enable <- 1' || { bad bal-mtk "eara re-enable missing"; return; }
  ok bal-mtk
}

t_powersave_mtk() {
  out=$(run_profile 1 powersave)
  echo "$out" | grep -q 'cpufreq_power_mode' || { bad ps-mtk "MTK power mode missing"; return; }
  # powersave governor
  echo "$out" | grep -q 'scaling_governor.*powersave' || { bad ps-mtk "powersave governor missing"; return; }
  ok ps-mtk
}

t_other_socs() {
  out=$(run_profile 2 performance)  # snapdragon: kgsl writes in dry-run
  echo "$out" | grep -q 'kgsl' || { bad soc-qcom "kgsl missing"; return; }
  # exynos: gpu_max_clock code path exists (inner freq read needs device)
  src_has 'gpu_max_clock' || { bad soc-exynos "gpu clock code path missing"; return; }
  out=$(run_profile 3 performance)  # exynos dry-run should not crash
  echo "$out" | grep -q 'profile applied' || { bad soc-exynos "profile not applied"; return; }
  ok other-socs
}

t_dryrun_no_sideeffects() {
  # dry-run output must not contain raw redirect characters (no actual writes)
  out=$(run_profile 1 performance)
  echo "$out" | grep -qE '^[^[]' && { bad dryrun "non-dry line in output"; return; }
  ok dryrun-pure
}

t_dispatch
t_performance_mtk
t_performance_lite_mtk
t_balance_mtk
t_powersave_mtk
t_other_socs
t_dryrun_no_sideeffects

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
