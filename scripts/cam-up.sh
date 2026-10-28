#!/bin/sh
# TB378FC rear OV13B10: load the camera stack (run on the device, as root).
#
#   sh /root/cam-up.sh
#
# Idempotent: exits early when the stack is already up, so it is safe to call
# from a boot service and by hand.
set -e
M=${M:-/root/cam}

loaded() { lsmod | grep -q "^$1 "; }

# The system dma-buf heap is a module; without it libcamera cannot allocate
# buffers for the software ISP and silently disables debayering.
modprobe -a system_heap
# Flash LED (used as a fill light for the rear camera).
modprobe -a led-class-flash leds-qcom-flash

# Camera clock providers must be up before the sensor probes: without
# cambistmclkcc-sm8750 the sensor's clk_get() defers forever and the sensor
# never binds (-EPROBE_DEFER shows up as "Resource temporarily unavailable"
# when binding by hand).
modprobe -a camcc-sm8750 cambistmclkcc-sm8750
modprobe -a v4l2-fwnode v4l2-async mc videobuf2-common videobuf2-v4l2 \
	videobuf2-dma-sg

if ! loaded qcom_camss; then
	insmod "$M/qcom-camss.ko"
fi
if ! loaded ov13b10; then
	insmod "$M/ov13b10.ko"
fi

i=0
while :; do
	[ -e /dev/media0 ] && break
	i=$((i + 1))
	if [ "$i" -gt 150 ]; then
		echo "camera stack did not come up" >&2
		exit 1
	fi
	sleep 0.2
done

# VCM autofocus (dw9807-compatible GT9772B on the same CCI bus).
modprobe dw9807-vcm 2>/dev/null || insmod /root/cam/dw9807-vcm.ko 2>/dev/null || true

if [ -e /dev/dma_heap/system ]; then
	echo "camera stack up"
else
	echo "camera stack up (warning: no /dev/dma_heap/system)" >&2
fi
