# Licensing and third-party notices

Licenses in individual files and upstream source trees apply to those components.
The submodule revisions are recorded by Git and the other build dependency
revisions are recorded by the build scripts.

| Component | Applicable terms |
| --- | --- |
| Linux kernel | GPL-2.0-only for the kernel as a whole. Individual files retain their SPDX terms, including the Linux syscall exception where marked. See kernel-source/COPYING and kernel-source/LICENSES. |
| BusyBox | GPL version 2. See LICENSE in the pinned BusyBox source release. |
| libcamera | LGPL-2.1-or-later for the core libraries, GPL-2.0-or-later for the sample applications, and per-file terms for other components. See libcamera/COPYING.rst and libcamera/LICENSES. |
| HexagonRPC | GPL-3.0-or-later for the daemon and LGPL-3.0-or-later for the library components, subject to their source notices. |
| sensord | GPL-2.0-or-later, as stated in sensors/sensord.c. |
| initramfs programs | The init and helpers with SPDX headers use their stated licenses. Statically linked dependencies retain their own terms. See licenses/initramfs and the revisions and package versions in keymint/build-deps.sh and keymint/static-packages.tsv. |
| AudioReach topology | Zhiyu-vendorprops.m4 and the pinned AudioReach inputs use BSD-3-Clause and retain the upstream copyright notices. |
| Other files without an identified license | The respective copyright holders retain their rights. This notice grants no additional license. |

LicenseRef-Zhiyu-Unspecified marks files whose individual license has not
been established. Rights remain with their respective copyright holders.

## Vendor material

See [firmware notices](licenses/firmware/README.md) and the
[firmware manifest](initramfs-src/blobs/MANIFEST.tsv) for provenance.
The firmware, sensor configuration and stock device-tree dumps retain the
rights and terms of Lenovo, Qualcomm, Awinic, Novatek or other applicable
rights holders. A file's presence in the repository or in a build does not
grant permission to redistribute it. The upstream Qualcomm license texts
apply to their covered files only.

If you are a rights holder or an authorized representative and want to
request removal, please [contact the maintainer](https://github.com/PickaxeHit)
or use [GitHub's copyright reporting process](https://docs.github.com/en/site-policy/content-removal-policies/dmca-takedown-policy).
Include the relevant file path or artifact URL and the basis of the request.
