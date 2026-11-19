#!/bin/sh
# Install the signed image set matching the running kernel into its boot slot.
set -eu

images=/usr/lib/linux-zhiyu/images
proc_bootconfig=/proc/bootconfig
proc_cmdline=/proc/cmdline
# The board is recognised by the properties our own device tree adds.  The
# stock DTBO that the bootloader applies on top overrides the root "model"
# and "compatible" with Qualcomm's values, but it knows nothing about these,
# so they always describe this port.
compat=/proc/device-tree/lenovo,mainline-compatible
partitions=/dev/disk/by-partlabel

log() { echo "zhiyu-image-update: $*" >&2; }

# Package installation is also used while building a rootfs on a CI host.
# Silently skip there; on this board, missing slot data is an error and must
# never fall back to guessing or changing the active slot.
if [ ! -r "$compat" ] || ! tr '\0' '\n' < "$compat" | grep -Fxq 'lenovo,zhiyu'; then
    log "not running on Lenovo zhiyu; skipping partition writes"
    exit 0
fi

if [ ! -r "$proc_bootconfig" ]; then
    log "kernel bootconfig unavailable; refusing to write partitions"
    exit 1
fi
slot=$(sed -n 's/^[[:space:]]*androidboot\.slot_suffix[[:space:]]*=[[:space:]]*"\(_[ab]\)"[[:space:]]*$/\1/p' "$proc_bootconfig")
case "$slot" in
    _a|_b) ;;
    *) log "could not determine current slot from /proc/bootconfig; refusing to write"; exit 1 ;;
esac

lsm=$(tr ' ' '\n' < "$proc_cmdline" | sed -n 's/^lsm=//p' | tail -n1)
case ",$lsm," in
    *,apparmor,*) variant=apparmor ;;
    *,selinux,*) variant=selinux ;;
    *) variant=none ;;
esac

status_dir=$(mktemp -d)
trap 'rm -f "$status_dir/decoded"; rmdir "$status_dir"' 0
trap 'exit 1' HUP INT TERM

# POSIX sh reports only the last command's status for a pipeline.
# Record decompression success independently without buffering the image.
decode_image() {
    xz -dc -- "$1.xz" && : > "$status_dir/decoded"
}

check_decoded() {
    if [ ! -f "$status_dir/decoded" ]; then
        log "could not decompress $image"
        exit 1
    fi
    rm -f "$status_dir/decoded"
}

set --
for label in boot vendor_boot init_boot vbmeta; do
    case "$label" in
        boot|vbmeta) image="$images/$label-$variant.img" ;;
        *) image="$images/$label.img" ;;
    esac
    device="$partitions/$label$slot"
    if [ ! -b "$device" ]; then
        log "partition $device not found; refusing to write"
        exit 1
    fi
    if [ ! -s "$image.xz" ]; then
        log "signed image $image missing; refusing to write"
        exit 1
    fi
    image_size=$(awk -v name="${image##*/}" '$2 == name { print $1 }' "$images/SIZES")
    case "$image_size" in
        ''|0*|*[!0-9]*) log "invalid image size for $image"; exit 1 ;;
    esac
    expected=$(awk -v name="${image##*/}" '$2 == name { print $1 }' "$images/SHA256SUMS")
    actual=$(decode_image "$image" | sha256sum)
    check_decoded
    if [ "${actual%% *}" != "$expected" ]; then
        log "image checksum mismatch: $image"
        exit 1
    fi
    partition_size=$(blockdev --getsize64 "$device")
    if [ "$image_size" -gt "$partition_size" ] ||
        { [ "$label" != vbmeta ] && [ "$image_size" -ne "$partition_size" ]; }; then
        log "$image ($image_size bytes) does not fit $device ($partition_size bytes)"
        exit 1
    fi
    set -- "$@" "$image" "$device" "$image_size"
done

# Resolve and validate the complete set before writing any partition.
log "updating slot $slot ($variant)"
while [ "$#" -gt 0 ]; do
    image=$1
    device=$2
    image_size=$3
    shift 3
    log "writing ${image##*/} to $device ($image_size bytes)"
    decode_image "$image" | dd of="$device" bs=4M iflag=fullblock conv=fsync status=none
    check_decoded
    blockdev --flushbufs "$device"
    decode_image "$image" | cmp -n "$image_size" - "$device"
    check_decoded
done
log "all image partitions in slot $slot were written and read back; reboot to run the updated kernel"
