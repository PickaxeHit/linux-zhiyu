#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")" && pwd)
: "${MINK_SRC:?Set MINK_SRC to a minkipc source tree with generated CBO IDL headers}"
: "${MINK_LIB:?Set MINK_LIB to its libminkadaptor directory}"
cc=${CC:-${CROSS_COMPILE:-}gcc}
flags=(-O2 -Wall -Wextra -pthread -I"$MINK_SRC/libminkadaptor/include" -I"$MINK_SRC/listeners/listenercbo/idl" -I"$MINK_SRC/listeners/listenercbo/include")
crypto=${KEYMINT_DEPS:-$base/.deps}/crypto
cmp -s "$base/static-packages.tsv" "$crypto/.verified" && [ -f "$crypto/usr/lib/aarch64-linux-gnu/libcrypto.a" ] || { echo 'Run build-crypto.sh first' >&2; exit 1; }
flags+=(-static -ffunction-sections -fdata-sections -Wl,--gc-sections)
link=("$MINK_LIB/libminkadaptor.a" "$MINK_LIB/libqcomtee.a" "$MINK_LIB/libqcbor.a")
mkdir -p "$base/bin"
"$cc" "${flags[@]}" -Wno-deprecated-declarations -I"$crypto/usr/include" -I"$crypto/usr/include/aarch64-linux-gnu" "$base/unlock_metadata.c" "${link[@]}" "$crypto/usr/lib/aarch64-linux-gnu/libcrypto.a" -o "$base/bin/unlock_metadata"
"$cc" "${flags[@]}" "$base/rpmb_readonly.c" "$MINK_SRC/listeners/listenercbo/src/CListenerCBO.c" "${link[@]}" -o "$base/bin/rpmb_readonly"
"$cc" "${flags[@]}" "$base/time_main.c" "$MINK_SRC/listeners/libtimeservice/atime.c" "$MINK_SRC/listeners/listenercbo/src/CListenerCBO.c" "${link[@]}" -o "$base/bin/time_listener"
# Remove stale dynamic output from earlier builds.
rm -f "$base/bin/libminkadaptor.so.1"
"$cc" -static -Os -Wall -Wextra "$base/../initramfs-src/src/userdata-map.c" -o "$base/bin/userdata-map"
