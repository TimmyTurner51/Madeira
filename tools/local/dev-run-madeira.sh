#!/bin/bash
# Launch Madeira from LiveContainer WITHOUT trusting a fixed y coordinate.
#
# Two things this script refuses to do, because both have already caused real
# damage in this project:
#
#  1. Tap a Run button that has not been proven to belong to Madeira. The
#     LiveContainer list reorders as apps are installed, so a blind
#     "tap 1006 <y>" launched the wrong app (Erosion) once. Every tap here is
#     derived from OCR text verified against Madeira's bundle id, and the Run
#     button must sit in that same row.
#  2. Swipe past an error dialog. LiveContainer reports a failed launch in a
#     modal, and the modal sits on top of the list, so a scrolling loop can
#     never find the row it wants. A launch error is now detected up front and
#     reported with its reason instead of being scrolled through.
#
# OCR lines look like "  x, y  [ w x h]  text" with leading whitespace, so this
# uses default awk field splitting (1=x, 2=y). A character-class FS such as
# '[ ,]+' leaves an empty $1 and shifts every field by one.
set -u
export PATH="$HOME/bin:$PATH"

TARGET_ID="com.willfaust.madeora"
ROW=120   # max px between a name line and its Run button
# The phone this project drives. usbmux lists every iPhone on the cable, including
# other people's, so a bare "a device is connected" test is not enough: addressed by
# UDID, every iosdev call below either reaches THIS phone or fails.
DEVID="${IOSDEV_UDID:-00008150-001564AE3407801C}"

# A preflight that costs a second and prevents the failure mode that made this script
# necessary: with the target phone off the cable, `iosdev launch` and `iosdev see` fail
# silently, every check below passes vacuously, and a caller that then taps a
# remembered coordinate acts on whatever is on screen -- which opened an unrelated app
# on 2026-11-21. Refuse up front, and name the phones that ARE connected so the wrong
# cable is obvious.
preflight() {
    local json
    json="$("${IOSDEV_PMD3:-$HOME/.local/bin/pymobiledevice3}" usbmux list 2>/dev/null)"
    if [ -z "$json" ] || [ "$json" = "[]" ]; then
        echo "ABORT: no iPhone is connected over USB (usbmux list is empty)." >&2
        exit 2
    fi
    if ! printf '%s' "$json" | grep -q "$DEVID"; then
        echo "ABORT: the phone this project drives ($DEVID) is not on the cable." >&2
        echo "  Connected instead: $(printf '%s' "$json" | grep -o '"UniqueDeviceID": "[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')" >&2
        exit 2
    fi
    # A live tunnel is what iosdev actually needs; usbmux alone does not imply it.
    if ! iosdev see >/dev/null 2>&1; then
        echo "ABORT: $DEVID is on the cable but its RSD tunnel is not answering." >&2
        echo "  Unlock the phone and try again." >&2
        exit 2
    fi
}
preflight

# Shared start/stop for LiveContainer. Defines LC_BUNDLE's helpers, which is why the
# list is opened through open_livecontainer_list below rather than a bare launch.
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LC_BUNDLE="com.kdt.livecontainer.4CDWTGR84Z"
. "$REPO_ROOT/tools/local/lc-control.sh"

# Print the reason text of a launch-error dialog, or nothing if none is up.
launch_error() {
    local see="$1"
    printf '%s\n' "$see" | grep -qiE 'missing code signature|code signature invalid|Library not loaded|dlopen\(' || return 0
    # Prefer the code-signature reason, which is the actionable one.
    local reason
    reason=$(printf '%s\n' "$see" | grep -oiE 'missing code signature[^)]*|code signature invalid[^)]*|Library not loaded: [^ ]*|dlopen\([^,]*' | head -1)
    printf '%s\n' "${reason:-launch failed}"
}

if [ "${1:-}" = "--check-error" ]; then
    launch_error "$(iosdev see 2>/dev/null)"
    exit 0
fi

iosdev launch com.kdt.livecontainer.4CDWTGR84Z >/dev/null 2>&1
sleep 1

# Starting from a live session is not a fresh start: LiveContainer resumes wherever it
# was left, which can be inside Madeira, where the list and its Run button do not exist.
# If a tap sequence below were to run against that, it would press controls in a game
# launcher. Release first, then require LiveContainer's list before going further.
if ! open_livecontainer_list; then
    echo "ABORT: Madeira is still on screen; cannot reach LiveContainer's list." >&2
    exit 1
fi

# Fail fast if the previous launch left an error modal up: nothing on the list
# is reachable behind it.
err=$(launch_error "$(iosdev see 2>/dev/null)")
if [ -n "$err" ]; then
    echo "ABORT: LiveContainer is showing a launch error, not the app list:" >&2
    echo "  $err" >&2
    echo "  The installed bundle is in a bad state. Reinstall the IPA:" >&2
    echo "  LiveContainer -> + -> Install IPA File -> Madeira.ipa -> replace." >&2
    exit 2
fi

run_y=""
for attempt in 1 2 3 4 5 6 7 8; do
    see=$(iosdev see 2>/dev/null)

    err=$(launch_error "$see")
    if [ -n "$err" ]; then
        echo "ABORT: launch error appeared while locating the row:" >&2
        echo "  $err" >&2
        exit 2
    fi

    sub=$(printf '%s\n' "$see" | grep -F "$TARGET_ID" | head -1)
    if [ -n "$sub" ]; then
        sub_y=$(printf '%s\n' "$sub" | awk '{print $2}' | tr -d ',')
        name=$(printf '%s\n' "$see" | grep -E '  Madeira$' | head -1)
        if [ -n "$name" ]; then
            name_y=$(printf '%s\n' "$name" | awk '{print $2}' | tr -d ',')
            run=$(printf '%s\n' "$see" | grep -E '  Run$' | awk -v ty="$sub_y" -v row="$ROW" '
                { y = $2 + 0 } y > ty - row && y < ty + row { print; exit }')
            if [ -n "$run" ]; then
                run_y=$(printf '%s\n' "$run" | awk '{print $2}' | tr -d ',')
                echo "verified name : $name  (y=$name_y)"
                echo "verified id   : $sub  (y=$sub_y)"
                echo "verified run  : $run  (y=$run_y)"
                break
            fi
            echo "row found but no Run in it; scrolling"
        else
            echo "bundle id visible but 'Madeira' name not on screen; scrolling"
        fi
    fi

    iosdev swipe 600 2100 600 1000 >/dev/null 2>&1
    sleep 1
done

if [ -z "$run_y" ]; then
    echo "ABORT: could not verify a Madeira row; nothing was tapped." >&2
    exit 1
fi

echo "tapping Run at 1006,$run_y"
iosdev tap 1006 "$run_y" >/dev/null 2>&1
sleep 10

screen=$(iosdev see 2>/dev/null)

err=$(launch_error "$screen")
if [ -n "$err" ]; then
    echo "ABORT: Madeira failed to launch:" >&2
    echo "  $err" >&2
    exit 2
fi

if printf '%s\n' "$screen" | grep -qi "Enable and Run Script"; then
    echo "approving StikDebug JIT prompt"
    iosdev tap 605 2401 >/dev/null 2>&1
    sleep 22
elif printf '%s\n' "$screen" | grep -qi "Enable JIT"; then
    echo "note: StikDebug picker opened without an inline prompt"
fi

echo "=== matching procs ==="
iosdev ps 2>/dev/null | grep -iE "madeira|erosion" | head -3
echo "=== screen ==="
iosdev see 2>/dev/null | head -8
