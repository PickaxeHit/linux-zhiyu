#!/bin/bash
# Extract the device firmware from a ZUXOS factory image directory.
#
# The script is intentionally self-contained: it reads only the images below
# and never copies firmware from blobs/firmware.  It replaces the stock parts:
#
#   BTFM.bin       -> qca/brh*                 (WCN7860 Bluetooth)
#   NON-HLOS.bin   -> qcom/sm8750/...          (ADSP/CDSP/Modem/peach)
#   super_7.img    -> aw882xx_acf.bin, novatek/nt36526e-zhiyu.bin, qcom/gen80000*
#
# ath12k/WCN7860 and tplg are deliberately left untouched: ZUXOS has no
# mainline ath12k image, and tplg is generated locally.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
images=${ZUXOS_IMAGES:-/nosnap/gt13-port/TB378_ZUXOS_2.0.10.252_Tool/image}
out=${ZUXOS_OUT:-$root/initramfs-src/blobs/firmware}
tmp=

die() { echo "extract-zuxos-firmware: $*" >&2; exit 1; }
cleanup() { [ -z "$tmp" ] || rm -rf "$tmp"; }
trap cleanup EXIT

while [ $# -gt 0 ]; do
	case "$1" in
	--images) images=$2; shift 2 ;;
	--out) out=$2; shift 2 ;;
	-h|--help)
		echo "usage: $0 [--images DIR] [--out DIR]"
		exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

for tool in 7z debugfs; do
	command -v "$tool" >/dev/null || die "$tool not found"
done
for img in BTFM.bin NON-HLOS.bin super_7.img; do
	[ -f "$images/$img" ] || die "missing $images/$img"
done

tmp=$(mktemp -d)
mkdir -p "$out/qca" "$out/qcom/sm8750" "$out/novatek"
rm -rf "$out/qca" "$out/qcom/sm8750" "$out/novatek"
mkdir -p "$out/qca" "$out/qcom/sm8750" "$out/novatek"

# ---- Bluetooth: BTFM.bin is a FAT image with image/brh* -------------------
7z x -y -o"$tmp/btfm" "$images/BTFM.bin" >/dev/null 2>&1 || [ $? -eq 2 ]
find "$tmp/btfm" -type f -path '*/image/brh*' -exec cp -f {} "$out/qca/" \;
[ -n "$(find "$out/qca" -type f -name 'brh*' -print -quit)" ] || die "no brh firmware in BTFM.bin"

# ---- ADSP/CDSP/Modem/peach: NON-HLOS.bin is a FAT image with image/* ------
7z x -y -o"$tmp/nonhlos" "$images/NON-HLOS.bin" >/dev/null 2>&1 || [ $? -eq 2 ]
find "$tmp/nonhlos" -type f -path '*/image/peach/*' | while read -r f; do
	rel=${f#*/image/peach/}
	mkdir -p "$out/qcom/sm8750/peach/$(dirname "$rel")"
	cp -f "$f" "$out/qcom/sm8750/peach/$rel"
done
find "$tmp/nonhlos" -type f -path '*/image/modem_pr/*' | while read -r f; do
	rel=${f#*/image/modem_pr/}
	mkdir -p "$out/qcom/sm8750/modem_pr/$(dirname "$rel")"
	cp -f "$f" "$out/qcom/sm8750/modem_pr/$rel"
done
find "$tmp/nonhlos" -type f -path '*/image/*' | while read -r f; do
	rel=${f#*/image/}
	case "$rel" in
	peach/*|modem_pr/*) continue ;;
	esac
	cp -f "$f" "$out/qcom/sm8750/$rel"
done

# ---- Vendor firmware: super_7.img volume "vendor" is ext4 -----------------
super=$images/super_7.img
dump_fw() {
	local src=$1 dst=$2
	debugfs -R "stat $src" "$super" 2>/dev/null | grep -q 'Inode:' || return 0
	mkdir -p "$(dirname "$dst")"
	debugfs -R "dump $src $dst" "$super" >/dev/null 2>&1
}
dump_fw /firmware/aw882xx_acf.bin "$out/aw882xx_acf.bin"
dump_fw /firmware/novatek_ts_fw.bin "$out/novatek/nt36526e-zhiyu.bin"
dump_fw /firmware/gen80000_zap.mbn "$out/qcom/sm8750/zhiyu/gen80000_zap.mbn"
dump_fw /firmware/vpu35_4v.mbn "$out/qcom/sm8750/vpu35_4v.mbn"
for f in gen80000_aqe.fw gen80000_gmu.bin gen80000_sqe.fw; do
	dump_fw "/firmware/$f" "$out/qcom/$f"
done

# Audio topology is generated locally, not present in the Android firmware.
if [ -f "$root/initramfs-src/tplg/sm8750-tplg.bin" ]; then
	cp -f "$root/initramfs-src/tplg/sm8750-tplg.bin" "$out/qcom/sm8750/"
fi

echo "== extracted =="
for p in qca qcom/sm8750 novatek aw882xx_acf.bin; do
	[ -e "$out/$p" ] || continue
	n=$(find "$out/$p" -type f 2>/dev/null | wc -l)
	s=$(du -sh "$out/$p" 2>/dev/null | cut -f1)
	printf '%-24s %4s files  %s\n' "$p" "$n" "$s"
done
find "$out/qca" -type f -printf '  %f\n' | sort | head -5
echo "  ..."
