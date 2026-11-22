#!/bin/bash
# Move files into and out of LiveContainer's container when devicectl will not.
#
#   tools/local/device-file.sh get  <remote> <local>
#   tools/local/device-file.sh put  <local>  <remote>
#   tools/local/device-file.sh ls   [remote]
#
# Why this exists. `xcrun devicectl device copy --domain-type appDataContainer`
# is the only channel `iosdev app-get/app-put/app-ls/mad-log` use, and it wedges
# independently of everything else: on 2026-11-21 01:0x it hung for seven
# minutes per call -- no timeout, no error, just nothing -- while `iosdev see`
# kept answering and `devicectl list devices` still said "connected". The effect
# was that a temporary config line could not be removed from the phone and the
# log could not be read, so the session stalled on a file transfer, not on FH6.
#
# `pymobiledevice3 apps push/pull` reaches the same app container through a
# different service and kept working throughout. It takes paths relative to the
# container root (so "Documents/..." rather than the app's absolute path), which
# is why the remote argument here is always the container-relative form.
#
# Both routes are attempted; devicectl first because it is the documented one,
# then the fallback. Every attempt is bounded, because the failure mode this
# guards against is an unbounded hang rather than an error.
set -u

LC_BUNDLE="${LC_BUNDLE:-com.kdt.livecontainer.4CDWTGR84Z}"
DEVID="${IOSDEV_UDID:-00008150-001564AE3407801C}"
PMD3="${IOSDEV_PMD3:-$HOME/.local/bin/pymobiledevice3}"
# Generous enough for a multi-MB log over USB, short enough that a wedge is
# noticed: the observed hang never recovered, so waiting longer only costs time.
LIMIT="${DEVICE_FILE_TIMEOUT:-60}"
# auto | devicectl | pmd3. A caller that has already seen devicectl wedge once can
# pin pmd3 and stop paying the timeout on every call -- the archiver polls every
# few seconds, so a 60s miss per poll is the difference between a log and no log.
ROUTE="${DEVICE_FILE_ROUTE:-auto}"

# No `timeout` on stock macOS. Run in the background, poll, then kill the tree.
bounded() {
    local secs="$1"; shift
    "$@" & local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            kill -TERM "$pid" 2>/dev/null
            sleep 1
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# Same, but the command needs the piped AFC script on stdin. A command started
# with & gets /dev/null for stdin when job control is off, so the pipe above would
# be discarded and the shell would print nothing -- the twin repair silently
# never ran because of exactly that. Redirect from a file instead: an explicit
# redirect survives the backgrounding.
bounded_in() {
    local in="$1" secs="$2"; shift 2
    "$@" < "$in" &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            kill -TERM "$pid" 2>/dev/null
            sleep 1
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

devicectl_get() {
    bounded "$LIMIT" xcrun devicectl device copy from \
        --device "$DEVID" --domain-type appDataContainer \
        --domain-identifier "$LC_BUNDLE" \
        --source "$1" --destination "$2" >/dev/null 2>&1
}

devicectl_put() {
    bounded "$LIMIT" xcrun devicectl device copy to \
        --device "$DEVID" --domain-type appDataContainer \
        --domain-identifier "$LC_BUNDLE" \
        --source "$1" --destination "$2" >/dev/null 2>&1
}

pmd3_get() {
    bounded "$LIMIT" "$PMD3" apps pull --udid "$DEVID" "$LC_BUNDLE" "$1" "$2" >/dev/null 2>&1
}

# `apps pull` asks AFC to open the path, and AFC in this container refuses a file
# with more than one hard link: FILE_OPEN answers status 1 ("unknown"), not the
# status 8 a missing path gives, so the failure reads like a transport fault.
# Madeira's own live log is hard-linked by design (LogStore.startSessionLog keeps
# `Documents/logs/<program>-<stamp>.txt` pointing at the same inode), which makes
# `madeira-log.txt` nlink=2 for the whole session -- measured 2026-11-21:
#
#   madeira-log.txt / madeira-log.prev.txt   nlink 2 -> status 1
#   madeira-last-game-log.txt, rotated logs  nlink 1 -> read fine
#
# afc-pull.py stats first and, when nlink > 1, unlinks the redundant `logs/` name
# (same inode, app prunes that directory itself) so the file becomes openable.
# Nothing is lost: the inode stays reachable by the name we read.
afc_pull() {
    local py
    py="$(dirname "$0")/afc-pull.py"
    [ -f "$py" ] || return 1
    IOSDEV_UDID="$DEVID" LC_BUNDLE="$LC_BUNDLE" \
        bounded "$LIMIT" python3 "$py" "$1" "$2" "$LC_BUNDLE" >/dev/null 2>&1
}

pmd3_put() {
    bounded "$LIMIT" "$PMD3" apps push --udid "$DEVID" "$LC_BUNDLE" "$1" "$2" >/dev/null 2>&1
}

cmd="${1:-}"
case "$cmd" in
get)
    remote="${2:?usage: get <remote> <local>}"; local_="${3:?usage: get <remote> <local>}"
    rm -f "$local_"
    try_devicectl() {
        [ "$ROUTE" = pmd3 ] && return 1
        devicectl_get "$remote" "$local_" && [ -s "$local_" ]
    }
    try_pmd3() {
        [ "$ROUTE" = devicectl ] && return 1
        if pmd3_get "$remote" "$local_" && [ -s "$local_" ]; then return 0; fi
        afc_pull "$remote" "$local_" && [ -s "$local_" ]
    }
    # Diagnostics go to stderr: this is called from a loop that captures stdout
    # as the log body, and a route banner inside the log is a corrupted log.
    if try_devicectl; then
        echo "get: devicectl ($remote)" >&2
        exit 0
    fi
    if try_pmd3; then
        echo "get: pymobiledevice3 apps pull ($remote)" >&2
        exit 0
    fi
    echo "get: FAILED for $remote (devicectl timed out and the app-container fallback did not produce a file)" >&2
    exit 1
    ;;
put)
    local_="${2:?usage: put <local> <remote>}"; remote="${3:?usage: put <local> <remote>}"
    [ -f "$local_" ] || { echo "put: no such local file: $local_" >&2; exit 1; }
    # A push that returns success is not evidence the bytes landed; read the file
    # back and compare, which is the same rule push-fex-to-device.sh follows.
    for route in devicectl pmd3; do
        [ "$ROUTE" != auto ] && [ "$ROUTE" != "$route" ] && continue
        if [ "$route" = devicectl ]; then devicectl_put "$local_" "$remote"; else pmd3_put "$local_" "$remote"; fi
        [ $? -eq 0 ] || continue
        verify="/tmp/.device-file-verify.$$"
        if [ "$route" = devicectl ]; then devicectl_get "$remote" "$verify"; else pmd3_get "$remote" "$verify"; fi
        if [ -f "$verify" ] && cmp -s "$local_" "$verify"; then
            rm -f "$verify"
            echo "put: $route (verified by read-back)" >&2
            exit 0
        fi
        rm -f "$verify"
    done
    echo "put: FAILED or unverified for $remote" >&2
    exit 1
    ;;
