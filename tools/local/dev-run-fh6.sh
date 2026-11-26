#!/bin/bash
# Launch Forza Horizon 6 through Madeira, end to end, without a human.
#
# What this is for: the iteration loop in the objective -- edit, build, push, relaunch,
# read log -- needs the launch itself to stop being a manual step. Everything below is
# derived from ON-STATE text, never from remembered coordinates: the library reorders,
# and this project has already launched the wrong app once by tapping a stored y.
#
#   1. install any .wcp waiting in the guest's Import folder, and confirm with the log
#      that it did (a component half only takes effect on the launch AFTER it installs,
#      so an unconfirmed install silently measures the previous build -- which already
#      cost a whole run here)
#   2. restart Madeira so the newest half is what loads
#   3. open the FH6 row and tap Play, verifying every tap against on-state text
#   4. wait, pull the log, and print the markers that decide the experiment
#
#   tools/local/dev-run-fh6.sh [--wait SECONDS] [--no-install]
#
# Exits 0 when a launch was started, 2 when the UI could not be verified.set -u
export PATH="$HOME/bin:$PATH"
cd "$(dirname "$0")/../.." || exit 1

WAIT=30
INSTALL=1
DRIVE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --wait) WAIT="${2:-30}"; shift 2 ;;
        --no-install) INSTALL=0; shift ;;
        --no-drive) DRIVE=0; shift ;;
        *) shift ;;
    esac
done

GUEST=Documents/Data/Application/EDAFB512-48D7-4839-98DA-E66816D6174E/Documents
# A function, not a variable: the interpreter lives under "Application Support", so an
# unquoted "$PMD3 args" splits at the space and runs the wrong argv. That failed
# silently inside this script for several runs -- every in-script pull reported "could
# not read the log" while the same command typed by hand worked.
pmd3() { "$HOME/Library/Application Support/pipx/venvs/pymobiledevice3/bin/python" "$@"; }

see() { iosdev see 2>/dev/null; }

pull_log() {
    local out="$1" i
    rm -f "$out"
    for i in 1 2 3 4; do
        pmd3 tools/local/afc-pull.py "$GUEST/madeira-log.txt" "$out" 2>/dev/null && [ -s "$out" ] && return 0
        sleep 3
    done
    return 1
}

# A row is a name line and its tile; ROW is the max px either can be from the other.
ROW=300

count_waiting() {
    # Exit 1 (container unreachable) must not read as "nothing to install": that is how
    # a run silently measures the previous build.
    pmd3 tools/local/wcp-count.py 2>/dev/null || echo "unknown"
}

# Count BEFORE the restart: that launch consumes the package, so looking afterwards
# always finds an empty folder and cannot tell "nothing to install" from "already
# installed into the WRONG session" (the one that is still running the old code).
waiting=$(count_waiting)

echo "== restarting Madeira (loads whatever half is installed now)"
./tools/local/dev-run-madeira.sh >/tmp/fh6-launch-step1.log 2>&1 || {
    tail -6 /tmp/fh6-launch-step1.log; echo "ABORT: Madeira did not come up" >&2; exit 2; }
tail -3 /tmp/fh6-launch-step1.log

# The install step. A package in Import is consumed by the launch in progress, which
# means the half it replaces is still the one Wine is running from; the NEXT launch is
# the first that runs the new code. `waiting` was counted before the restart above for
# exactly this reason.
if [ "$INSTALL" = 1 ] && [ "${waiting:-0}" != "0" ]; then
    echo "== $waiting package(s) were installed by that launch; restarting once more so the new code is what runs"
    ./tools/local/dev-run-madeira.sh >/tmp/fh6-launch-step1b.log 2>&1 || {
        echo "ABORT: second restart failed" >&2; exit 2; }
    sleep 3
    pull_log /tmp/fh6-install.txt && LC_ALL=C grep -a '\[wcp\] imported\|unix-half\] ' /tmp/fh6-install.txt | tail -2 | cut -c1-140
fi

