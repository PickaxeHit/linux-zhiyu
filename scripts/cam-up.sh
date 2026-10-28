#!/bin/sh
# TB378FC rear OV13B10: load the camera stack (run on the device).
#   M=/root/cam SEQ=0 sh cam-up.sh
# SEQ=0 -> mainline power sequence (MCLK first). SEQ=1 -> legacy MCLK-last.
set -e
M=${M:-/root/cam}
SEQ=${SEQ:-0}

# Camera clock providers must be up before the sensor probes: without
# cambistmclkcc-sm8750 the sensor's clk_get() defers forever and the
# sensor never binds (-EPROBE_DEFER shown as "Resource temporarily
# unavailable" when binding by hand).
modprobe -a camcc-sm8750 cambistmclkcc-sm8750
modprobe -a v4l2-fwnode v4l2-async mc videobuf2-common videobuf2-v4l2 \
	videobuf2-dma-sg

insmod "$M/ov13b10.ko" tb_pwr_seq="$SEQ"
insmod "$M/qcom-camss.ko"

i=0
while :; do
	if [ -e /dev/media0 ] && [ -e /sys/bus/i2c/devices/4-0036/driver ]; then
		break
	fi
	i=$((i + 1))
	if [ "$i" -gt 150 ]; then
		echo "sensor/media did not come up" >&2
		exit 1
	fi
	sleep 0.2
done
echo "camera stack up (power sequence $SEQ)"
