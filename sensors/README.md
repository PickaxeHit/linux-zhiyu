# SensorProxy userspace daemon

C daemon that publishes `net.hadess.SensorProxy` on the system bus and streams
ambient-light, accelerometer, and gyroscope values from the ADSP Sensor Core
through `sensh`/SNS Client.

This is the userspace/HAL-style path: no IIO kernel driver is involved.

## Build

```sh
make -C sensors
```

## Install

```sh
install -Dm755 sensors/sensord /usr/local/bin/sensord
install -Dm644 sensors/sensord.service /etc/systemd/system/sensord.service
systemctl daemon-reload
systemctl disable --now iio-sensor-proxy
systemctl enable --now sensord.service
```

The accelerometer stream is exposed as `AccelerometerOrientation`; the gyro
stream is read but SensorProxy has no standard gyro property.

Orientation uses an Android-style filter: a 200 ms low-pass filter, gravity
magnitude gating, a flat/horizontal dead band, a 60 degree hysteresis band,
and a 300 ms stable-candidate timer.  Lying the tablet flat (z gravity) never
changes the rotation.

When the orientation changes, the daemon writes the corresponding speaker
matrix rotation to:

```text
/sys/module/q6apm_lpass_dais/parameters/spk_rotation
```

The kernel programs the device-side MFC channel mixer (`PARAM_ID_CHMIXER_COEFF`);
no DSP graph reload is needed.

## Test

```sh
busctl --system get-property net.hadess.SensorProxy \
  /net/hadess/SensorProxy net.hadess.SensorProxy LightLevel
monitor-sensor --light
```

`iio-sensor-proxy` must not own `net.hadess.SensorProxy` at the same time.