# Keep exactly ONE UnixHalf enabled. Do it here, after the import, because that is
# the first moment the new component exists in state.json -- enabling it from the
# build script ran too early and left nothing enabled (ml2136). Two or more alive at
# once is what made ml2132/2133/2134 disagree: each half prints its own lines, so a
# probe "printing nothing" may just be the half nobody is calling (§4ah, §4ak).
if [ -z "${MADEIRA_KEEP_OTHER_HALVES:-}" ]; then
    HALFDIR="Documents/Data/Application/EDAFB512-48D7-4839-98DA-E66816D6174E/Documents"
    if DEVICE_FILE_ROUTE=pmd3 ./tools/local/device-file.sh get "$HALFDIR/Components/state.json" /tmp/_halfstate.json >/dev/null 2>&1; then
        python3 - <<'PY'
import json
d = json.load(open("/tmp/_halfstate.json"))
halves = [c for c in d["components"] if c.get("type") == "UnixHalf"]
on = [c for c in halves if c.get("enabled")]
if len(on) <= 1:
    print(f"== UnixHalf: {len(on)} enabled" + (f" ({on[0]['name']})" if on else ""))
else:
    # Keep the newest by name (mlNNNN sorts lexically) and turn the rest off.
    keep = sorted(on, key=lambda c: c.get("name", ""))[-1]
    for c in on:
        if c is not keep:
            c["enabled"] = False
    json.dump(d, open("/tmp/_halfstate.json", "w"))
    print(f"== UnixHalf: {len(on)} were enabled; keeping {keep['name']}, disabling "
          + ", ".join(c['name'] for c in on if c is not keep))
PY
        DEVICE_FILE_ROUTE=pmd3 ./tools/local/device-file.sh put /tmp/_halfstate.json "$HALFDIR/Components/state.json" >/dev/null 2>&1 \
            && echo "   restarted Madeira needed? no -- this applies to the next launch"
    fi
fi

echo "== locating Forza Horizon 6 in the library"
# DO NOT SCROLL FIRST. Measured: on a fresh Madeira start FH6 is the FIRST game in
# the list and the list is already at the top, so the row is on the very first
# screen. An earlier version of this script swiped up to six times while looking
# for it, which walked the grid straight past the F's and then reported "no FH6 row
# on screen" -- a locator that destroys the thing it is looking for.
#
# So: look, wait, look again. If it is genuinely absent, scroll UP (back toward the
# top) and look again, which is the only direction that can recover from a list left
# scrolled by a previous run.
found=""
try_find() {
    local s="$1" line
    line=$(printf '%s\n' "$s" | grep -iE '  Forza Horizon 6$' | head -1)
    [ -z "$line" ] && return 1
    local y ay ax art
    y=$(printf '%s\n' "$line" | awk '{print $2}' | tr -d ',')
    art=$(printf '%s\n' "$s" | grep -iE '  (FORZA|HORIZON 6)$' | head -1)
    if [ -n "$art" ]; then
        ay=$(printf '%s\n' "$art" | awk '{print $2}' | tr -d ',')
        ax=$(printf '%s\n' "$art" | awk '{print $1}' | tr -d ',')
        if [ "$ay" -gt $((y - ROW)) ] && [ "$ay" -lt $((y + ROW)) ]; then
            found="$ax $ay"; echo "verified row: $line (y=$y) cover at $found"; return 0
        fi
    fi
    # Title is there but the wordmark was not OCR'd as a separate box: tap the title.
    found=$(printf '%s' "$line" | awk '{print $1" "$2}' | tr -d ',')
    echo "verified row by title only: $line -> tap $found"
    return 0
}

# Convert screenshot OCR coordinates to device-portrait tap coordinates (1206x2622).
# When Madeira opens in landscape-right (2622x1206), iosdev see returns landscape
# pixels scaled to 1206x554 or full 2622x1206; detect actual orientation via a probe shot.
_is_landscape() {
    local tmp=/tmp/_fh6_orient.png w h
    iosdev shot "$tmp" >/dev/null 2>&1 || return 1
    w=$(sips -g pixelWidth "$tmp" 2>/dev/null | awk '/pixelWidth/{print $2}')
    h=$(sips -g pixelHeight "$tmp" 2>/dev/null | awk '/pixelHeight/{print $2}')
    [ "${w:-0}" -gt "${h:-0}" ]
}

