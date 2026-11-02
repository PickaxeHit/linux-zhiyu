# Front camera (GalaxyCore GC08A8)

The TB378FC has two cameras: an OV13B10 on CCI0/CSIPHY5 (rear, see
`cam-run.sh`) and a **GalaxyCore GC08A8** on CCI1 master 0 / CSIPHY1 (front).
Both now stream through CAMSS; the front one also reaches libcamera and qcam.

## Where the parts come from

The stock firmware names the sensor: `com.qti.sensor.gc08a8_sunwin_front.so`
and `com.qti.sensormodule.gc08a8_sunwin_front.bin` in `/vendor/lib64/camera`.
The vendor device tree has the wiring in its `qcom,cam-sensor1` node:

| property | value | meaning |
|---|---|---|
| `cci-master` | 0 | CCI1 master 0, sensor at address 0x31 |
| `csiphy-sd-index` | 1 | CSIPHY1 |
| `gpios` | `gpio93`, `gpio7` | CAM_MCLK4 pad, reset |
| `clocks` | cam_bist_mclk MCLK4 | 19.2 MHz input clock |
| `cam_vio` / `cam_vana` / `cam_vdig` | pm8550 l10 / l7 / pm_v8i l1 | 1.8 V / 2.8 V / 1.2 V |
| `sensor-position-roll` | 270 | matches `rotation = <270>` in our DT |

## What the mainline side needs

1. **The sensor driver.** `drivers/media/i2c/gc08a8.c` follows the in-tree
   gc08a3 pattern (v4l2-cci register access, `cci_reg_sequence` tables,
   runtime PM, exposure/gain/hblank/vblank controls); what is sensor specific
   is the init/mode register table, HTS/VTS (3652 x 2548), the pixel rate
   (281.6 MHz) and the 336 MHz link frequency.  3264x2448 RAW10 on four lanes.
2. **CCI1 pin muxing.** The `cci@ac7c000` node had no `pinctrl-0` at all, so
   the I2C pads were never switched to the CCI function and every transfer
   ended in `i2c-qcom-cci ... master 0 queue 0 timeout`.  Vendor pins: SCL
   gpio118, SDA gpio117, both `cci_i2c_scl`/`cci_i2c_sda`.
3. **CSIPHY lane mask.** CAMSS turns the *csiphy side* endpoint's `data-lanes`
   into `lncfg->data[i].pos` and from that a lane bitmask
   (`csiphy_get_lane_mask()`).  Writing the CSI-2 data lane numbers `<1 2 3 4>`
   gives mask `0x1e` and captures nothing; the physical lane positions
   `<0 1 2 3>` (what the working rear node uses, and what the reference port
   has) give `0xf`.
4. **CSIPHY supplies.** All six PHYs are fed from the same two rails
   (`vreg_l3g_1p2`, `vreg_l1f_0p88`).  Only `vdd-csiphy5-*` was described, so
   the driver kept dummy regulators for CSIPHY1 and never enabled the 1.2 V
   rail.  The node now lists `vdd-csiphy0..5-{1p2,0p9}-supply`.

## Rear-camera rails were wrong

The rear module is powered from `vreg_l8b_2p8` (avdd) and `vreg_l11b_1p2`
(dvdd); `cam_vana`/`cam_vdig` are the **front** module's rails
(`vreg_l7b_2p8`, `vreg_l1i_1p2`).  The rear node was bound to the front rails.
It still worked because every camera rail is `regulator-always-on` in this
device tree, but the binding is now correct (`cam_vana_rear`, `cam_vdig_rear`).

## Capturing

```
sh /root/cam-up.sh                 # camss + ov13b10 + v4l2-cci + gc08a8
sh /root/cam-front.sh /tmp/f.raw 1200
python3 /root/raw10-to-png.py /tmp/f.raw /tmp/f.png --bayer rggb
```

`cam-front.sh` resets the media links first: a leftover `csiphy -> csid` link
from the other camera makes the VFE pick the wrong source and the capture times
out, which is what makes "no frames" so easy to reproduce by accident.

Frame geometry: 3264x2448 packed 10-bit Bayer, **line stride 4080** (no
padding, unlike the rear sensor's 5264), size 9,987,840 bytes.

## Live preview

libcamera enumerates the front camera as `Internal front camera`
(`/base/cci@ac7c000/i2c-bus@0/camera@31`), and `cam -c 2` captures at 30 fps,
so `qcam -c 2` gives a live preview.  The sensor's black pedestal is around
230 of 1023, so a dim room looks black until the soft ISP's auto exposure and
gain ramp up; the RAW frames still contain the scene (see the light and edges
in the RAW captures from a dark room).

Not done yet: per-sensor tuning file for the software ISP (the front camera
still uses default AWB/CCM), and the gc08a8 sensor properties entry
(`blackLevel_`, `gain_` linear), which only affects colour, not framing.
