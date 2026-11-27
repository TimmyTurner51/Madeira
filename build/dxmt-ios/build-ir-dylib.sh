#!/bin/bash
# Link madeira-d3d12's unix shader-converter service as a standalone loadable dylib
# so DXIL/SM5 -> Metal IR conversion fixes can ship in a native .wcp without rebuilding
# Madeira.app.
#
#   build/dxmt-ios/build-ir-dylib.sh -> build/dxmt-ios/libmadeira_ir_unix.dylib
#
# Loaded on first shader conversion by dxmt/src/winemetal/unix/winemetal_unix.c
# (_madeira_ir_convert -> madeira_wcp_dylib_path("libmadeira_ir_unix.dylib")).
# Package with tools/wcp/make-native-wcp.sh.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
OBJ_DIR="$BUILD_DIR/obj"
OUT="$BUILD_DIR/libmadeira_ir_unix.dylib"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

OBJECTS=(
    madeira_ir_unix
    madeira_sm5_ia
    madeira_ags
    madeira_sc_pack
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
    echo "run build/dxmt-ios/build.sh first" >&2
    exit 1
fi

EXPORTS="$(mktemp)"
trap 'rm -f "$EXPORTS"' EXIT
cat > "$EXPORTS" <<'LIST'
_madeira_ir_convert
LIST

echo "=== Linking $OUT from ${#ARGS[@]} objects ==="
xcrun -sdk iphoneos clang++ \
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=18.0 \
    -dynamiclib -o "$OUT" \
    -Wl,-install_name,@rpath/libmadeira_ir_unix.dylib \
    -Wl,-undefined,dynamic_lookup \
    -Wl,-exported_symbols_list,"$EXPORTS" \
    -framework Foundation \
    "${ARGS[@]}"

chmod 755 "$OUT"

echo "=== Verifying exported surface ==="
EXPORTED=$(nm -gU "$OUT" | awk '{print $3}' | sort)
if [ "$EXPORTED" != "_madeira_ir_convert" ]; then
    echo "ERROR: expected only _madeira_ir_convert exported, got:" >&2
    printf '%s\n' "$EXPORTED" | sed 's/^/  /' >&2
    exit 1
fi
echo "  1 exported symbol: _madeira_ir_convert"
echo "dylib: $(wc -c < "$OUT" | tr -d ' ') bytes"
