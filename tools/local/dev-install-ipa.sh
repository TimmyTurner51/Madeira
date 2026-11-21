#!/bin/bash
# Reinstall a Madeira IPA into LiveContainer, REPLACING the existing install.
# This is the only channel that produces a loadable debug dylib.
#
# Why this channel is required
# ---------------------------
# LiveContainer re-signs the whole app at install, nested code included. The
# installed Madeira.debug.dylib carries LiveContainer's own signature
# (Identifier=com.kdt.livecontainer.4CDWTGR84Z, TeamIdentifier=4CDWTGR84Z).
# Copying a dylib in with `iosdev app-put` destroys that signature, and nothing
# the Mac can produce is accepted in its place:
#   * unsigned          -> "missing code signature"
#   * codesign ad-hoc   -> "code signature invalid"
#   * ldid ad-hoc       -> "code signature invalid"
# ldid cannot override Identifier/TeamIdentifier (both derive from
# LiveContainer's provisioning profile), so the signature cannot be reproduced
# off-device. A dylib swap is therefore NOT a deploy path on this setup; the
# fast channel is rebuilding the dylib, packaging an IPA and installing it here.
#
# Why replacement is mandatory
# ---------------------------
# On a duplicate bundle identifier LiveContainer offers three rows:
#   "Install as new"      -> a SECOND container: the existing prefix (drive_c,
#                           installed games, config) is orphaned. Never choose it.
#   "com.willfaust....app" -> replaces the bundle in place, keeping its container.
#   "Abort Installation"
# This script only ever taps the app row, and aborts rather than guessing.
#
# Two iOS Files picker quirks this handles (both cost real debugging time):
#   * Tapping a file's LABEL does nothing. The file must be opened by tapping its
#     ICON, which sits ~94 px above the label.
#   * The unzip blocks for a while before the duplicate prompt appears, so the
#     prompt must be waited for, not probed once.
#
# Usage
#   tools/local/dev-install-ipa.sh                     # install Documents/Madeira.ipa
#   tools/local/dev-install-ipa.sh Madeira-b37.ipa     # install a named on-device IPA
#   tools/local/dev-install-ipa.sh --push FILE         # copy FILE in first, then install
set -u
export PATH="$HOME/bin:$PATH"
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DFILE="$REPO_ROOT/tools/local/device-file.sh"

# A preflight that costs seconds and prevents a silent half-hour stall. On
# 2026-11-21 this script ran 23 minutes and exited 0 having uploaded the IPA and
# installed nothing: the USB link had dropped, `iosdev app-put` wedged with no
# timeout, and `installed_version` (delegating to devicectl's app container) hung
# too, so the failure looked like a slow install. `usbmux list` answers in about a
# second and is empty exactly when no run is possible, so gate on it.
preflight() {
    local pmd3="${IOSDEV_PMD3:-$HOME/.local/bin/pymobiledevice3}"
    local json
    json="$("$pmd3" usbmux list 2>/dev/null)"
    # Parse rather than pattern-match: an unset path or a transient error makes
    # `usbmux list` print [] or nothing, and a grep for a key would then be false
    # both ways (an unbound variable with `set -u` aborted even when a phone WAS
    # connected). Only a parsed, non-empty device entry means a run is possible.
    if ! printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if isinstance(d, list) and len(d) > 0 else 1)
' 2>/dev/null; then
        echo "ABORT: the device is not on the bus (pymobiledevice3 usbmux list is empty)." >&2
        echo "       Nothing can be uploaded or installed, so this run would only burn time." >&2
        echo "       Reconnect the phone (and unlock it), then re-run." >&2
        exit 2
    fi
}

# Upload through device-file.sh, which bounds every route and falls back to the
# pmd3 app-container service when devicectl wedges. `iosdev app-put` is unbounded
# and was the actual cause of the 23-minute no-op above; a transfer that cannot be
# proven should fail here rather than 20 minutes later.
upload() {   # upload <local> <container-relative-remote>
    DEVICE_FILE_ROUTE="${DEVICE_FILE_ROUTE:-auto}" DEVICE_FILE_TIMEOUT="${DEVICE_FILE_TIMEOUT:-300}" \
        "$DFILE" put "$1" "$2"
}

