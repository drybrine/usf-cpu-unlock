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
#   watcher.interval  poll interval in seconds (default 2)
#   watcher.screen_off  powersave (default) | balance | keep
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
HOLDFILE="$CONFIG_DIR/manual_hold"
SCREENOFF_FILE="$CONFIG_DIR/watcher.screen_off"
# What to do when the panel turns off:
#   powersave (default) | balance | keep (leave the profile alone)
# "keep" exists because the powersave governor can make the unlock animation
# stutter on some devices.
DEFAULT_SCREENOFF=${USF_SCREENOFF_DEFAULT:-powersave}
# A manual profile pick holds until the foreground app changes (or this
# safety TTL expires), so tapping a profile in the WebUI is not instantly
# undone by the next poll.
HOLD_TTL=${USF_HOLD_TTL:-7200}
DRYRUN=${USF_WATCHER_DRYRUN:-0}
PROFILER="$MODULE_DIR/scripts/usf_profiler.sh"

log() { printf '[watcher] %s\n' "$*"; }

now() { printf '%s\n' "${USF_NOW:-$(date +%s)}"; }

screenoff_mode() {
    m=$(head -n 1 "$SCREENOFF_FILE" 2>/dev/null | tr -d '\r' | tr -d ' ')
    case "$m" in
        powersave|balance|keep) printf '%s\n' "$m" ;;
        *) printf '%s\n' "$DEFAULT_SCREENOFF" ;;
    esac
}

# "<epoch>|<package>" of a manual pick, or nothing.
read_hold() {
    [ -r "$HOLDFILE" ] || return 1
    line=$(head -n 1 "$HOLDFILE" 2>/dev/null)
    case "$line" in
        *'|'*) printf '%s\n' "$line"; return 0 ;;
    esac
    return 1
}

