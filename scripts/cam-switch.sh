#!/bin/sh
# cam-switch - point the V4L2 loopback devices at one of the cameras.
#
#   cam-switch front   # gc08a8, 3256x2448, into /dev/video19
#   cam-switch rear    # ov13b10, 4200x3120, into /dev/video20
#   cam-switch off     # stop feeding
#
# libcamera's CAMSS handler manages one camera at a time: while a camera is
# streaming, its media graph is busy and the other camera cannot even be
# enumerated.  This switches between them, including the CSI/CSID links the
# camera needs (each one gets its own CSID, so the links do not fight).
set -e

MEDIA=${MEDIA:-/dev/media0}
CAMFEED=${CAMFEED:-camfeed}
FRONT_OUT=${FRONT_OUT:-/dev/video19}
REAR_OUT=${REAR_OUT:-/dev/video20}

stop_feeds() {
	pkill -x camfeed 2>/dev/null || true
	while pgrep -x camfeed >/dev/null 2>&1; do
		sleep 0.1
	done
}

media_link() {
	media-ctl -d "$MEDIA" -l "$1" 2>/dev/null || true
}

case "${1:-}" in
front)
	stop_feeds
	# gc08a8: csiphy1 -> csid1 -> vfe0_rdi1, so it does not share csid0
	media_link '"msm_csiphy1":1 -> "msm_csid0":0[0]'
	media_link '"msm_csiphy1":1 -> "msm_csid1":0[1]'
	media_link '"msm_csid1":2 -> "msm_vfe0_rdi1":0[1]'
	exec setsid "$CAMFEED" -c 1 -w 3256 -h 2448 -o "$FRONT_OUT"
	;;
rear)
	stop_feeds
	media_link '"msm_csiphy1":1 -> "msm_csid0":0[0]'
	media_link '"msm_csiphy1":1 -> "msm_csid1":0[0]'
	media_link '"msm_csiphy5":1 -> "msm_csid0":0[1]'
	media_link '"msm_csid0":1 -> "msm_vfe0_rdi0":0[1]'
	exec setsid "$CAMFEED" -c 0 -w 4200 -h 3120 -o "$REAR_OUT"
	;;
off)
	stop_feeds
	;;
*)
	echo "usage: $0 front|rear|off" >&2
	exit 1
	;;
esac
