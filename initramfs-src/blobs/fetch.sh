#!/bin/bash
# fetch.sh — (re)populate blobs/ from their documented origins.
#
#   blobs/firmware/{ath12k,qca,qcom}   Arch linux-firmware package on the device
#   blobs/firmware/novatek/*.bin       stock firmware dump (stock-fw/)
#   blobs/firmware/aw882xx_acf.bin     stock vendor partition (stock-dump/)
#   blobs/firmware/qcom/sm8750/sm8750-tplg.bin{,.v2}
#                                      built from tplg/*.m4 (kept as blob, see MANIFEST)
#
# Running this is only needed when blobs/ is missing or the device firmware
# package was updated; the normal build (../build.sh) uses blobs/ as-is.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
DEV=${DEV:-root@192.168.31.156}       # device with Arch linux-firmware installed
WS=${WS:-/nosnap/gt13-port}
FW=$here/firmware

mkdir -p "$FW"

echo "== firmware subtrees from $DEV:/usr/lib/firmware =="
for d in ath12k qca qcom; do
	echo "   $d"
	ssh -o BatchMode=yes "$DEV" "cd /usr/lib/firmware && tar -cf - $d" | tar -xf - -C "$FW"
done

echo "== vendor blobs from the stock dumps =="
mkdir -p "$FW/novatek"
cp -f "$WS/stock-fw/novatek_ts_fw.bin"            "$FW/novatek/nt36526e-zhiyu.bin"
cp -f "$WS/stock-dump/vendor/firmware/aw882xx_acf.bin" "$FW/aw882xx_acf.bin"

echo "== sensor registry/config from the stock vendor image =="
# hexagonrpcd serves these to the ADSP (file access over fastrpc).  They live
# on the Android vendor partition, which is a logical partition inside super,
# so they are read straight out of the dumped vendor image with debugfs.
VIMG=$WS/stock-dump/vendor.img
if [ -f "$VIMG" ]; then
	tmp=$(mktemp -d)
	debugfs -R "rdump /etc/sensors $tmp" "$VIMG" >/dev/null 2>&1 || true
	if [ -d "$tmp/sensors" ]; then
		rm -rf "$here/sensors"
		mkdir -p "$here/sensors"
		cp -a "$tmp/sensors/config" "$here/sensors/config"
		# hexagonrpcd expects /sensors/sns_reg.conf (not sns_reg_config)
		cp -f "$tmp/sensors/sns_reg_config" "$here/sensors/sns_reg.conf"
		chmod 644 "$here/sensors/sns_reg.conf"
		echo "   $(find "$here/sensors" -type f | wc -l) files from vendor.img:/etc/sensors"
	else
		echo "   WARNING: could not extract /etc/sensors from $VIMG"
	fi
	rm -rf "$tmp"
else
	echo "   WARNING: $VIMG missing, sensors/ blobs not refreshed"
fi

echo "== audio topology: kept as blob, sources in ../tplg =="
[ -f "$FW/qcom/sm8750/sm8750-tplg.bin" ] || \
	echo "   WARNING: qcom/sm8750/sm8750-tplg.bin missing (rebuild from ../tplg/*.m4)"

echo "== summary =="
echo "   $(find "$FW" -type f | wc -l) firmware files, $(du -sh "$FW" | cut -f1)"
