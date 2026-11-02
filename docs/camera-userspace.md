# Using the camera from ordinary programs

qcam talks to libcamera directly; everything else (ffmpeg, kamoso, cheese,
browsers) uses the V4L2 kernel interface, and on this board the VFE only offers
raw Bayer.  libcamera ships a compatibility layer for exactly that case: a
preloaded library that turns the application's `/dev/videoN` accesses into
libcamera requests, doing debayering, auto exposure and autofocus for it.

## Running an application through it

```sh
libcamerify ffmpeg -f v4l2 -i /dev/video2 -frames:v 10 out.mkv
libcamerify kamoso
libcamerify cheese
```

`/usr/local/bin/libcamerify` simply sets `LD_PRELOAD` to
`/usr/local/libexec/libcamera/v4l2-compat.so` and execs the application, so
anything that can be started from a shell can use the camera this way.

## Which /dev/video number

The layer *adds* its nodes after the ones the system already has.  On the
TB378FC the order is:

| node | device |
|---|---|
| /dev/video0 | Iris decoder |
| /dev/video1 | Iris encoder |
| **/dev/video2** | rear camera (OV13B10) through libcamara |
| /dev/video3 | front camera (GC08A8) |

`libcamerify v4l2-ctl -d /dev/video2 --info` prints the card name as the sensor
path, e.g. `/base/cci@ac7b000/i2c-bus@0/cam...`, which is how to tell which
camera a node is.

The layer exposes RGB formats only (`AB24`, `XB24`, `AR24`), so applications
that insist on YUYV will not work.

## Note on the build

libcamera must be built as a release build (`-Dbuildtype=release`): with the
default debug build the debayer and statistics run at `-O0`, a statistics frame
takes tens of milliseconds and the picture looks like it speeds up and slows
down even though the frame rate says 30 fps.

## The PipeWire route (recommended)

Two packages turn the cameras into system-wide video sources:

```sh
pacman -S --needed pipewire-libcamera pipewire-v4l2
```

`pipewire-libcamera` lets PipeWire open the cameras through libcamera (so the
tone mapping, auto exposure and autofocus above apply), and it publishes each
camera as a `Video/Source` node:

```sh
wpctl status            # two Video/Source nodes, one per camera
pw-cli ls Node
```

`pipewire-v4l2` ships the V4L2 interceptor, which makes those nodes look like
`/dev/video*` devices to ordinary applications:

```sh
LD_PRELOAD=/usr/lib/pipewire-0.3/v4l2/libpw-v4l2.so v4l2-ctl --list-devices
LD_PRELOAD=/usr/lib/pipewire-0.3/v4l2/libpw-v4l2.so ffmpeg -f v4l2 -i /dev/video1 ...
```

Unlike `libcamerify` this shares the camera between clients through PipeWire.

## About YUYV

Neither layer can hand an application YUYV on this board: the VFE only produces
raw Bayer, the software ISP debayers to RGB, and both compatibility layers pass
that RGB through (`AB24`/`XB24`/`AR24` from `libcamerify`, `AR24`/`XR24` from
`pipewire-v4l2`).  Applications that accept RGB and convert themselves - ffmpeg,
GStreamer, PipeWire clients, browsers using the camera portal - work as is.

An application that insists on YUYV needs a converter in between.  Two ways:

* `v4l2loopback` plus a feeder (`ffmpeg -f v4l2 -i /dev/video1 -pix_fmt yuyv422
  -f v4l2 /dev/video10`).  v4l2loopback is out of tree and is not built for this
  kernel, so it has to be built first.
* Teach the software ISP to output YUYV directly, which is the clean long-term
  fix: every client would then see it without a helper process.
