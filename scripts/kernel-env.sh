# Source from the repository root. All paths are absolute; Kbuild output is separate.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export KS=$(realpath "${KS:-$root/kernel-source}")
export KBUILD_DIR=$(realpath -m "${KBUILD_DIR:-$root/out/kernel}")
export JOBS=${JOBS:-$(nproc)}
export CROSS_COMPILE=${CROSS_COMPILE-$(if [[ $(uname -m) != aarch64 ]]; then printf aarch64-linux-gnu-; fi)}
export CC_AARCH64=${CC_AARCH64:-${CROSS_COMPILE}gcc}
[[ -f "$KS/Makefile" ]] || { echo 'Initialize kernel-source: git submodule update --init kernel-source' >&2; return 1; }
KVER=${KVER:-$(make -s -C "$KS" ARCH=arm64 kernelversion)}
SERIES=${SERIES:-$(cut -d. -f1,2 <<< "$KVER")}
export CFG=$(realpath "${CFG:-$root/configs/linux-$SERIES-zhiyu.config}")
[[ -f "$CFG" ]] || { echo "Missing config: $CFG" >&2; return 1; }
[[ "$KBUILD_DIR" != "$KS" ]] || { echo 'KBUILD_DIR must be separate from KS' >&2; return 1; }
# Optional compiler cache. Do not cache the actual source or Kbuild tree in CI.
kmake() {
    local cc="${CROSS_COMPILE}gcc"
    if [[ ${KERNEL_CCACHE:-0} == 1 ]]; then cc="ccache $cc"; fi
    make -C "$KS" O="$KBUILD_DIR" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CC="$cc" "$@"
}
kernel_id() {
    { git -C "$KS" rev-parse HEAD; git -C "$KS" diff HEAD --binary; git -C "$KS" ls-files --others --exclude-standard | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$KS/$f"; done; sha256sum "$CFG"; "${CROSS_COMPILE}gcc" --version; "$CC_AARCH64" --version; gcc --version; printf '%s\n' "$CROSS_COMPILE" "$KS"; } | sha256sum | cut -d' ' -f1
}
images_id() {
    { kernel_id; python3 "$root/scripts/image-inputs.py"; sha256sum "${KEY:-$root/avb-test-key.pem}"; } | sha256sum | cut -d' ' -f1
}
