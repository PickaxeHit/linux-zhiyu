#!/usr/bin/env bash
# Pinned, unmodified upstream libraries; IDL compiler runs on the build host.
set -euo pipefail
base=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$base/.." && pwd)
deps=${KEYMINT_DEPS:-$base/.deps}
prefix=$deps/prefix
cc=${CC:-${CROSS_COMPILE:-}gcc}
case $("$cc" -dumpmachine) in aarch64*) ;; *) echo 'Set CC or CROSS_COMPILE for ARM64' >&2; exit 1 ;; esac
mkdir -p "$deps"
deps=$(realpath "$deps")
prefix=$deps/prefix
rm -rf "$deps/prefix" "$deps/qcbor-build" "$deps/quic-build" "$deps/mink-build"
"$base/build-crypto.sh"

dep() { python3 "$root/scripts/deps.py" path "$1"; }
# These builds generate files in their source trees; use private copies.
copy_dep() {
    local src target
    src=$(dep "$1")
    target=$deps/src/$1
    rm -rf "$target"
    mkdir -p "$target"
    cp -a "$src/." "$target/"
    printf '%s\n' "$target"
}
qcbor=$(copy_dep qcbor)
quic_teec=$(copy_dep quic-teec)
minkipc=$(copy_dep minkipc)
idlc=$(copy_dep mink-idl-compiler)

cp "$base/idlc.Cargo.lock" "$idlc/Cargo.lock"
env -u CC -u CFLAGS -u CXXFLAGS cargo build --manifest-path "$idlc/Cargo.toml" --release --locked -p idlc
args=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_C_COMPILER="$cc"
 -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
cmake -S "$qcbor" -B "$deps/qcbor-build" "${args[@]}" -DBUILD_SHARED_LIBS=OFF
cmake --build "$deps/qcbor-build" -j"${JOBS:-4}"
cmake --install "$deps/qcbor-build"
cmake -S "$quic_teec" -B "$deps/quic-build" "${args[@]}" -DQCBOR_DIR_HINT="$prefix" -DBUILD_SHARED_LIBS=OFF
cmake --build "$deps/quic-build" -j"${JOBS:-4}"
cmake --install "$deps/quic-build"
cmake -S "$minkipc" -B "$deps/mink-build" "${args[@]}" \
 -DQCOMTEE_DIR_HINT="$prefix" -DQCBOR_DIR_HINT="$prefix" -DMINKIDLC_BIN_DIR="$idlc/target/release" \
 -DBUILD_MINKTEEC=OFF -DBUILD_PKCS11=OFF -DBUILD_RPMB_CLIENT=OFF -DBUILD_RPMB_LISTENER=OFF \
 -DBUILD_FS_LISTENER=OFF -DBUILD_GPFS_LISTENER=OFF -DBUILD_TA_AUTOLOAD_LISTENER=OFF -DBUILD_TIME_LISTENER=OFF
cmake --build "$deps/mink-build" -j"${JOBS:-4}"
cmake --install "$deps/mink-build"
# Upstream hardcodes SHARED. Reuse its three compiled objects in a static
# archive, without changing the pinned upstream source tree.
"${AR:-${CROSS_COMPILE:-}ar}" rcs "$prefix/lib/libminkadaptor.a" \
 "$deps/mink-build/libminkadaptor/CMakeFiles/minkadaptor.dir/src/supplicant.c.o" \
 "$deps/mink-build/libminkadaptor/CMakeFiles/minkadaptor.dir/src/mink_adaptor.c.o" \
 "$deps/mink-build/libminkadaptor/CMakeFiles/minkadaptor.dir/src/syscall.S.o"
CC="$cc" MINK_SRC="$minkipc" MINK_LIB="$prefix/lib" "$base/build.sh"
