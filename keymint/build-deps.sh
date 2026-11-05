#!/usr/bin/env bash
# Pinned, unmodified upstream libraries; IDL compiler runs on the build host.
set -euo pipefail
base=$(cd "$(dirname "$0")" && pwd)
deps=${KEYMINT_DEPS:-$base/.deps}
prefix=$deps/prefix
cc=${CC:-${CROSS_COMPILE:-}gcc}
case $("$cc" -dumpmachine) in aarch64*) ;; *) echo 'Set CC or CROSS_COMPILE for ARM64' >&2; exit 1 ;; esac
mkdir -p "$deps"
"$base/build-crypto.sh"
fetch() {
 local name=$1 url=$2 rev=$3
 if [ ! -d "$deps/$name/.git" ]; then
  git init -q "$deps/$name"
  git -C "$deps/$name" remote add origin "$url"
  git -C "$deps/$name" fetch --depth 1 origin "$rev"
  git -C "$deps/$name" checkout --detach FETCH_HEAD
 fi
 [ "$(git -C "$deps/$name" rev-parse HEAD)" = "$rev" ] || { echo "wrong revision: $name" >&2; exit 1; }
}
fetch qcbor https://github.com/laurencelundblade/QCBOR.git 572a567d02bcfde42f5863f6a515131cc270798d
fetch quic-teec https://github.com/quic/quic-teec.git 736419e25a2036aac3292a10a93e394a90750ca3
fetch minkipc https://github.com/quic/minkipc.git 5e3c6951d13162a262ea65ea8e8351228f092b58
fetch idlc https://github.com/quic/mink-idl-compiler.git 95ebb8d6031dd2c8d3f6277e50edadee8a119d5b
cp "$base/idlc.Cargo.lock" "$deps/idlc/Cargo.lock"
cargo build --manifest-path "$deps/idlc/Cargo.toml" --release --locked -p idlc
args=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_C_COMPILER="$cc"
 -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
cmake -S "$deps/qcbor" -B "$deps/qcbor-build" "${args[@]}" -DBUILD_SHARED_LIBS=OFF
cmake --build "$deps/qcbor-build" -j"${JOBS:-4}"
cmake --install "$deps/qcbor-build"
cmake -S "$deps/quic-teec" -B "$deps/quic-build" "${args[@]}" -DQCBOR_DIR_HINT="$prefix" -DBUILD_SHARED_LIBS=OFF
cmake --build "$deps/quic-build" -j"${JOBS:-4}"
cmake --install "$deps/quic-build"
cmake -S "$deps/minkipc" -B "$deps/mink-build" "${args[@]}" \
 -DQCOMTEE_DIR_HINT="$prefix" -DQCBOR_DIR_HINT="$prefix" -DMINKIDLC_BIN_DIR="$deps/idlc/target/release" \
 -DBUILD_MINKTEEC=OFF -DBUILD_PKCS11=OFF -DBUILD_RPMB_CLIENT=OFF -DBUILD_RPMB_LISTENER=OFF \
 -DBUILD_FS_LISTENER=OFF -DBUILD_GPFS_LISTENER=OFF -DBUILD_TA_AUTOLOAD_LISTENER=OFF -DBUILD_TIME_LISTENER=OFF
cmake --build "$deps/mink-build" -j"${JOBS:-4}"
cmake --install "$deps/mink-build"
# Upstream hardcodes SHARED. Reuse its three compiled objects in a static
# archive, without changing the pinned upstream source tree.
"${AR:-ar}" rcs "$prefix/lib/libminkadaptor.a" \
 "$deps/mink-build/libminkadaptor/CMakeFiles/minkadaptor.dir/src/supplicant.c.o" \
 "$deps/mink-build/libminkadaptor/CMakeFiles/minkadaptor.dir/src/mink_adaptor.c.o" \
 "$deps/mink-build/libminkadaptor/CMakeFiles/minkadaptor.dir/src/syscall.S.o"
CC="$cc" MINK_SRC="$deps/minkipc" MINK_LIB="$prefix/lib" "$base/build.sh"
