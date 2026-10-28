#!/bin/sh
# TB378FC rear OV13B10: configure the CAMSS pipeline and capture one RAW10 frame.
#   sh cam-run.sh [output.raw]
# Requires cam-up.sh to have run in this boot.
set -x
OUT=${1:-/root/rear.raw}

node_of() { # $1 = subdev name -> /dev/v4l-subdevN
	for n in /sys/class/video4linux/v4l-subdev*/name; do
		[ "$(cat "$n" 2>/dev/null)" = "$1" ] &&
			echo "/dev/$(basename "$(dirname "$n")")"
	done
}

SUD=$(node_of 'ov13b10 4-0036')
CSIPHY=$(node_of msm_csiphy5)
CSID=$(node_of msm_csid2)
VFE=$(node_of msm_vfe2_rdi0)
VN=/dev/$(for n in /sys/class/video4linux/video*/name; do
	case "$(cat "$n" 2>/dev/null)" in
	msm_vfe2_video0) basename "$(dirname "$n")" ;;
	esac
done)
echo "sensor=$SUD csiphy=$CSIPHY csid=$CSID vfe=$VFE video=$VN"

# The sensor outputs SGRBG10_1X10, so the VFE pixelformat must be the
# matching packed 10-bit Bayer code 'pgAA'.  Using 'pBAA' makes
# video_start_streaming() fail with -EPIPE.
CODE=0x300a
W=4208
H=3120
PIX=pgAA

media-ctl -d /dev/media0 -l '"ov13b10 4-0036":0 -> "msm_csiphy5":0[1]'
media-ctl -d /dev/media0 -l '"msm_csiphy5":1 -> "msm_csid2":0[1]'
media-ctl -d /dev/media0 -l '"msm_csid2":1 -> "msm_vfe2_rdi0":0[1]'

for d in "$SUD" "$CSIPHY" "$CSID" "$VFE"; do
	v4l2-ctl -d "$d" --set-subdev-fmt pad=0,width=$W,height=$H,code=$CODE >/dev/null
done
v4l2-ctl -d "$CSIPHY" --set-subdev-fmt pad=1,width=$W,height=$H,code=$CODE >/dev/null
v4l2-ctl -d "$CSID" --set-subdev-fmt pad=1,width=$W,height=$H,code=$CODE >/dev/null

rm -f "$OUT"
v4l2-ctl -d "$VN" --set-fmt-video=width=$W,height=$H,pixelformat=$PIX
timeout 20 v4l2-ctl -d "$VN" --stream-mmap --stream-count=1 --stream-to="$OUT"
echo "capture rc=$?"
ls -l "$OUT"
dmesg | grep -iE "CSIPHY|CSID.*isr|ov13b10|TB " | tail -20
