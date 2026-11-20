#!/bin/bash
# Compile, never load, a tiny out-of-tree module using packaged headers and
# native target distro GCC. Keep the shared staging tree untouched.
set -euo pipefail
cd "$(dirname "$0")/.."
ver=$(cat out/kernel-release)
headers="$PWD/stage/linux-zhiyu-headers/usr/src/linux-headers-$ver"
python3 scripts/verify-header-tools.py "$headers"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -a "$headers" "$tmp/headers"
mkdir "$tmp/module"
cat > "$tmp/module/Makefile" <<'EOF'
obj-m := zhiyu_header_test.o
EOF
cat > "$tmp/module/zhiyu_header_test.c" <<'EOF'
#include <linux/module.h>
#include <linux/init.h>
static int __init zhiyu_test_init(void) { return 0; }
static void __exit zhiyu_test_exit(void) {}
module_init(zhiyu_test_init);
module_exit(zhiyu_test_exit);
MODULE_LICENSE("GPL");
EOF
make -C "$tmp/headers" ARCH=arm64 CROSS_COMPILE= CC=gcc M="$tmp/module" -j"${JOBS:-1}" modules
python3 - "$tmp/module/zhiyu_header_test.ko" "$ver" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); elf=p.read_bytes()
assert elf[:6]==b'\x7fELF\x02\x01' and int.from_bytes(elf[18:20],'little')==183, 'Wrong module ELF architecture'
assert b'vermagic='+sys.argv[2].encode()+b' ' in elf, 'Wrong kernel release in vermagic'
PY
printf '%s\n' "External-module smoke test passed ($DISTRO, $ver)"
