#!/bin/sh
set -eu
G=/sys/kernel/config/usb_gadget/g1
modprobe libcomposite 2>/dev/null || true
if [ ! -d "$G" ]; then
    mkdir -p "$G"
fi
cd "$G"
echo 0x1d6b > idVendor
echo 0x0104 > idProduct
mkdir -p strings/0x409
printf '%s\n' 'TB378FC0001' > strings/0x409/serialnumber
printf '%s\n' 'Lenovo' > strings/0x409/manufacturer
printf '%s\n' 'TB378FC NCM' > strings/0x409/product
mkdir -p configs/c.1/strings/0x409
printf '%s\n' 'NCM' > configs/c.1/strings/0x409/configuration
mkdir -p functions/ncm.usb0
ln -sf functions/ncm.usb0 configs/c.1/ncm.usb0 2>/dev/null || true
if [ ! -e UDC ] || [ -z "$(cat UDC 2>/dev/null)" ]; then
    echo a600000.usb > UDC
fi
i=0
while [ ! -e /sys/class/net/usb0 ]; do
    i=$((i + 1))
    [ "$i" -gt 100 ] && exit 1
    sleep 0.1
done
ip addr replace 192.168.42.1/24 dev usb0
ip link set usb0 up
