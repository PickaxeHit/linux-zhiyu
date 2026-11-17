#!/usr/bin/env bash
# Build an RPM from a staged root tree on Fedora.
set -euo pipefail
stage=$(realpath "${1:?staged root required}")
out=$(realpath -m "${2:?output directory required}")
name=${PKG_NAME:?package name required}
version=${PKG_VERSION:?package version required}
version=${version//-/_}
release=${PKG_REVISION:-1}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
find "$stage" -mindepth 1 ! -type d -printf '/%P\n' | LC_ALL=C sort |
    while IFS= read -r file; do
        case "$file" in
            /etc/*) printf '%%config(noreplace) "%s"\n' "$file" ;;
            *) printf '"%s"\n' "$file" ;;
        esac
    done > "$work/files"
cat > "$work/package.spec" <<SPEC
Name: $name
Version: $version
Release: $release
Summary: ${PKG_DESC:-Zhiyu $name}
License: ${PKG_LICENSE:?package license metadata required}
URL: https://github.com/PickaxeHit/linux-zhiyu
ExclusiveArch: aarch64
%global debug_package %{nil}
%global __os_install_post %{nil}
${PKG_RPM_REQUIRES:+Requires: $PKG_RPM_REQUIRES}
${PKG_RPM_PROVIDES:+Provides: $PKG_RPM_PROVIDES}
${PKG_RPM_CONFLICTS:+Conflicts: $PKG_RPM_CONFLICTS}

%description
${PKG_DESC:-Zhiyu $name}

%install
mkdir -p "%{buildroot}"
cp -a "$stage/." "%{buildroot}/"

%files -f $work/files
%defattr(-,root,root,-)
SPEC

if [[ -n "${PKG_RPM_POST:-}" ]]; then
    printf '\n%%posttrans -p /bin/sh\n%s\n' "$PKG_RPM_POST" >> "$work/package.spec"
fi
rpmbuild -bb --target aarch64 --define "_topdir $work/rpm" --define "_rpmdir $out" "$work/package.spec"
