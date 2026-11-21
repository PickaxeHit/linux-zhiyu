"""Exercise generation selection and a complete flash using private fixtures."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile


def run(*args, fails=False):
    proc = subprocess.run(args, text=True, capture_output=True)
    assert (proc.returncode != 0) == fails, proc.stdout + proc.stderr
    return proc.stdout


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def generation(root, name, ids):
    path = Path("/nix/store") / ("a" * 32 + "-nixos-system-" + name)
    actual = root / path.relative_to("/")
    write(actual / "etc/zhiyu/boot-id", ids)
    write(actual / "init", "#!/bin/sh\n")
    (actual / "init").chmod(0o755)
    return path, actual


def test_rescue(root, selector):
    init = root / "usr/lib/systemd/systemd"
    write(init, "#!/bin/sh\n")
    init.chmod(0o755)
    fhs = root / "sbin/init"
    fhs.parent.mkdir()
    fhs.symlink_to("/usr/lib/systemd/systemd")
    rescue = (selector, "--sd-rescue", root)
    assert run(*rescue).strip() == "/sbin/init"

    profiles = root / "nix/var/nix/profiles"
    profiles.mkdir(parents=True)
    current, current_path = generation(root, "rescue-current", "unused\n")
    fallback, _ = generation(root, "rescue-fallback", "unused\n")
    (profiles / "system").symlink_to("system-7-link")
    (profiles / "system-7-link").symlink_to(current)
    (profiles / "system-6-link").symlink_to(fallback)
    (current_path / "etc/zhiyu/boot-id").unlink()
    assert run(*rescue).strip() == "/sbin/init"

    init.chmod(0o644)
    assert run(*rescue).strip() == str(current / "init")
    (current_path / "init").unlink()
    assert run(*rescue).strip() == str(fallback / "init")

    cmdline = root / "cmdline"
    bootconfig = root / "bootconfig"
    write(cmdline, "zhiyu.kernel_id=" + "a" * 64 + "\n")
    write(bootconfig, 'zhiyu.vendor_id = "' + "b" * 64 + '"\n')
    run(selector, root, cmdline, bootconfig, fails=True)
    (profiles / "system-6-link").unlink()
    run(*rescue, fails=True)


def test(root, selector, flasher, production):
    ids = "a" * 64 + " " + "b" * 64 + "\n"
    kernel, vendor = ids.split()
    old_ids = "c" * 64 + " " + vendor + "\n"
    old, old_path = generation(root, "old", old_ids)
    previous, _ = generation(root, "previous", ids)
    new, actual = generation(root, "current", ids)
    pending, _ = generation(root, "pending", ids)

    profiles = root / "nix/var/nix/profiles"
    profiles.mkdir(parents=True)
    (profiles / "system-9-link").symlink_to(previous)
    (profiles / "system-10-link").symlink_to(new)
    (profiles / "system-11-link").symlink_to(old)
    (profiles / "system").symlink_to("system-11-link")
    (profiles / "zhiyu-boot").symlink_to(old)
    (profiles / "zhiyu-pending").symlink_to(pending)
    cmdline, bootconfig = root / "proc/cmdline", root / "proc/bootconfig"
    write(cmdline, f"zhiyu.kernel_id={kernel} androidboot.slot_suffix=_b\n")
    write(bootconfig, f'zhiyu.vendor_id = "{vendor}"\nandroidboot.slot_suffix = "_b"\n')
    command = (selector, root, cmdline, bootconfig)
    assert run(*command).strip() == str(pending / "init")
    (profiles / "zhiyu-pending").unlink()
    assert run(*command).strip() == str(new / "init")
    good = cmdline.read_text()
    write(cmdline, good.rstrip() + f" zhiyu.kernel_id={kernel}\n")
    run(*command, fails=True)
    write(cmdline, good.replace(kernel, "e" * 64))
    run(*command, fails=True)
    write(cmdline, good)

    (root / "proc/device-tree").mkdir()
    compatible = root / "proc/device-tree/lenovo,mainline-compatible"
    compatible.write_bytes(b"lenovo,zhiyu\0")
    (root / "run/lock").mkdir(parents=True)
    (root / "partitions").mkdir()
    images = actual / "etc/zhiyu/boot-images"
    write(images / "BOOT-IDS", ids)
    hashes, sizes = [], []
    parts = {"boot": 96 << 20, "vendor_boot": 96 << 20, "init_boot": 8 << 20, "vbmeta": 64 << 10}
    for part, size in parts.items():
        name = part + ".img"
        payload = hashlib.sha256()
        with (images / name).open("wb") as file:
            head = part.encode()
            file.write(head)
            file.truncate(size)
            payload.update(head)
            remaining = size - len(head)
            while remaining:
                chunk = bytes(min(remaining, 1 << 20))
                payload.update(chunk)
                remaining -= len(chunk)
        hashes.append(f"{payload.hexdigest()}  {name}")
        sizes.append(f"{size} {name}")
        for slot in ("a", "b"):
            with (root / "partitions" / f"{part}_{slot}").open("wb") as f:
                f.truncate(size)

    sums = images / "SHA256SUMS"
    write(sums, "\n".join(hashes))
    write(images / "SIZES", "\n".join(sizes))
    command = (flasher, "--simulate", root, actual)
    assert "unknown option" in subprocess.run(
        [production, "--simulate", root, actual], capture_output=True, text=True
    ).stderr
    assert run(*command, "--dry-run").count("would write") == len(parts)
    run(*command, "--expect-slot", "a", fails=True)
    compatible.write_bytes(b"not-a-zhiyu\0")
    run(*command, fails=True)
    compatible.write_bytes(b"lenovo,zhiyu\0")
    config = bootconfig.read_text()
    write(bootconfig, config.replace("_b", "_a"))
    run(*command, fails=True)
    write(bootconfig, config)

    modified = hashes.copy()
    modified[-1] = "0" * 64 + "  vbmeta.img"
    write(sums, "\n".join(modified))
    run(*command, fails=True)
    assert (profiles / "zhiyu-boot").readlink() == old
    with (root / "partitions/boot_b").open("rb") as file:
        assert file.read(4) == bytes(4)
    write(sums, "\n".join(hashes))
    run(*command, "--expect-slot", "b")
    assert not (profiles / "zhiyu-pending").is_symlink()
    assert (profiles / "zhiyu-boot").readlink() == new
    assert run(*command).count("unchanged") == len(parts)
    for part in parts:
        with (root / "partitions" / f"{part}_a").open("rb") as file:
            assert file.read(4) == bytes(4)

    # Roll back to another generation with a different kernel ID and image.
    old_images = old_path / "etc/zhiyu/boot-images"
    write(old_images / "BOOT-IDS", old_ids)
    for part, size in parts.items():
        image = old_images / f"{part}.img"
        with image.open("wb") as file:
            file.write(b"old" if part == "boot" else part.encode())
            file.truncate(size)
    old_sums = []
    for part in parts:
        name = f"{part}.img"
        with (old_images / name).open("rb") as file:
            old_sums.append(f"{hashlib.file_digest(file, 'sha256').hexdigest()}  {name}")
    write(old_images / "SHA256SUMS", "\n".join(old_sums))
    write(old_images / "SIZES", "\n".join(sizes))
    result = run(flasher, "--simulate", root, old_path)
    assert "complete (1 written)" in result
    assert (profiles / "zhiyu-boot").readlink() == old
    write(cmdline, good.replace(kernel, "c" * 64))
    assert run(selector, root, cmdline, bootconfig).strip() == str(old / "init")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        test(root, *sys.argv[1:])
        test_rescue(root / "rescue", sys.argv[1])