# Is a manual pick in force for this foreground app? Sets HOLD_PKG on
# success and drops a stale hold on failure.
HOLD_PKG=""
hold_active() { # hold_active <fg>
    HOLD_PKG=""
    line=$(read_hold) || return 1
    ts=${line%%|*}
    pkg=${line#*|}
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    age=$(($(now) - ts))
    # An unknown foreground (launcher / home screen, where the top-app
    # cpuset often holds nothing with adj 0) must not drop the hold: the
    # user picked a profile and then went home, not into another app.
    if [ "$age" -ge 0 ] && [ "$age" -lt "$HOLD_TTL" ] &&
       { [ -z "$pkg" ] || [ -z "$1" ] || [ "$pkg" = "$1" ]; }; then
        HOLD_PKG=$pkg
        return 0
    fi
    rm -f "$HOLDFILE" 2>/dev/null
    return 1
}

interval() {
    n=$(cat "$INTERVAL_FILE" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=2 ;; esac
    [ "$n" -ge 1 ] 2>/dev/null || n=2
    printf '%s\n' "$n"
}

# --- detection -------------------------------------------------------------

# Panel backlight only: a sysfs read, no process spawn. This is the hot path —
# calling `dumpsys power` on every poll is what made unlocking feel laggy,
# because dumpsys competes with the system exactly while the lock screen is
# lifting. Prints nothing when no backlight node is readable.
screen_state_fast() {
    if [ -n "${USF_SCREEN_STATE:-}" ]; then
        printf '%s\n' "$USF_SCREEN_STATE"; return 0
    fi
    for bl in /sys/class/backlight/*/brightness; do
        [ -r "$bl" ] || continue
        b=$(cat "$bl" 2>/dev/null)
        case "$b" in ''|*[!0-9]*) continue ;; esac
        if [ "$b" -gt 0 ] 2>/dev/null; then printf 'on\n'; else printf 'off\n'; fi
        return 0
    done
    return 1
}

# Ask the power service. Slow, so it is only used to confirm a *transition*:
# the backlight node reads 0 while the panel is merely dimmed or showing AOD,
# which would otherwise look like "screen off" and trigger a needless switch.
confirm_screen() { # confirm_screen <fast-state>
    w=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=')
    case "$w" in
        *Asleep*|*Dozing*) printf 'off\n' ;;
        *Awake*)           printf 'on\n' ;;
        *)                 printf '%s\n' "$1" ;;
    esac
}

LAST_SCREEN=""

screen_state() {
    fast=$(screen_state_fast)
    if [ -z "$fast" ]; then
        # No backlight node at all: ask the power service every time.
        confirm_screen on
        return 0
    fi
    # Hook-driven state is authoritative; never second-guess it with dumpsys.
    if [ -z "${USF_SCREEN_STATE:-}" ] && [ "$fast" != "$LAST_SCREEN" ]; then
        fast=$(confirm_screen "$fast")
    fi
    LAST_SCREEN=$fast
    printf '%s\n' "$fast"
}

# Block while the panel is off, polling the cheap node once a second, so the
# profile is already switched back by the time the screen is usable again.
wait_screen_on() {
    while :; do
        st=$(screen_state_fast) || return 0   # cannot tell -> let main loop decide
        [ "$st" = "off" ] || return 0
        sleep 1
    done
}

foreground_package() {
    if [ -n "${USF_FG_PACKAGE+x}" ]; then
        printf '%s\n' "$USF_FG_PACKAGE"; return
    fi
    # Cheapest reliable signal: the foreground app is the process with
    # oom_score_adj 0 inside the top-app cpuset (no dumpsys needed).
    # Word splitting is intended: cgroup.procs is a whitespace list of PIDs.
    # shellcheck disable=SC2013
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
    soff=$(screenoff_mode)
    skip_hold=""

    if [ "$scr" = "off" ]; then
        fg="-"
        case "$soff" in
            keep)
                # User opted out: the panel going off must not touch the
                # profile. This is the setting for devices where the
                # powersave governor makes unlocking stutter.
                profile=$(last_state)
                [ -n "$profile" ] || profile=balance
                skip_hold=keep
                ;;
            balance)
                profile=balance
                ;;
            *)
                profile=powersave
                ;;
        esac
    else
        fg=$(foreground_package)
        if in_gamelist "$fg"; then
            profile=performance
        else
            profile=balance
        fi
    fi

    if [ -n "$skip_hold" ]; then
        log "fg=none screen=$scr profile=$profile action=skip screenoff=$soff"
        [ -n "${USF_WATCHER_ONCE:-}" ] && exit 0
        wait_screen_on
        continue
    fi

    # Manual pick wins over auto-switching while its app stays foreground.
    # Screen-off behaviour is governed by screenoff_mode instead.
    if [ "$scr" != "off" ] && hold_active "$fg"; then
        log "fg=${fg:-none} screen=$scr profile=$profile action=skip override=manual(${HOLD_PKG:-any})"
        [ -n "${USF_WATCHER_ONCE:-}" ] && exit 0
        sleep "$(interval)"
        continue
    fi

    prev=$(last_state)
    if [ "$profile" = "$prev" ]; then
        action=skip
    else
        # Re-check right before writing: the user may have tapped a profile
        # in the WebUI while this poll was deciding.
        if [ "$scr" != "off" ] && hold_active "$fg"; then
            log "fg=${fg:-none} screen=$scr profile=$profile action=skip override=manual(${HOLD_PKG:-any})"
            [ -n "${USF_WATCHER_ONCE:-}" ] && exit 0
            sleep "$(interval)"
            continue
        fi
        action=apply
        apply_profile "$profile"
        save_state "$profile"
    fi

    log "fg=${fg:-none} screen=$scr profile=$profile action=$action screenoff=$soff"

    [ -n "${USF_WATCHER_ONCE:-}" ] && exit 0
    if [ "$scr" = "off" ]; then
        # Cheap 1s wake poll: the profile is back before the lock screen is
        # usable, instead of up to a full interval later.
        wait_screen_on
    else
        sleep "$(interval)"
    fi
done