ls)
    remote="${2:-.}"
    # `apps afc` is interactive-only, so list by asking for a directory the only
    # way both transports support: a pull of the directory is not possible, so
    # this reports what devicectl says and is expected to be the weak one here.
    bounded "$LIMIT" xcrun devicectl device info files \
        --device "$DEVID" --domain-type appDataContainer \
        --domain-identifier "$LC_BUNDLE" \
        --subdirectory "$remote" --no-recurse
    exit $?
    ;;
logs)
    # Fetch the live session log. This needs one repair first.
    #
    # startSessionLog() hardlinks Documents/madeira-log.txt to
    # Documents/logs/<program>-<stamp>.txt so a finished run keeps a name. AFC
    # refuses to open any file with st_nlink > 1 (house_arrest sandbox rule), so
    # for as long as that link exists the session log -- the current one and the
    # rotated previous one -- reads as FILE_OPEN failed. Measured 2026-11-21:
    # logs/..._23-24-19.txt had nlink 1 and read fine, logs/..._01-33-25.txt had
    # nlink 2 and failed with the same bytes on disk.
    #
    # So: unlink the newest archive name (the twin of the current log, whose
    # stamp is the latest session start), which drops nlink to 1 and makes the
    # log readable. The log's contents are untouched; only the second name goes.
    remote_dir="${2:-Documents/Data/Application/EDAFB512-48D7-4839-98DA-E66816D6174E/Documents}"
    out="${3:-/tmp/madeira-log.txt}"
    script=$(mktemp /tmp/.device-file-afc.XXXXXX)
    printf 'cd %s\nstat madeira-log.txt\nls logs\n' "$remote_dir" > "$script"
    listing=$(bounded_in "$script" "$LIMIT" "$PMD3" apps afc --udid "$DEVID" "$LC_BUNDLE" 2>/dev/null)
    rm -f "$script"
    # Match the twin by birthtime, not size: the log is being appended to while
    # this runs, so two stats of the same inode seconds apart differ (measured
    # 2964112 vs 2969005 during a live run). Birthtime is fixed per inode.
    live_birth=$(printf '%s\n' "$listing" | sed -n 's/^st_birthtime: *//p' | head -1)
    names=$(printf '%s\n' "$listing" |
        grep -oE '[A-Za-z0-9._-]+-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.txt')
    if [ -n "$names" ] && [ -n "$live_birth" ]; then
        # Stamps sort chronologically, so the greatest name is the session in
        # progress -- and its twin must have the same birthtime. Check before
        # deleting: an older archive name is the only copy of that run's log, so
        # removing one that is not the live twin destroys it.
        twin=$(printf '%s\n' "$names" | sort | tail -1)
        script=$(mktemp /tmp/.device-file-afc.XXXXXX)
        printf 'cd %s\nstat logs/%s\n' "$remote_dir" "$twin" > "$script"
        twin_birth=$(bounded_in "$script" "$LIMIT" "$PMD3" apps afc --udid "$DEVID" "$LC_BUNDLE" 2>/dev/null |
            sed -n 's/^st_birthtime: *//p' | head -1)
        rm -f "$script"
        if [ -n "$twin_birth" ] && [ "$twin_birth" = "$live_birth" ]; then
            script=$(mktemp /tmp/.device-file-afc.XXXXXX)
            printf 'cd %s\nrm logs/%s\n' "$remote_dir" "$twin" > "$script"
            bounded_in "$script" "$LIMIT" "$PMD3" apps afc --udid "$DEVID" "$LC_BUNDLE" >/dev/null 2>&1
            rm -f "$script"
            echo "logs: dropped hardlink twin logs/$twin (AFC will not read nlink 2)" >&2
        fi
    fi
    exec "$(dirname "$0")/device-file.sh" get "$remote_dir/madeira-log.txt" "$out"
    ;;
*)
    sed -n '2,10p' "$0"
    exit 2
    ;;
esac
