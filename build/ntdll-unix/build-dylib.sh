#!/bin/bash
# Link the Wine unix half as a loadable dylib instead of the static archive.
#
#   build/ntdll-unix/build-dylib.sh   -> build/ntdll-unix/libntdll_unix.dylib
#
# Why a dylib and not the archive. The unix half is reached through a function-pointer
# table that the PE ntdll owns (`__wine_unixlib_handle`), but the table is installed by
# `load_ntdll_functions` inside the unix half itself, while `__wine_main` bootstraps. An
# app-side `dlopen` that writes the table earlier is therefore overwritten. The only
# coherent arrangement is for the whole half to come from one image: this dylib defines
# the table, and its own `__wine_main` installs it. Nothing overwrites anything, because
# there is only one copy of the half running.
#
# The objects are the ones build.sh already compiled, so this cannot drift from the
# archive: same sources, same flags, different container.
#
# `-undefined dynamic_lookup` is deliberate. The unix half calls into the app (logging,
# config, the PE ntdll's Nt* entry points) and those symbols only exist in the main
# executable. An archive gets them at link time because it is linked into the app; a
# dylib gets them at load time, by name, from the same process. That is the same set of
# symbols -- it is not a new contract -- and it keeps this script from having to restate
# the app's entire linker line.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$BUILD_DIR/../.." && pwd)"
ROOT_APP="$REPO_ROOT/app/Madeira"
OBJ_DIR="$BUILD_DIR/obj"
OUT="$BUILD_DIR/libntdll_unix.dylib"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)

# Only these are meant to be resolvable from outside. Everything else stays private to
# the image, so the dylib cannot accidentally interpose on the app or on the archive
# copy that is still linked as a fallback.
EXPORTS="$(mktemp)"
trap 'rm -f "$EXPORTS"' EXIT
cat > "$EXPORTS" <<'LIST'
_madeira_unix_half_main
_madeira_unix_half_log_set_file
_madeira_unix_half_main_i386_addr
_madeira_unix_half_live_game_children
_madeira_unix_half_winios_drv_census_owner
_madeira_unix_half_winios_drv_process_image
_madeira_unix_half_winios_drv_post_restore
_madeira_unix_half_winios_drv_foreground_if_owner
_madeira_unix_half_winios_drv_close_desktop_if_owner
_madeira_unix_half_winios_drv_post_mouse
_madeira_unix_half_winios_drv_post_key
_madeira_unix_half_winios_drv_post_text
_madeira_unix_half_winios_drv_size_game_window
_madeira_unix_half_winios_dump_window_tree
_madeira_unix_half_ios_dump_all_thread_stacks
_madeira_unix_half_wineserver_main
_madeira_unix_half_wineserver_log_set_file
_madeira_unix_half_wineserver_set_nls_dir
_madeira_unix_half_wineserver_inject_client_fd
_madeira_unix_half_wineserver_foreground_addr
_madeira_unix_half_wineserver_ready_addr
_madeira_unix_half_wineserver_log_quiet_addr
_madeira_unix_half_wineserver_set_ui_log_callback
LIST

# The archive's object list, in the same order build.sh passes it.
OBJECTS=(
    audio_null_ios madsync nsi_unixlib_ios
    nsi_network_ios nsi_ndis nsi_ip
    gnutls_symtab_ios ws2_32_unixlib
    bcrypt_unixlib secur32_unixlib crypt32_unixlib
    dwrite_unixlib dnsapi_unixlib opengl32_wgl opengl32_thunks
    winevulkan_vulkan winevulkan_thunks
    winegstreamer_unixlib wg_parser_apple_ios
    cdrom debug env file
    loader loadorder process registry
    security serial server
    signal_arm signal_arm64 signal_i386 signal_x86_64
    socket sync syscall system
    tape thread virtual
)

ARGS=()
MISSING=()
for name in "${OBJECTS[@]}"; do
    if [ -f "$OBJ_DIR/$name.o" ]; then
        ARGS+=("$OBJ_DIR/$name.o")
    else
        MISSING+=("$name")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "missing objects: ${MISSING[*]}" >&2
    echo "run build/ntdll-unix/build.sh first" >&2
    exit 1
fi

# The one default-visible object in the image; see unixhalf_entry.c for why the half
# itself cannot export anything (it is compiled with -fvisibility=hidden).
echo "=== Compiling the entry surface ==="
xcrun -sdk iphoneos clang \
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
    -O2 -fPIC \
    -c "$BUILD_DIR/unixhalf_entry.c" -o "$OBJ_DIR/unixhalf_entry.o"
