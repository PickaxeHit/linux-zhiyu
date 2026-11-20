#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$base/.." && pwd)
: "${MINK_SRC:?Set MINK_SRC to a minkipc source tree with generated CBO IDL headers}"
: "${MINK_LIB:?Set MINK_LIB to its libminkadaptor directory}"
cc=${CC:-${CROSS_COMPILE:-}gcc}
flags=(-O2 -Wall -Wextra -pthread -I"$MINK_SRC/libminkadaptor/include" -I"$MINK_SRC/listeners/listenercbo/idl" -I"$MINK_SRC/listeners/listenercbo/include")
crypto=${KEYMINT_DEPS:-$base/.deps}/crypto
openssl_rev=$(python3 "$root/scripts/deps.py" rev openssl)
[ "$(cat "$crypto/.openssl-rev" 2>/dev/null)" = "$openssl_rev" ] &&
 [ -f "$crypto/usr/lib/aarch64-linux-gnu/libcrypto.a" ] ||
 { echo 'Run build-crypto.sh first (or it is out of date)' >&2; exit 1; }
flags+=(-static -ffunction-sections -fdata-sections -Wl,--gc-sections)
link=("$MINK_LIB/libminkadaptor.a" "$MINK_LIB/libqcomtee.a" "$MINK_LIB/libqcbor.a")
bin=${KEYMINT_BIN:-$base/bin}
mkdir -p "$bin"
"$cc" "${flags[@]}" -Wno-deprecated-declarations -I"$crypto/usr/include" "$base/unlock_metadata.c" "${link[@]}" "$crypto/usr/lib/aarch64-linux-gnu/libcrypto.a" -o "$bin/unlock_metadata"
"$cc" "${flags[@]}" "$base/rpmb_proxy.c" "$MINK_SRC/listeners/listenercbo/src/CListenerCBO.c" "${link[@]}" -o "$bin/rpmb_proxy"
"$cc" "${flags[@]}" "$base/time_main.c" "$MINK_SRC/listeners/libtimeservice/atime.c" "$MINK_SRC/listeners/listenercbo/src/CListenerCBO.c" "${link[@]}" -o "$bin/time_listener"
# Remove stale dynamic output from earlier builds.
rm -f "$bin/libminkadaptor.so.1"
"$cc" -static -Os -Wall -Wextra "$base/../initramfs-src/src/userdata-map.c" -o "$bin/userdata-map"
