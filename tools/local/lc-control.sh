#!/usr/bin/env bash
# Start and stop LiveContainer deterministically. Sourced by the install and run
# scripts so both agree on what "released" means.
#
# Why this is not a one-line `iosdev launch`:
#
#   * `iosdev launch` on a running LiveContainer only foregrounds it. LiveContainer
#     resumes wherever it was left, so if Madeira was in the foreground the session
#     comes back INSIDE MADEIRA. A caller that then taps an import menu taps into the
#     game launcher instead, and fails with a dialog that has nothing to do with the
#     real problem.
#   * `iosdev kill-bundle` cannot see LiveContainer: its process channel omits the
#     app, so it answers "no matching process" and exits 0 while the app keeps
#     running. The DVT process list does show it, so killing goes through DVT.
#   * `process-id-for-bundle-id` prints `0` for a bundle that is not running. Treating
#     empty output as "dead" therefore never sees a death and spins a full timeout on
#     every run. `lc_pid` normalises `0` to empty for this reason.
#
# Madeira runs as a guest inside LiveContainer, so releasing the host releases the game
# too; there is no separate Madeira process to kill.
#
# Requires the caller to have set LC_BUNDLE (and optionally DEVID, IOSDEV_PMD3) and to
# have iosdev on PATH.

: "${LC_BUNDLE:?lc-control.sh needs LC_BUNDLE}"
DEVID="${DEVID:-${IOSDEV_UDID:-00008150-001564AE3407801C}}"
IOSDEV_PMD3="${IOSDEV_PMD3:-$HOME/.local/bin/pymobiledevice3}"

# pid of LiveContainer, or empty when it is not running.
lc_pid() {
    "$IOSDEV_PMD3" developer dvt process-id-for-bundle-id \
        --udid "$DEVID" "$LC_BUNDLE" 2>/dev/null | tr -dc '0-9' | sed 's/^0*$//'
}

# Stop LiveContainer and wait until it is really gone.
release_livecontainer() {
    local i pid
    pid=$(lc_pid)
    if [ -n "$pid" ]; then
        "$IOSDEV_PMD3" developer dvt kill --udid "$DEVID" "$pid" >/dev/null 2>&1
    fi
    # Some builds answer the kill by relaunching, so keep killing what is left.
    for i in $(seq 1 20); do
        pid=$(lc_pid)
        [ -z "$pid" ] && return 0
        "$IOSDEV_PMD3" developer dvt kill --udid "$DEVID" "$pid" >/dev/null 2>&1
        sleep 1
    done
    return 0
}

# Launch LiveContainer through DVT, which (unlike `iosdev launch`) reports a pid.
launch_livecontainer() {
    "$IOSDEV_PMD3" developer dvt launch --udid "$DEVID" "$LC_BUNDLE" >/dev/null 2>&1 \
        || iosdev launch "$LC_BUNDLE" >/dev/null 2>&1
}

# True when the screen is Madeira's library rather than LiveContainer's list.
# Madeira has a "Search your library" field; the list does not.
inside_madeira() {
    iosdev see 2>/dev/null | grep -qi 'Search your library'
}

# Release and launch, retrying while the session keeps resuming inside Madeira.
# Returns non-zero if Madeira is still on screen, which means the caller cannot use
# the app list and should say so rather than tapping blindly.
open_livecontainer_list() {
    local attempt
    release_livecontainer
    launch_livecontainer
    sleep 7
    for attempt in 1 2 3 4 5; do
        inside_madeira || return 0
        echo "==> LiveContainer resumed inside Madeira; releasing it again" >&2
        release_livecontainer
        launch_livecontainer
        sleep 7
    done
    inside_madeira && return 1
    return 0
}
