# Rear-camera autofocus (DW9807 actuator)

The OV13B10's lens is moved by a DW9807 (or register-compatible) VCM driver IC
on CCI0 address 0x0c, powered from `vreg_l16b_2p8` (`cam_vaf`; the vendor tree
also lists this rail as the rear module's `cam_vaf`).  Nothing here changed when
the cameras' other rails were fixed: the front module owns
`vreg_l7b_2p8`/`vreg_l1i_1p2`, the rear module `vreg_l8b_2p8`/
`vreg_l11b_1p2`, and the actuator stays on `l16b`.

## Register map

| reg | meaning |
|---|---|
| 0x02 | control (`0x01` = start, `0x00` = standby) |
| 0x03 | position, **upper 2 bits** |
| 0x04 | position, **lower 8 bits** |
| 0x05 | status (busy while the lens slews) |
| 0x06/0x07 | mode / resonance |

The position is 10 bit (0..1023).  `dw9807_set_dac()` has to write 0x03 in its
own transfer and then 0x04 in a second one: a single burst, or 0x04 alone, does
not latch a new position on this part.  It also polls 0x05 until the lens is
idle, and leaves the driver in standby afterwards.

## Two ways to move the lens

Through the driver (preferred, smooth, sets the latch sequence correctly):

```sh
v4l2-ctl -d /dev/v4l-subdev33 -c focus_absolute=400
```

Directly over I2C (fine for calibration sweeps, but both registers and both
transfers are needed):

```sh
i2cset -y -f 4 0x0c 0x03 $(( pos >> 8 ))
i2cset -y -f 4 0x0c 0x04 $(( pos & 0xff ))
```

Writing `0x04` alone (as the old `af-sweep3.sh` did, in steps of 16) leaves the
upper bits at whatever they were: the sweep then only exercises 256 of the 1024
codes and every step is 16 counts, which looks like the lens jumping in coarse
irregular hops rather than tracking the sweep.

## Power and runtime PM

The actuator's rail is only enabled while the camera streams (the sensor's
`vaf` consumer is what turns `l16b` on).  If the driver's first resume happens
while that rail is still off, the I2C write to 0x02 fails with `-ENXIO`, and the
runtime-PM core latches `runtime_status = error` - after that every
`open()` on the subdev fails with `EINVAL` and `focus_absolute` appears dead
even though the rail is powered.  Recovering without a reboot:

```sh
echo 4-000c > /sys/bus/i2c/drivers/dw9807/unbind
echo 4-000c > /sys/bus/i2c/drivers/dw9807/bind	# with a stream running
```

`scripts/af-sweep.sh` sweeps the lens under one continuous capture and
`scripts/af-sharpness.py` ranks the frames by Laplacian variance, so the DAC
value with the crispest image can be read off directly.