tap_ocr() {
    local ox="$1" oy="$2"
    if _is_landscape; then
        # Landscape-right (2622x1206): OCR coords are in landscape space (scale 2622/1206 if needed)
        local tmp=/tmp/_fh6_orient.png w h px py
        w=$(sips -g pixelWidth "$tmp" 2>/dev/null | awk '/pixelWidth/{print $2}')
        h=$(sips -g pixelHeight "$tmp" 2>/dev/null | awk '/pixelHeight/{print $2}')
        # iosdev see normalizes width to 1206 (so landscape 2622x1206 -> 1206x555)
        local lx ly
        lx=$(( ox * w / 1206 ))
        ly=$(( oy * w / 1206 ))
        px=$(( h - ly ))
        py=$lx
        iosdev tap "$px" "$py" >/dev/null 2>&1
    else
        iosdev tap "$ox" "$oy" >/dev/null 2>&1
    fi
}

# Tap the A button of Madeira's built-in "Xbox controller" touch layout.
#
# This is the only input FH6's own menus accept. Two things make the obvious
# approach (tap the "Continue" text) silently do nothing:
#   * a tap on the game view that misses every control is NOT sent to the guest
#     while controller mappings are shown (docs/CONTROLLERS.md, touch controls),
#     so the click is swallowed by the overlay instead of reaching the menu;
#   * the menus are gamepad-only, so even a tap that did arrive would not select.
# The position comes from TouchControlPresets.xbox(for:) -- the same formula the
# app lays the layout out with -- so it follows the real screen instead of a
# remembered pixel. Landscape-right: portrait x is (height - landscape y).
# A tap of ~50 ms is NOT a press as far as the guest is concerned. Measured in the
# 11:39 run: `iosdev tap` on the pad's A produced exactly one XInput sample
# ([11:40:18.947] buttons=0x1000, [11:40:18.980] buttons=0x0 -- 33 ms apart), and the
# game runs at 10-20 FPS, so no frame the title ever drew contained that press. The
# tap was delivered, sampled once, and dropped. Every press here therefore holds the
# contact for HOLD seconds (a drag with the same start and end), which keeps A down
# for several guest frames.
HOLD=0.45
pad_press() {
    local px=$1 py=$2 hold=${3:-$HOLD}
    iosdev swipe "$px" "$py" "$px" "$py" --duration "$hold" --steps 1 >/dev/null 2>&1
}

tap_pad_A() {
    local tmp=/tmp/_fh6_pad.png w h px py
    iosdev shot "$tmp" >/dev/null 2>&1 || return 1
    w=$(sips -g pixelWidth "$tmp" 2>/dev/null | awk '/pixelWidth/{print $2}')
    h=$(sips -g pixelHeight "$tmp" 2>/dev/null | awk '/pixelHeight/{print $2}')
    [ "${w:-0}" -gt 0 ] && [ "${h:-0}" -gt 0 ] || return 1
    read -r px py <<EOF
$(python3 - "$w" "$h" <<'PY'
import sys
w, h = int(sys.argv[1]), int(sys.argv[2])
landscape = w > h
# Landscape pixels, and the portrait tap space (width = the short side).
lw, lh = (w, h) if landscape else (h, w)
W, H = lw / 3.0, lh / 3.0
L = R = 59.0
k = min(max(H / 400.0, 1.0), 1.3)
base = 64.0
d = lambda s: base * s
sh = d(0.88 * k)
shW, shH = sh * 1.6, sh * 0.74
triggerY = 8 + 6 * k + shH / 2
bumperY = triggerY + shH + 8 * k
rowBottom = bumperY + shH / 2
face = d(0.78 * k)
o = face / 2 + 22 * k
cx = W - max(R, 16) - 6 * k - o - face / 2
cy = rowBottom + 8 * k + o + face / 2
lx, ly = cx * 3.0, (cy + o) * 3.0          # A, in landscape device pixels
if landscape:
    print(int(round(lh - ly)), int(round(lx)))   # landscape-right rotation
else:
    print(int(round(w - ly * w / lh)), int(round(lx * w / lh)))
PY
)
EOF
    echo "   A at $px,$py (hold ${HOLD}s)"
    pad_press "$px" "$py"
}

