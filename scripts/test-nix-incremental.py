#!/usr/bin/env python3
"""Evaluate the impact of independent BSP changes without rebuilding them."""
import json
from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
ATTRIBUTES = [
    "kernel", "dtb", "firmware", "topology", "initramfs", "keymint", "libcamera-0_7",
    "libcamera-0_8", "sensord", "sensh", "zhiyu-boot", "zhiyu-init-boot",
    "zhiyu-vendor-boot", "zhiyu-vbmeta", "zhiyu-images",
]
VENDOR = {"zhiyu-vendor-boot", "zhiyu-vbmeta", "zhiyu-images"}


def evaluate(tree):
    expr = f"""
      let
        flake = builtins.getFlake {json.dumps("path:" + str(tree))};
        packages = flake.packages.aarch64-linux;
      in builtins.listToAttrs (map (name: {{ inherit name; value = packages.${{name}}.drvPath; }})
        (builtins.fromJSON {json.dumps(json.dumps(ATTRIBUTES))}))
    """
    return json.loads(subprocess.check_output(["nix", "eval", "--impure", "--json", "--expr", expr]))


def test(tree, path, mutation, expected):
    file = tree / path
    before = file.read_text()
    baseline = evaluate(tree)
    file.write_text(mutation(before))
    try:
        modified = evaluate(tree)
        actual = {attr for attr in ATTRIBUTES if baseline[attr] != modified[attr]}
        assert actual == expected, f"{path}: expected {sorted(expected)}, got {sorted(actual)}"
        print(f"{path}: {', '.join(sorted(actual))}")
    finally:
        file.write_text(before)


with TemporaryDirectory(prefix="zhiyu-incremental-") as temp:
    tree = Path(temp)
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
    for entry in (entry.decode() for entry in tracked if entry):
        path = ROOT / entry
        if path.is_file():
            (tree / entry).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, tree / entry)
    test(tree, "dts/lenovo-zhiyu.dts", lambda s: s + "\n/* DTS change */\n", VENDOR | {"dtb"})
    test(tree, "sensors/sensord.c", lambda s: s + "\n/* daemon change */\n", {"sensord"})
    test(tree, "nix/hardware.nix",
         lambda s: s.replace('cp -a ${raw}/firmware/. "$out/lib/firmware/"',
                             'cp -a ${raw}/firmware/. "$out/lib/firmware/"\n    touch "$out/firmware-change"'),
         VENDOR | {"firmware", "initramfs"})