ARGS+=("$OBJ_DIR/unixhalf_entry.o")

echo "=== Linking $OUT from ${#ARGS[@]} objects ==="
# Static libraries the half references and the app does not export.
#
# These are hidden inside Madeira.debug.dylib (`nm` shows them as local), so no dylib can
# resolve them by name -- `-undefined dynamic_lookup` fails with "symbol not found in flat
# namespace". They are also genuinely part of this half, not app services:
#
#   libav*/libswresample  winegstreamer and the AV parsers, which live in this object list
#   libwin32u_unix        win32u's unixlib init, which the ntdll loader brings up
#   libwineserver         in-process wineserver (shares madsync, madeira_sync_cells,
#                         ios_srv_direct_call, ios_wineserver_ring, ios_eco_gen, etc.)
#
# Linking them here makes the image self-contained for all three. The app keeps its own
# copies for the archive fallback; only one half runs, so none is initialised twice.
EXTRA_LIBS=(
    "$ROOT_APP/libavformat.a" "$ROOT_APP/libavcodec.a"
    "$ROOT_APP/libavutil.a" "$ROOT_APP/libswresample.a"
    "$ROOT_APP/libwin32u_unix.a"
    "$ROOT_APP/libwineserver.a"
    "$ROOT_APP/libgnutls.a" "$ROOT_APP/libhogweed.a"
    "$ROOT_APP/libnettle.a" "$ROOT_APP/libgmp.a"
)
for lib in "${EXTRA_LIBS[@]}"; do
    [ -f "$lib" ] || { echo "missing static library: $lib" >&2; exit 1; }
done

xcrun -sdk iphoneos clang \
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 \
    -dynamiclib -o "$OUT" \
    -Wl,-install_name,@rpath/libntdll_unix.dylib \
    -Wl,-undefined,dynamic_lookup \
    -Wl,-exported_symbols_list,"$EXPORTS" \
    "${ARGS[@]}" "${EXTRA_LIBS[@]}"

chmod 755 "$OUT"

echo "=== Verifying the entry points are exported and nothing else is ==="
EXPORTED=$(nm -gU "$OUT" | awk '{print $3}' | sort)
for want in _madeira_unix_half_main _madeira_unix_half_log_set_file _madeira_unix_half_main_i386_addr _madeira_unix_half_wineserver_main; do
    if ! printf '%s\n' "$EXPORTED" | grep -qx "$want"; then
        echo "ERROR: $want is not exported from the dylib" >&2
        echo "exported symbols:" >&2
        printf '%s\n' "$EXPORTED" | sed 's/^/  /' >&2
        exit 1
    fi
done
echo "  $(printf '%s\n' "$EXPORTED" | wc -l | tr -d ' ') exported symbol(s):"
printf '%s\n' "$EXPORTED" | sed 's/^/    /'

echo "=== Host symbols this image expects (must exist in the app) ==="
# The coupling between this dylib and the app: every symbol here resolves at load time by
# name, so anything third-party must have been linked in above instead of being left to
# the host. This check exists because the first build of this dylib loaded on device and
# then failed with `symbol not found in flat namespace '_av_channel_layout_compare'`: the
# FFmpeg symbols are *local* inside Madeira.debug.dylib, so "the app has it" was true in
# `nm` output and false for the dynamic linker.
HOST_SYMS=$(nm -u "$OUT" | awk '{print $1}' | grep -E '^_(Nt|wine_|madeira_|ios_|__wine)' | sort -u)
if [ -n "$HOST_SYMS" ]; then printf '%s\n' "$HOST_SYMS" | sed 's/^/    /'; fi

echo "=== Checking nothing third-party was left to the host ==="
# Prefixes that belong to libraries this half must carry itself. If one shows up
# undefined, it will fail at load time on device, so fail here instead.
LEAKED=$(nm -u "$OUT" | awk '{print $1}' \
    | grep -E '^_(av|avcodec|avformat|avio|swr|win32u|gnutls|gcry|nettle|hogweed|gmp|vulkan|Z)' \
    | sort -u || true)
if [ -n "$LEAKED" ]; then
    echo "ERROR: these must be linked into the dylib, not resolved from the app:" >&2
    printf '%s\n' "$LEAKED" | sed 's/^/    /' >&2
    exit 1
fi
echo "    none"

echo "dylib: $(wc -c < "$OUT" | tr -d ' ') bytes"