# Press pad A until $1 stops appearing on screen. Verified, not blind: the old
# version tapped once per 4 s look and moved on whether or not anything happened, so
# a swallowed press was indistinguishable from a menu that simply did not open. It
# now says so when A is not accepted instead of pretending the game advanced.
press_A_until_gone() {
    local re=$1 tries=${2:-4} i s
    for i in $(seq 1 "$tries"); do
        tap_pad_A || return 1
        sleep 3
        s=$(see)
        if ! printf '%s\n' "$s" | grep -qiE "$re"; then
            echo "== A accepted (after $i press(es))"
            return 0
        fi
        echo "== /$re/ still on screen after press $i"
    done
    echo "== A NEVER accepted: /$re/ still shown after $tries holds" >&2
    return 1
}

# Drive FH6's own menus from on-state text until the game is actually running.
# START is Enter (the title screen answers it); everything after that wants A.
drive_into_game() {
    local round s blank=0
    for round in $(seq 1 "${1:-10}"); do
        s=$(see)
        if printf '%s\n' "$s" | grep -qiE 'Continue|Resume'; then
            echo "== menu: A on Continue (held, then verified)"
            press_A_until_gone 'Continue|Resume' || \
                echo "== NOTE: Continue did not clear; log below shows what A did" >&2
        elif printf '%s\n' "$s" | grep -qiE 'Start Game|Press any|Festival|Welcome, '; then
            echo "== title/menu: pressing START"
            iosdev key enter >/dev/null 2>&1
            sleep 2
            s=$(see)
            # The title answers Enter; if it did not, try A before waiting a round.
            printf '%s\n' "$s" | grep -qiE 'Continue|Resume|Start Game|Press any' && tap_pad_A
        elif printf '%s\n' "$s" | grep -qiE 'Garage|Horizon Life|My Cars|Freeroam|Buy & Sell|Time Driven|Horizon Invitational|Complete the|Skill Score|ANNA'; then
            echo "== in game (garage/world)"
            return 0
        else
            # Nothing to act on yet: the title and the world's first frames both
            # read as blank. Wait and look again rather than declaring victory.
            #
            # ...but blank is also what an FH6 COMPATIBILITY WARNING looks like.
            # FH6 creates that dialog with every window at visible=0 (win-name #51:
            # "We have detected the following hardware issues ... Code: FH202"), so
            # nothing is drawn, no OCR text exists, and the game sits behind it
            # forever. Pressing Enter and A dismisses it; doing so on a screen that
            # has no dialog is harmless (the title ignores input it does not want).
            blank=$((blank + 1))
            if [ "$blank" -ge 2 ]; then
                echo "== blank screen: Enter + A (a hidden dialog, e.g. FH202, blocks like this)"
                iosdev key return >/dev/null 2>&1
                sleep 1
                tap_pad_A
                blank=0
                continue
            fi
            echo "== no menu text yet; waiting"
        fi
        sleep "${2:-4}"
    done
    echo "== menus never settled after ${1:-10} looks; continuing anyway"
    return 0
}

scroll_down() {
    if _is_landscape; then
        iosdev swipe 200 1300 900 1300 >/dev/null 2>&1
    else
        iosdev swipe 600 2000 600 900 >/dev/null 2>&1
    fi
}

scroll_up() {
    if _is_landscape; then
        iosdev swipe 900 1300 200 1300 >/dev/null 2>&1
    else
        iosdev swipe 600 1100 600 2100 >/dev/null 2>&1
    fi
}