LC_BUNDLE="com.kdt.livecontainer.4CDWTGR84Z"
APP_ID="com.willfaust.madeora"
BUNDLE_REMOTE="Documents/Applications/com.willfaust.madeora.app"
IPA_NAME="Madeira.ipa"
REMOTE_DIR="Documents"
ICON_OFFSET=94   # px from a file's label up to its icon
# Set when this run installs the .ipa it was asked to install. The default form
# installs whatever Documents/Madeira.ipa already holds on the phone, which is
# stale often enough to be worth guarding (see the verification step).
INSTALLING_INTENDED=0

if [ "${1:-}" = "--push" ]; then
    [ -f "${2:-}" ] || { echo "--push needs a local .ipa" >&2; exit 1; }
    IPA_NAME=$(basename "$2")
    INTENDED_IPA="$2"
    INSTALLING_INTENDED=1
    preflight
    echo "==> uploading $2 ($(stat -f %z "$2") bytes)"
    # AFC (device-file.sh's pmd3 route) is used rather than iosdev push: push goes
    # over usbmux, which disappears whenever the USB link drops, while the RSD
    # tunnel stays up. Bounded, so a wedge is an error instead of a silent stall.
    upload "$2" "$REMOTE_DIR/$IPA_NAME" >/dev/null || exit 1
elif [ "${1:-}" = "--from-app" ]; then
    # Fast loop for app-side (Swift/ObjC/unix) changes: zip the already-built
    # product instead of re-running xcodebuild + the runtime component verify.
    # The app's bundled *-windows DLLs are whatever that build carried, so a PE
    # change still needs tools/build/package-ipa.sh.
    APP="app/DerivedData/Build/Products/Debug-iphoneos/Madeira.app"
    [ -d "$APP" ] || { echo "ABORT: $APP not built" >&2; exit 1; }
    preflight
    ver=$(plutil -extract CFBundleVersion raw "$APP/Info.plist" 2>/dev/null)
    echo "==> packaging $APP (build $ver) without the component verify"
    rm -rf /tmp/devipa && mkdir -p /tmp/devipa/Payload
    ditto "$APP" /tmp/devipa/Payload/Madeira.app || exit 1
    (cd /tmp/devipa && zip -qry Madeira.ipa Payload) || exit 1
    # A short remote name on purpose: iOS Files wraps long labels across lines,
    # so OCR renders "Madeira-app-37.ipa" as two rows and an exact-name match
    # silently fails. "dev.ipa" is always one row. The build number is printed
    # here instead, read from the app being packaged.
    IPA_NAME="dev.ipa"
    echo "==> uploading /tmp/devipa/Madeira.ipa -> $REMOTE_DIR/$IPA_NAME (build $ver)"
    upload /tmp/devipa/Madeira.ipa "$REMOTE_DIR/$IPA_NAME" >/dev/null || exit 1
elif [ -n "${1:-}" ]; then
    IPA_NAME="$1"
fi

# Read CFBundleVersion currently installed on the device (empty if unreadable).
installed_version() {
    local tmp v
    tmp=$(mktemp -d)
    iosdev app-get "$BUNDLE_REMOTE/Info.plist" "$tmp/p" >/dev/null 2>&1
    v=$(plutil -extract CFBundleVersion raw "$tmp/p" 2>/dev/null)
    rm -rf "$tmp"
    printf '%s' "$v"
}

version_of_ipa() {
    unzip -p "$1" Payload/Madeira.app/Info.plist 2>/dev/null | plutil -extract CFBundleVersion raw - 2>/dev/null
}

before=$(installed_version)
echo "==> installed build before: ${before:-unknown}"

iosdev launch "$LC_BUNDLE" >/dev/null 2>&1
sleep 7

# A leftover launch-error modal blocks the list; clear it before interacting.
if iosdev see 2>/dev/null | grep -qiE 'missing code signature|code signature invalid'; then
    echo "==> clearing a stale launch error dialog"
    iosdev tap 1072 301 >/dev/null 2>&1
    sleep 2
fi

echo "==> opening import menu"
iosdev tap 116 257 >/dev/null 2>&1
sleep 3
if ! iosdev see 2>/dev/null | grep -q 'Install IPA File'; then
    echo "ABORT: import menu did not open (no 'Install IPA File')." >&2
    iosdev see 2>/dev/null | head -8 >&2
    exit 1
fi
iosdev tap-text "Install IPA File" >/dev/null 2>&1
sleep 5

