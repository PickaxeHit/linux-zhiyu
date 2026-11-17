#!/usr/bin/env bash
# Run inside a Fedora 44 aarch64 container.
set -euo pipefail
dnf -y --setopt=install_weak_deps=False install rpm-build redhat-rpm-config gcc gcc-c++ make meson ninja-build git \
    python3-pyyaml python3-jinja2 python3-ply pkgconf-pkg-config \
    glib2-devel systemd-devel libdrm-devel libevent-devel libyaml-devel \
    libjpeg-turbo-devel qt6-qtbase-devel mesa-libEGL-devel mesa-libGL-devel \
    openssl-devel libatomic curl tar gzip

install -d out/rpms
if [[ -d stage/linux-zhiyu-modules ]]; then
    modules=(stage/linux-zhiyu-modules/usr/lib/modules/*)
    test "${#modules[@]}" -eq 1
    kernel_version=${modules[0]##*/}
    rpm_kernel_version=${kernel_version//-/_}

    for part in modules headers firmware images; do
        (
            export PKG_NAME="linux-zhiyu-$part" PKG_VERSION="$kernel_version"
            case "$part" in
                modules)
                    export PKG_LICENSE=GPL-2.0-only PKG_RPM_REQUIRES=kmod
                    ;;
                headers)
                    export PKG_LICENSE=GPL-2.0-only PKG_RPM_REQUIRES='gcc, make'
                    ;;
                firmware)
                    export PKG_LICENSE='LicenseRef-Zhiyu-Firmware'
                    ;;
                images)
                    export PKG_LICENSE='GPL-2.0-only AND LicenseRef-Zhiyu-Firmware'
                    export PKG_RPM_REQUIRES="coreutils, util-linux, grep, sed, gawk, diffutils, xz, linux-zhiyu-modules = $rpm_kernel_version-${PKG_REVISION:-1}"
                    export PKG_RPM_POST='/usr/libexec/zhiyu/update-boot-images.sh'
                    ;;
            esac
            scripts/mkrpm.sh "stage/$PKG_NAME" out/rpms
        )
    done
fi

if [[ "${BUILD_USERSPACE:-false}" == true ]]; then
    hexagonrpc_revision=$(cat scripts/hexagonrpc-revision)
    mkdir -p out/hexagonrpc-source
    curl --fail --silent --show-error --location --retry 3 \
        "https://codeload.github.com/linux-msm/hexagonrpc/tar.gz/$hexagonrpc_revision" |
        tar -xz --strip-components=1 -C out/hexagonrpc-source
    meson setup out/fedora-hexagonrpc out/hexagonrpc-source \
        --buildtype=release --prefix=/usr --libdir=lib64
    meson compile -C out/fedora-hexagonrpc
    hexagonrpc_stage="$PWD/stage/fedora-hexagonrpc"
    DESTDIR="$hexagonrpc_stage" meson install -C out/fedora-hexagonrpc --no-rebuild
    install -d "$hexagonrpc_stage/usr/lib/systemd/system" \
        "$hexagonrpc_stage/usr/lib/sysusers.d" "$hexagonrpc_stage/usr/lib/tmpfiles.d"
    mv "$hexagonrpc_stage"/usr/lib64/systemd/system/hexagonrpcd-*.service \
        "$hexagonrpc_stage/usr/lib/systemd/system/"
    printf '%s\n' 'u fastrpc - "FastRPC" /var/lib/fastrpc' \
        > "$hexagonrpc_stage/usr/lib/sysusers.d/fastrpc.conf"
    printf '%s\n' 'd /usr/share/qcom/sensors/registry 0755 fastrpc fastrpc -' \
        > "$hexagonrpc_stage/usr/lib/tmpfiles.d/hexagonrpc.conf"
    license_dir="$hexagonrpc_stage/usr/share/licenses/hexagonrpc"
    install -Dm644 out/hexagonrpc-source/COPYING "$license_dir/COPYING"
    install -m644 licenses/LGPL-3.0.txt "$license_dir/LGPL-3.0.txt"
    hexagonrpc_version=$(meson introspect out/fedora-hexagonrpc --projectinfo |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
    PKG_NAME=hexagonrpc PKG_VERSION="$hexagonrpc_version" \
        PKG_DESC="Qualcomm Hexagon FastRPC daemon and libraries" \
        PKG_LICENSE='GPL-3.0-or-later AND LGPL-3.0-or-later' \
        scripts/mkrpm.sh "$hexagonrpc_stage" out/rpms

    # Use Fedora's native ABI and libdir for userspace binaries.
    meson setup out/fedora-camera libcamera --buildtype=release --prefix=/usr --libdir=lib64 \
        -Dwerror=false -Dqcam=enabled -Dpipelines=simple -Dgstreamer=disabled \
        -Dpycamera=disabled -Ddocumentation=disabled -Dcam=enabled -Dv4l2=enabled
    meson compile -C out/fedora-camera
    DESTDIR="$PWD/stage/fedora-camera" meson install -C out/fedora-camera --no-rebuild
    version=$(meson introspect out/fedora-camera --projectinfo |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
    PKG_NAME=libcamera-zhiyu PKG_VERSION="$version" \
        PKG_LICENSE='LGPL-2.1-or-later AND GPL-2.0-or-later' \
        PKG_RPM_PROVIDES="libcamera = $version" PKG_RPM_CONFLICTS="libcamera < $version, libcamera > $version" \
        scripts/mkrpm.sh stage/fedora-camera out/rpms

    make -C sensors -B
    install -Dm755 sensors/sensord stage/fedora-sensord/usr/bin/zhiyu-sensord
    install -Dm644 sensors/zhiyu-sensord.service \
        stage/fedora-sensord/usr/lib/systemd/system/zhiyu-sensord.service
    sed -i 's#ExecStart=/usr/local/bin/#ExecStart=/usr/bin/#' \
        stage/fedora-sensord/usr/lib/systemd/system/zhiyu-sensord.service
    PKG_NAME=zhiyu-sensord PKG_VERSION=1.0.0 PKG_LICENSE=GPL-2.0-only \
        scripts/mkrpm.sh stage/fedora-sensord out/rpms
fi
