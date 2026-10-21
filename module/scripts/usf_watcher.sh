#!/system/bin/sh
#
# usf_watcher.sh — foreground-game watcher for usf-cpu-unlock.
#
# Stand-in for Encore Tweaks' `encored` daemon: it polls the foreground app
# and switches the performance profile automatically (game -> performance,
# anything else -> balance, screen off -> powersave), so the tweaks engage
# the moment a game is opened instead of needing a manual profile switch.
#
# Unlike Encore's daemon this is plain sh, because this module must also work
# under GhostLock temporary root where only late-load scripts run.
#
# Config (default /data/adb/.config/usf-cpu-unlock):
#   gamelist.txt      one package per line, '#' comments allowed
#   watcher.state     last applied profile (managed here)
#   watcher.disabled  present => watcher exits without doing anything
#   watcher.interval  poll interval in seconds (default 5)
#
# Test hooks (host suite):
#   USF_CONFIG_DIR, USF_FG_PACKAGE, USF_SCREEN_STATE,
#   USF_WATCHER_DRYRUN, USF_WATCHER_ONCE, USF_NO_SPAWN

MODULE_DIR=${MODULE_DIR:-/data/adb/modules/usf-cpu-unlock}
CONFIG_DIR=${USF_CONFIG_DIR:-/data/adb/.config/usf-cpu-unlock}
GAMELIST="$CONFIG_DIR/gamelist.txt"
STATEFILE="$CONFIG_DIR/watcher.state"
DISABLED="$CONFIG_DIR/watcher.disabled"
INTERVAL_FILE="$CONFIG_DIR/watcher.interval"
DRYRUN=${USF_WATCHER_DRYRUN:-0}
PROFILER="$MODULE_DIR/scripts/usf_profiler.sh"

log() { printf '[watcher] %s\n' "$*"; }

interval() {
    n=$(cat "$INTERVAL_FILE" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=5 ;; esac
    [ "$n" -ge 1 ] 2>/dev/null || n=5
    printf '%s\n' "$n"
}

# --- detection -------------------------------------------------------------

screen_state() {
    if [ -n "${USF_SCREEN_STATE:-}" ]; then
        printf '%s\n' "$USF_SCREEN_STATE"; return
    fi
    w=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=')
    case "$w" in
        *Asleep*|*Dozing*) printf 'off\n'; return ;;
        *Awake*)           printf 'on\n';  return ;;
    esac
    # fallback: panel backlight
    for bl in /sys/class/backlight/*/brightness; do
        [ -r "$bl" ] || continue
        b=$(cat "$bl" 2>/dev/null)
        case "$b" in ''|*[!0-9]*) continue ;; esac
        if [ "$b" -gt 0 ] 2>/dev/null; then printf 'on\n'; else printf 'off\n'; fi
        return
    done
    printf 'on\n'
}

foreground_package() {
    if [ -n "${USF_FG_PACKAGE+x}" ]; then
        printf '%s\n' "$USF_FG_PACKAGE"; return
    fi
    # Cheapest reliable signal: the foreground app is the process with
    # oom_score_adj 0 inside the top-app cpuset (no dumpsys needed).
    for p in $(cat /dev/cpuset/top-app/cgroup.procs 2>/dev/null); do
        adj=$(cat "/proc/$p/oom_score_adj" 2>/dev/null)
        [ "$adj" = "0" ] || continue
        cmd=$(tr -d '\0' < "/proc/$p/cmdline" 2>/dev/null)
        case "$cmd" in ''|*:*|*/*) continue ;; esac
        printf '%s\n' "$cmd"; return
    done
    # Fallback: activity manager
    dumpsys activity activities 2>/dev/null \
        | grep -m1 -E 'topResumedActivity|mResumedActivity' \
        | sed -n 's/.*[ {]\([A-Za-z0-9_.]*\)\/[A-Za-z0-9_.$]*.*/\1/p'
}

in_gamelist() { # in_gamelist <package>
    [ -n "$1" ] || return 1
    [ -r "$GAMELIST" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | tr -d '\r')
        case "$line" in ''|'#'*) continue ;; esac
        # trim surrounding blanks
        line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$line" ] || continue
        [ "$line" = "$1" ] && return 0
    done < "$GAMELIST"
    return 1
}

# --- apply -----------------------------------------------------------------

apply_profile() { # apply_profile <profile>
    if [ "$DRYRUN" = "1" ]; then
        log "dry-run: would apply $1"
        return 0
    fi
    if [ -x "$PROFILER" ] || [ -f "$PROFILER" ]; then
        sh "$PROFILER" "$1" >/dev/null 2>&1
    fi
}

save_state() { # save_state <profile>
    [ "$DRYRUN" = "1" ] && return 0
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    printf '%s\n' "$1" > "$STATEFILE" 2>/dev/null
}

last_state() { cat "$STATEFILE" 2>/dev/null; }

# --- main ------------------------------------------------------------------

if [ -e "$DISABLED" ]; then
    log "disabled ($DISABLED present) — watcher idle"
    exit 0
fi

mkdir -p "$CONFIG_DIR" 2>/dev/null

# single instance (skipped in tests / dry-run)
if [ "$DRYRUN" != "1" ] && [ -z "${USF_NO_SPAWN:-}" ]; then
    PIDFILE="$CONFIG_DIR/watcher.pid"
    if [ -r "$PIDFILE" ]; then
        old=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$old" ] && [ -d "/proc/$old" ]; then
            case "$(tr -d '\0' < "/proc/$old/cmdline" 2>/dev/null)" in
                *usf_watcher*) log "already running (pid $old)"; exit 0 ;;
            esac
        fi
    fi
    printf '%s\n' "$$" > "$PIDFILE"
    trap 'rm -f "$PIDFILE" 2>/dev/null' EXIT INT TERM
fi

while :; do
    scr=$(screen_state)
    if [ "$scr" = "off" ]; then
        profile=powersave
        fg="-"
    else
        fg=$(foreground_package)
        if in_gamelist "$fg"; then
            profile=performance
        else
            profile=balance
        fi
    fi

    prev=$(last_state)
    if [ "$profile" = "$prev" ]; then
        action=skip
    else
        action=apply
        apply_profile "$profile"
        save_state "$profile"
    fi

    log "fg=${fg:-none} screen=$scr profile=$profile action=$action"

    [ -n "${USF_WATCHER_ONCE:-}" ] && exit 0
    sleep "$(interval)"
done