# Locate the file's label, then tap its icon (the label itself is inert).
line=$(iosdev see 2>/dev/null | grep -E "  ${IPA_NAME}\$" | head -1)
if [ -z "$line" ]; then
    echo "ABORT: '$IPA_NAME' not visible in the file picker." >&2
    iosdev see 2>/dev/null | head -14 >&2
    exit 1
fi
lx=$(printf '%s' "$line" | awk '{print $1}' | tr -d ',')
ly=$(printf '%s' "$line" | awk '{print $2}' | tr -d ',')
iy=$((ly - ICON_OFFSET))
echo "==> selecting $IPA_NAME (icon at $lx,$iy)"
iosdev tap "$lx" "$iy" >/dev/null 2>&1

# Wait for the duplicate prompt; the unzip can take a couple of minutes.
prompt=""
for i in $(seq 1 60); do
    sleep 3
    see=$(iosdev see 2>/dev/null)
    if printf '%s\n' "$see" | grep -q 'Install as new'; then prompt="$see"; break; fi
done

if [ -z "$prompt" ]; then
    echo "ABORT: duplicate-install prompt never appeared." >&2
    iosdev see 2>/dev/null | head -12 >&2
    exit 1
fi

echo "==> duplicate bundle id: replacing in place (NOT 'Install as new')"
oy=$(printf '%s\n' "$prompt" | grep -F "$APP_ID" | head -1 | awk '{print $2}' | tr -d ',')
if [ -z "$oy" ]; then
    echo "ABORT: no row for $APP_ID; refusing to guess." >&2
    exit 1
fi
# The row we are about to tap must not be the "as new" option.
if printf '%s\n' "$prompt" | grep -E "^ *[0-9]+, *${oy} " | grep -q 'Install as new'; then
    echo "ABORT: '$APP_ID' row resolves to 'Install as new'." >&2
    exit 1
fi
echo "    replacing via row '$APP_ID' at y=$oy"
iosdev tap 605 "$oy" >/dev/null 2>&1

# Wait until the prompt is gone and the list is interactive again.
for i in $(seq 1 80); do
    sleep 3
    iosdev see 2>/dev/null | grep -q 'Install as new' || break
done

echo "==> verifying the installed bundle"
tmp=$(mktemp -d)
iosdev app-get "$BUNDLE_REMOTE/Madeira.debug.dylib" "$tmp/d" >/dev/null 2>&1
after=$(installed_version)
# Did we actually install the thing we meant to? The default form installs
# Documents/Madeira.ipa from the phone, which is whatever was pushed last,
# NOT the freshly packaged dist/Madeira.ipa. A run that silently installs an
# older build looks exactly like a successful install (it reports a build
# number, the signature is fine, the app launches), so say so loudly here.
want=""
if [ -n "${INTENDED_IPA:-}" ] && [ -f "$INTENDED_IPA" ]; then
    want=$(version_of_ipa "$INTENDED_IPA")
    why="the IPA passed to --push"
elif [ -f "$REPO_ROOT/dist/Madeira.ipa" ]; then
    want=$(version_of_ipa "$REPO_ROOT/dist/Madeira.ipa")
    why="dist/Madeira.ipa on this Mac"
fi
if [ -z "${INTENDED_IPA:-}" ] && [ -n "$want" ] && [ "$after" != "$want" ]; then
    echo "    WARNING: this run installed Documents/$IPA_NAME from the phone, not ${why}." >&2
    echo "             installed build $after != $want. Use --push $REPO_ROOT/dist/Madeira.ipa" >&2
    echo "             to install what you just built. Verify with the runtime [build] line:" >&2
    echo "             a stale install still reports a build number and a valid signature." >&2
elif [ -n "$want" ] && [ "$after" != "$want" ]; then
    echo "    WARNING: installed build $after != $want (${why})." >&2
fi
if [ -s "$tmp/d" ]; then
    ident=$(codesign -dv "$tmp/d" 2>&1 | sed -n 's/^Identifier=//p')
    team=$(codesign -dv "$tmp/d" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    echo "    installed build : $after  $([ "$after" = "$before" ] && echo '(unchanged)')"
    echo "    dylib signature : $ident / $team"
    if [ "$ident" = "$LC_BUNDLE" ] && [ "$team" = "4CDWTGR84Z" ]; then
        echo "    OK: LiveContainer signature present; this copy will load."
    else
        echo "    WARNING: signature is not LiveContainer's; it will not load." >&2
    fi
else
    echo "    WARNING: could not read the installed dylib." >&2
fi
rm -rf "$tmp"
