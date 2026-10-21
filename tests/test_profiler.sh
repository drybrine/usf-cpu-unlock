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

# --- performance: fork budget ---------------------------------------------
# Every external command the profiler spawns costs a fork; on a phone that is
# 3-5ms each, and a profile switch runs the profiler synchronously behind a
# button tap. Measured before the optimisation: `performance` spawned 60
# processes (43 of them `chmod`). The budget below is the regression gate.
mk_fork_stubs() { # mk_fork_stubs <dir> — logging wrappers for every command
  _d=$1; rm -rf "$_d"; mkdir -p "$_d"
  for _c in chmod cat tr sort head tail find awk sed grep wc basename dirname date sleep; do
    _real=$(command -v "$_c" 2>/dev/null) || continue
    {
      printf '#!/bin/sh\n'
      printf 'printf "%%s\\n" "%s" >> "$FORKLOG"\n' "$_c"
      printf 'exec "%s" "$@"\n' "$_real"
    } > "$_d/$_c"
    chmod +x "$_d/$_c"
  done
}

count_forks() { # count_forks <profile> — prints "<total> <non-chmod>"
  export FORKLOG="$TMP/forks.log"; : > "$FORKLOG"
  PATH="$TMP/stub:$PATH" SOC=1 sh "$PROF" "$1" >/dev/null 2>&1 || true
  total=$(wc -l < "$FORKLOG" | tr -d ' ')
  chmods=$(grep -cx chmod "$FORKLOG" || true)
  printf '%s %s\n' "$total" "${chmods:-0}"
}

t_fork_budget() {
  # Writing to /proc or /sys as root would actually change the host, so this
  # gate only runs unprivileged (where every write fails harmlessly).
  if [ "$(id -u)" = "0" ]; then
    printf 'skip fork-budget (running as root)\n'; return 0
  fi
  mk_fork_stubs "$TMP/stub"
  # chmod forks are counted separately: on the host no /proc node is writable,
  # so every write takes the chmod path; on the device (root) apply() skips
  # chmod entirely, which t_apply_no_gratuitous_chmod proves. What this gate
  # protects is the avoidable forks: cat/tr/sort/head/find/grep per write.
  for prof in performance balance; do
    set -- $(count_forks "$prof")
    total=$1; chmods=$2
    other=$((total - chmods))
    [ "$other" -le 10 ] || { bad "fork-$prof" "$other non-chmod forks (budget 10; total $total)"; return; }
    ok "fork-$prof ($other non-chmod, $total total)"
  done
}

t_sourceable() {
  # The profiler must be usable as a library so functions can be unit-tested:
  # the dispatch may only run when the file is executed, not when sourced.
  out=$(sh -c '. "$1"; type apply >/dev/null 2>&1 && echo sourced-ok' _ "$PROF" 2>&1)
  echo "$out" | grep -q 'sourced-ok' || { bad sourceable "sourcing runs the dispatch: $out"; return; }
  echo "$out" | grep -q 'usage:' && { bad sourceable "sourcing printed usage"; return; }
  ok sourceable
}

t_apply_no_gratuitous_chmod() {
  # chmod is a fork. A node that is already writable must not be chmod-ed.
  mk_fork_stubs "$TMP/stub2"
  node="$TMP/writable_node"
  printf '0\n' > "$node"
  chmod 644 "$node"
  export FORKLOG="$TMP/chmod.log"; : > "$FORKLOG"
  PATH="$TMP/stub2:$PATH" sh -c '. "$1"; apply 5 "$2"' _ "$PROF" "$node" >/dev/null 2>&1
  grep -q chmod "$FORKLOG" && { bad apply-chmod "chmod forked on a writable node"; return; }
  [ "$(cat "$node")" = "5" ] || { bad apply-chmod "value not written"; return; }

  # a read-only node still needs the chmod attempt
  node2="$TMP/ro_node"; printf '0\n' > "$node2"; chmod 444 "$node2"
  : > "$FORKLOG"
  PATH="$TMP/stub2:$PATH" sh -c '. "$1"; apply 7 "$2"' _ "$PROF" "$node2" >/dev/null 2>&1
  grep -q chmod "$FORKLOG" || { bad apply-chmod "no chmod attempted on a read-only node"; return; }
  ok apply-chmod
}

t_ppm_index_extraction() {
  # "[1] THERMAL 1" -> index "1". The PPM node is keyed by that index, so a
  # wrong slice silently disables the wrong policy.
  for pair in "0|[0] PWR_THRO 1" "1|[1] THERMAL 1" "5|[5] PPM_USER_LIMIT 1"; do
    want=${pair%%|*}; row=${pair#*|}
    got=$(sh -c '. "$1"; _second_char "$2"; printf "%s" "$SC"' _ "$PROF" "$row" 2>&1)
    [ "$got" = "$want" ] || { bad ppm-index "row [$row] -> '$got' (want $want)"; return; }
  done
  ok ppm-index
}

t_no_bogus_root_paths() {
  # With no GPU node present the old code built "$mali_sysfs/power_policy"
  # from an empty variable and wrote to "/power_policy". Every write target
  # must be a plausible node path, never a bare root-level file.
  for prof in performance balance powersave; do
    out=$(run_profile 1 "$prof")
    if echo "$out" | grep -qE '^\[dry\] /[A-Za-z0-9_]+ <- '; then
      bad "bogus-$prof" "writes to a root-level path: $(echo "$out" | grep -E '^\[dry\] /[A-Za-z0-9_]+ <- ' | head -n 1)"
      return
    fi
  done
  ok no-bogus-root-paths
}

t_dispatch
t_fork_budget
t_sourceable
t_apply_no_gratuitous_chmod
t_ppm_index_extraction
t_no_bogus_root_paths
t_performance_mtk
t_performance_lite_mtk
t_balance_mtk
t_powersave_mtk
t_other_socs
t_dryrun_no_sideeffects

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
