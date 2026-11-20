#!/bin/bash
# Runs as container root only; installs packages into the ephemeral container.
set -euo pipefail
case ${DISTRO:?} in
    debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends bash coreutils findutils tar gzip xz-utils zstd binutils python3 util-linux ca-certificates dpkg-dev
        if [[ $BUILD_KERNEL == true && $BUILD_USERSPACE != true ]]; then
            apt-get install -y --no-install-recommends build-essential
        fi
        if [[ $BUILD_USERSPACE == true ]]; then
            apt-get install -y --no-install-recommends build-essential meson ninja-build git pkg-config \
                python3-jinja2 python3-ply python3-yaml python3-pip \
                libudev-dev libdrm-dev libevent-dev libyaml-dev libjpeg-dev libglib2.0-dev \
                qt6-base-dev libgl-dev libegl-dev libgles-dev libssl-dev
        fi
        ;;
    arch)
        # Landlock sandboxing is unavailable in some containers/hosts; pacman
        # otherwise refuses to open its databases.  Keep signature checks on.
        sed -i 's/^#DisableSandboxFilesystem/DisableSandboxFilesystem/; s/^#DisableSandboxSyscalls/DisableSandboxSyscalls/' /etc/pacman.conf
        # Full upgrade, never a partial upgrade; keep package signature checks.
        pacman-key --init
        pacman-key --populate archlinuxarm
        pacman -Syu --noconfirm --needed bash coreutils findutils tar gzip xz zstd binutils python util-linux ca-certificates
        if [[ $BUILD_KERNEL == true && $BUILD_USERSPACE != true ]]; then
            pacman -S --noconfirm --needed gcc make
        fi
        if [[ $BUILD_USERSPACE == true ]]; then
            pacman -S --noconfirm --needed base-devel meson ninja git pkgconf qt6-tools \
                python-jinja python-ply python-yaml systemd-libs libdrm libevent libyaml \
                libjpeg-turbo glib2 qt6-base libglvnd mesa openssl
        fi
        ;;
    fedora)
        dnf -y --setopt=install_weak_deps=False install rpm-build redhat-rpm-config bash coreutils findutils tar gzip xz zstd binutils python3 util-linux ca-certificates
        if [[ $BUILD_KERNEL == true && $BUILD_USERSPACE != true ]]; then
            dnf -y --setopt=install_weak_deps=False install gcc make
        fi
        if [[ $BUILD_USERSPACE == true ]]; then
            dnf -y --setopt=install_weak_deps=False install gcc gcc-c++ make meson ninja-build git \
                python3-pyyaml python3-jinja2 python3-ply pkgconf-pkg-config \
                glib2-devel systemd-devel libdrm-devel libevent-devel libyaml-devel \
                libjpeg-turbo-devel qt6-qtbase-devel mesa-libEGL-devel mesa-libGL-devel mesa-libGLES-devel \
                openssl-devel libatomic curl qmic qrtr-devel protobuf-c-devel protobuf-c-compiler
        fi
        ;;
    *) exit 2 ;;
esac
