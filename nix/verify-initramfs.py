"""Verify the staged early userspace before packing it."""
from pathlib import Path
import os
import re
import subprocess
import sys


def output(*args):
    return subprocess.check_output(args, text=True, env=dict(os.environ, LC_ALL="C"))


def require(condition, message):
    if not condition:
        sys.exit(message)


root, release = Path(sys.argv[1]), sys.argv[2]
bin_dir = root / "bin"
require((root / "etc/zhiyu-strict-boot").is_file(), "Missing strict userdata boot policy")
applets = set(output(bin_dir / "busybox", "--list").splitlines())
required = {
    "busybox", "fsck.f2fs", "zhiyu-boot-select", "userdata-map", "keymint-recover",
    "keymint-rpmb", "keymint-time", "charger", "btaddr",
}
require(all((bin_dir / name).is_file() for name in required), "Missing early userspace tool")
for path in bin_dir.iterdir():
    if path.is_symlink():
        require(path.readlink() == Path("busybox") and path.name in applets, f"Invalid applet {path}")
        continue
    require(path.stat().st_mode & 0o777 == 0o755, f"Invalid executable mode: {path}")
    require("AArch64" in output("readelf", "-h", path), f"Invalid ELF architecture: {path}")
    require(not re.search(r"INTERP|NEEDED", output("readelf", "-l", "-d", path)), f"Dynamic ELF: {path}")
    require(not re.search(rb"/nix/store/[0-9a-z]{32}-", path.read_bytes()), f"Store reference in {path}")

for name in ("init", "libexec/metadata-root"):
    path = root / name
    require(path.stat().st_mode & 0o777 == 0o755, f"Invalid script mode: {path}")
    require(path.read_bytes().startswith(b"#!/bin/sh\n"), f"Invalid interpreter: {path}")

modules = root / "lib/modules" / release
order = [line.split("\t")[1] for line in (modules / "load-order").read_text().splitlines()]
require(len(order) == len(set(order)), "Duplicate modules in load order")
actual = {str(p.relative_to(modules)) for p in modules.rglob("*.ko")}
require(actual == set(order), "Load order does not cover every module")
indices = {p: i for i, p in enumerate(order)}
for line in (modules / "modules.dep").read_text().splitlines():
    module, dependencies = line.split(":", 1)
    require(all(indices[dep] < indices[module] for dep in dependencies.split()), f"Invalid load order: {module}")
for path in actual:
    vermagic = output("modinfo", "-F", "vermagic", modules / path).split()[0]
    require(vermagic == release, f"Module version mismatch: {path}")

require((root / "dev/pts").is_dir(), "Missing devtmpfs mount layout")
for path in root.rglob("*"):
    if path.is_symlink():
        require(not path.readlink().is_absolute() and path.resolve().is_relative_to(root.resolve())
                and path.exists(), f"Unsafe ramdisk symlink: {path}")
