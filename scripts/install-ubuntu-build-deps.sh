#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sudo apt-get update
sudo apt-get install -y \
  build-essential ccache autoconf automake libtool perl git pkg-config bc bison flex cpio \
  libssl-dev libelf-dev libncurses-dev lz4 zstd xz-utils bzip2 \
  device-tree-compiler clang lld llvm pahole \
  meson ninja-build cmake cargo curl dpkg-dev \
  libglib2.0-dev libgles2-mesa-dev python3-jinja2 python3-ply python3-yaml \
  alsa-utils m4 kmod file rsync gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
