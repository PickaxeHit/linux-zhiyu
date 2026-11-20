#!/usr/bin/env python3
"""Reject host-architecture ELF files in an ARM64 external-module build tree."""
import argparse
from pathlib import Path


def elf_machine(path):
    with path.open('rb') as f:
        header = f.read(20)
    if header[:4] != b'\x7fELF':
        return None
    if len(header) != 20 or header[4] != 2 or header[5] != 1:
        raise ValueError(f'{path}: expected ELF64 little endian')
    return int.from_bytes(header[18:20], 'little')


def verify(root):
    for name in ('scripts/basic/fixdep', 'scripts/mod/modpost'):
        path = root / name
        if not path.is_file() or not path.stat().st_mode & 0o111 or elf_machine(path) != 183:
            raise ValueError(f'{path}: missing executable AArch64 Kbuild helper')
    for path in root.rglob('*'):
        if path.is_file() and not path.is_symlink():
            machine = elf_machine(path)
            if machine is not None and machine != 183:
                raise ValueError(f'{path}: unexpected ELF machine {machine}; expected AArch64 (183)')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('headers', type=Path)
    args = parser.parse_args()
    try:
        verify(args.headers)
    except (ValueError, OSError) as exc:
        parser.exit(1, f'{exc}\n')
