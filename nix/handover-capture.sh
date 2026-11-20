# hecate-handover-capture: what the kernel's display driver did while the login screen handed
# the monitor to a session. For a frame that still goes black at login.
#
#   sudo hecate-handover-capture
#
# then log out and log back in. It waits for the login screen to tell its hecate to exit,
# turns on the kernel's KMS, atomic and state debug output until the session's hecate has
# committed its first frame, and writes to /var/log/hecate-handover-capture.log:
#   - what was on screen before and after (mode, format, modifier, VRR of every plane and CRTC)
#   - what hecate and hecate-greetd logged
#   - every atomic commit the kernel saw in between, and the lines that matter picked out
# The debug output is off again as soon as that frame is up, or after five minutes.

log=/var/log/hecate-handover-capture.log
dbg=/sys/module/drm/parameters/debug
wait_s=${HECATE_CAPTURE_WAIT:-300}

if [ "$(id -u)" != 0 ]; then
    echo "hecate-handover-capture needs root: sudo hecate-handover-capture" >&2
    exit 1
fi
if [ ! -w "$dbg" ]; then
    echo "$dbg is not there: this kernel has no DRM debug switch" >&2
    exit 1
fi

# Logging out ends the terminal this was started from, so the recording runs as a unit.
if [ "${1:-}" != --run ]; then
    systemctl stop hecate-handover-capture.service 2>/dev/null || true
    systemctl reset-failed hecate-handover-capture.service 2>/dev/null || true
    systemd-run --unit=hecate-handover-capture --collect --quiet \
        --setenv=HECATE_CAPTURE_WAIT="$wait_s" "$0" --run
    echo "Recording for the next $((wait_s / 60)) minutes. Log out, then log back in."
    echo "Afterwards the capture is in $log"
    exit 0
fi

old=$(cat "$dbg")
restore() { echo "$old" >"$dbg"; }
trap restore EXIT

# Every card's atomic state as the kernel has it now.
state() {
    for f in /sys/kernel/debug/dri/*/state; do
        if [ -r "$f" ]; then
            echo "-- $f"
            cat "$f" || true
        fi
    done
}

tmp=$(mktemp -d)
since=$(date '+%Y-%m-%d %H:%M:%S')
state >"$tmp/started" 2>&1

exit_at=""
first_at=""
phase=waiting
coproc journal { journalctl -f -n 0 -o cat -t hecate -t hecate-greetd; }
deadline=$((SECONDS + wait_s))
while [ $SECONDS -lt $deadline ]; do
    IFS= read -r -t 1 line <&"${journal[0]}" || continue
    case "$phase:$line" in
        waiting:*"telling hecate to exit"*)
            # KMS | ATOMIC | STATE: every commit, with the state it asks for.
            echo 0x54 >"$dbg"
            exit_at=$(date +%s)
            state >"$tmp/greeter" 2>&1
            phase=handover
            ;;
        handover:*"first frame on"*)
            # The other monitors' first frames, and whatever follows at once.
            sleep 0.5
            restore
            first_at=$(date +%s)
            state >"$tmp/session" 2>&1
            phase=recorded
            break
            ;;
    esac
done
restore
if [ -n "${journal_PID:-}" ]; then
    kill "$journal_PID" 2>/dev/null || true
fi

interesting='mode_changed|needs_modeset|active_changed|connectors_changed|color_mgmt_changed|planes_changed|UPDATE_TYPE|update_type|full update|minimal transition|fb=|format=|modifier=|vrr|freesync|gamma|degamma|ctm|blank|disabl|Adding all current|\[PLANE|\[CRTC|commit '
{
    echo "hecate-handover-capture, started $since"
    case "$phase" in
        waiting) echo "No login was seen within $wait_s s: nothing recorded." ;;
        handover) echo "The login screen exited, but no session's first frame was seen within $wait_s s." ;;
        recorded) echo "Recorded one login: exit asked at $(date -d "@$exit_at" '+%H:%M:%S'), first frame by $(date -d "@$first_at" '+%H:%M:%S')." ;;
    esac
    echo
    echo "== kernel and driver"
    uname -r
    cat /proc/cmdline
    for c in /sys/class/drm/card*/device/driver; do
        if [ -e "$c" ]; then
            echo "$c -> $(readlink "$c")"
        fi
    done
    echo
    echo "== hecate and hecate-greetd"
    journalctl -b -t hecate -t hecate-greetd --since "$since" -o short-precise --no-pager || true
    echo
    echo "== on screen when this started (the session it was started from)"
    cat "$tmp/started"
    if [ -n "$exit_at" ]; then
        echo
        echo "== on screen when the login screen was told to exit (what the session has to match)"
        cat "$tmp/greeter"
    fi
    if [ -n "$first_at" ]; then
        echo
        echo "== on screen after the session's first frame"
        cat "$tmp/session"
        echo
        echo "== what changed between the two"
        diff "$tmp/greeter" "$tmp/session" || true
        echo
        echo "== kernel, the lines that matter"
        journalctl -k -b --since "@$((exit_at - 1))" --until "@$((first_at + 1))" -o short-precise --no-pager \
            | grep -Ei "$interesting" | tail -n 600 || true
        echo
        echo "== kernel, everything from the exit to the first frame"
        journalctl -k -b --since "@$((exit_at - 1))" --until "@$((first_at + 1))" -o short-precise --no-pager \
            | tail -n 6000 || true
    fi
} >"$log" 2>&1
rm -rf "$tmp"
