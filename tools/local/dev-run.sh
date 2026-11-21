#!/bin/bash
# Launch Madeira and report the outcome, including the on-screen error text when
# the launch is refused. Kept as a file because long inline shell with nested
# $( ) aborts the tool's spawn.
set -u
export PATH="$HOME/bin:$PATH"
BASE=$(iosdev mad-log 2>/dev/null | wc -l | tr -d ' ')

iosdev launch com.kdt.livecontainer.4CDWTGR84Z >/dev/null 2>&1
sleep 7

# Approve StikDebug's JIT prompt if it is showing (it relaunches LiveContainer).
if iosdev see 2>/dev/null | grep -qi "Enable and Run Script"; then
    echo "JIT prompt -> approving"
    iosdev tap 605 2400 >/dev/null 2>&1
    sleep 12
    iosdev launch com.kdt.livecontainer.4CDWTGR84Z >/dev/null 2>&1
    sleep 7
fi

for i in 1 2 3 4 5 6; do
    hit=$(iosdev see 2>/dev/null | grep -i ' Madeira$' | head -1)
    if [ -n "$hit" ]; then
        y=$(printf '%s' "$hit" | awk '{print $2}' | tr -d ',')
        echo "Run at y=$((y+39))"
        iosdev tap 1007 "$((y + 39))" >/dev/null 2>&1
        break
    fi
    iosdev swipe 600 2100 600 900 >/dev/null 2>&1
    sleep 1.2
done

sleep 18
echo "=== madeira alive: $(iosdev ps 2>/dev/null | grep -ci madeira) ==="
echo "=== log delta: $(( $(iosdev mad-log 2>/dev/null | wc -l) - BASE )) ==="
echo "=== screen ==="
iosdev see 2>/dev/null | head -18
