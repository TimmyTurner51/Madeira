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
while [ $# -gt 0 ]; do
    case "$1" in
        --wait) WAIT="${2:-30}"; shift 2 ;;
        --no-install) INSTALL=0; shift ;;
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

for attempt in 1 2 3 4 5 6; do
    try_find "$(see)" && break
    [ $attempt -ge 4 ] && iosdev swipe 600 1100 600 2100 >/dev/null 2>&1   # scroll up
    sleep 2
done

if [ -z "$found" ]; then echo "ABORT: no FH6 row on screen; nothing was tapped." >&2; exit 2; fi
iosdev tap $found >/dev/null 2>&1
sleep 3

echo "== opening the game details sheet"
s=$(see)
if ! printf '%s\n' "$s" | grep -qi 'Game details'; then
    # A single tap on the cover sometimes just focuses it; the title row opens it.
    iosdev tap $(printf '%s\n' "$s" | grep -iE '  Forza Horizon 6$' | head -1 | awk '{print $1" "$2}' | tr -d ',') >/dev/null 2>&1
    sleep 3
    s=$(see)
fi
if ! printf '%s\n' "$s" | grep -qi 'Forza Horizon 6'; then
    echo "ABORT: details sheet does not name Forza Horizon 6:" >&2
    printf '%s\n' "$s" | head -12 >&2
    exit 2
fi

play=$(printf '%s\n' "$s" | grep -E '  Play$' | head -1)
if [ -z "$play" ]; then
    echo "ABORT: details sheet is up but has no Play button" >&2
    printf '%s\n' "$s" | head -14 >&2
    exit 2
fi
echo "tapping Play at $(printf '%s' "$play" | awk '{print $1", "$2}' | tr -d ',')"
iosdev tap $(printf '%s' "$play" | awk '{print $1" "$2}' | tr -d ',') >/dev/null 2>&1

echo "== waiting ${WAIT}s for the run to develop"
sleep "$WAIT"

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
