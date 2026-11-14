#!/bin/bash
# Where is the Forza-on-iOS loop, right now?
#
# Reads three facts off the device and prints a verdict, so a working session
# never has to guess whether a build was installed or whether the game ran:
#
#   staged    the IPA waiting in LiveContainer's container (its Info.plist bump
#             is what identifies it, not its file name -- names are reused)
#   installed the app bundle LiveContainer actually has in Documents/Applications
#   last run  the newest forzahorizon6 session log and the build that wrote it
#
# Usage: tools/fh6-checkpoint.sh            verdict + details
#        tools/fh6-checkpoint.sh --quiet    one line only (for polling)
#
# Exit codes: 0 installed build is the staged build, 1 install is stale,
#             2 cannot tell (device or container unreachable).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOSDEV="${IOSDEV:-$HOME/bin/iosdev}"
LC_DATA="Documents/Data/Application/EDAFB512-48D7-4839-98DA-E66816D6174E"
LC_APPS="Documents/Applications"
BUNDLE="com.willfaust.madeora.app"
IPA="$ROOT/dist/Madeira.ipa"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
fail() { [ "$QUIET" = 1 ] || printf 'checkpoint: %s\n' "$*"; exit 2; }

plist_build() {   # plist_build <path> -> "version build"
    local v b
    v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1" 2>/dev/null) || return 1
    b=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1" 2>/dev/null) || return 1
    printf '%s %s' "$v" "$b"
}

staged=""
if [ -f "$IPA" ]; then
    tmp=$(mktemp -d)
    unzip -o -q "$IPA" 'Payload/Madeira.app/Info.plist' -d "$tmp" 2>/dev/null &&
        staged=$(plist_build "$tmp/Payload/Madeira.app/Info.plist")
    rm -rf "$tmp"
fi
[ -n "$staged" ] || fail "no staged IPA at ${IPA#"$ROOT"/} (build one: tools/build-ipa.sh)"

tmp=$(mktemp -d)
"$IOSDEV" app-get "$LC_APPS/$BUNDLE/Info.plist" "$tmp/inst.plist" >/dev/null 2>&1 ||
    fail "cannot read the installed bundle -- is the device connected and unlocked?"
installed=$(plist_build "$tmp/inst.plist")
rm -rf "$tmp"
[ -n "$installed" ] || fail "installed Info.plist has no version keys"

last=""
names=$(mktemp)
"$IOSDEV" app-ls "$LC_DATA/Documents/logs" 2>/dev/null |
    awk '/forzahorizon6\.exe-/ { print $1 }' | sort | tail -1 > "$names" 2>/dev/null || true
lastfile=$(cat "$names" 2>/dev/null)
rm -f "$names"
if [ -n "$lastfile" ]; then
    logtmp=$(mktemp)
    if "$IOSDEV" app-get "$LC_DATA/Documents/logs/$lastfile" "$logtmp" >/dev/null 2>&1; then
        stamp=$(grep -am1 '\[build\] v' "$logtmp" 2>/dev/null | sed 's/.*\[build\] //')
        status=$(grep -am1 'exit-report' "$logtmp" 2>/dev/null | sed 's/.*exit-report //')
        last="${lastfile#forzahorizon6.exe-}  ${stamp:-build ?}"
        [ -n "$status" ] && last="$last  ($status)"
    fi
    rm -f "$logtmp"
fi

say "staged     v${staged}"
say "installed  v${installed}"
say "last run   ${last:-no forzahorizon6 session log yet}"
# The IPAS folder under On My iPhone is the Files app's local file provider, which
# neither devicectl nor AFC can read, so its contents can only be checked on screen.
say "ipas       not host-readable (local file provider) -- verify on the device"

if [ "$staged" = "$installed" ]; then
    [ "$QUIET" = 1 ] && echo "installed v$installed: launch Forza" || say "verdict    INSTALLED -- launch Forza Horizon 6"
    exit 0
fi
[ "$QUIET" = 1 ] && echo "install needed: staged v$staged, installed v$installed" ||
    say "verdict    INSTALL NEEDED -- v${staged} is staged, v${installed} is installed"
exit 1