for attempt in 1 2 3 4 5 6; do
    cur=$(see)
    try_find "$cur" && break
    if [ $attempt -eq 1 ]; then
        # Ensure Steam filter pill is selected if visible
        steam=$(printf '%s\n' "$cur" | grep -E '  Steam$' | head -1)
        if [ -n "$steam" ]; then
            tap_ocr $(printf '%s' "$steam" | awk '{print $1" "$2}' | tr -d ',')
            sleep 1
            cur=$(see)
            try_find "$cur" && break
        fi
        scroll_down
    elif [ $attempt -eq 2 ] || [ $attempt -eq 3 ]; then
        scroll_down
    else
        scroll_up
    fi
    sleep 2
done

if [ -z "$found" ]; then echo "ABORT: no FH6 row on screen; nothing was tapped." >&2; exit 2; fi
tap_ocr $found
sleep 3

echo "== opening the game details sheet"
s=$(see)
if ! printf '%s\n' "$s" | grep -qi 'Game details'; then
    # A single tap on the cover sometimes just focuses it; the title row opens it.
    tap_ocr $(printf '%s\n' "$s" | grep -iE '  Forza Horizon 6$' | head -1 | awk '{print $1" "$2}' | tr -d ',')
    sleep 3
    s=$(see)
fi
if ! printf '%s\n' "$s" | grep -qi 'Forza Horizon 6'; then
    echo "ABORT: details sheet does not name Forza Horizon 6:" >&2
    printf '%s\n' "$s" | head -12 >&2
    exit 2
fi

play=$(printf '%s\n' "$s" | grep -iE '  Play$' | head -1)
if [ -z "$play" ]; then
    echo "ABORT: details sheet is up but has no Play button" >&2
    printf '%s\n' "$s" | head -14 >&2
    exit 2
fi
echo "tapping Play at $(printf '%s' "$play" | awk '{print $1", "$2}' | tr -d ',')"
tap_ocr $(printf '%s' "$play" | awk '{print $1" "$2}' | tr -d ',')

echo "== waiting ${WAIT}s for the run to develop"
sleep "$WAIT"

# The launch is not the goal: the game has to be RUNNING for any measurement to
# mean something, and its menus only take gamepad A (see tap_pad_A).
if [ "$DRIVE" = 1 ]; then
    echo "== driving FH6 through its own menus (START, then A)"
    drive_into_game 24 6 || echo "   NOTE: menus did not settle; log below is from whatever is on screen"
fi

# One pull, then one line per decisive marker.
LOG="$GUEST/madeira-log.txt"
rm -f /tmp/fh6-run.txt
for i in 1 2 3 4; do
    pmd3 tools/local/afc-pull.py "$LOG" /tmp/fh6-run.txt 2>/dev/null \
        && [ -s /tmp/fh6-run.txt ] && break
    sleep 3
done
if [ ! -s /tmp/fh6-run.txt ]; then echo "ABORT: could not read the log" >&2; exit 1; fi
echo "== log: $(wc -c </tmp/fh6-run.txt | tr -d ' ') bytes in /tmp/fh6-run.txt"

for pat in "stub-census] v2 armed" "stub-census] waiting" "COPIES DISAGREE" "every entry decrypted" \
           "text-sync] #" "arena-progress]" "Invalid instruction in entry" "guest-rwx] #"; do
    n=$(LC_ALL=C grep -ac "$pat" /tmp/fh6-run.txt)
    printf '   %-28s %s\n' "$pat" "$n"
done

# ml1299: what the swap tier is holding NOW, by address band and size, and which
# extents are the largest. This is the number that explains page-in stalls: the
# commit census counts requests since start, not bytes live.
echo "== swap (ml1299 live breakdown)"
LC_ALL=C grep -a '\[swap-live\]' /tmp/fh6-run.txt | tail -10 | cut -c1-210
echo "== swap policy"
LC_ALL=C grep -a '\[swap\] ml2021' /tmp/fh6-run.txt | tail -1 | cut -c1-170
LC_ALL=C grep -a '\[swap\] census' /tmp/fh6-run.txt | tail -1 | cut -c1-260
