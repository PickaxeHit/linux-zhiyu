# Backlight (AW99706) and the whine it couples into the microphones

Two AW99706 boost converters drive the panel's LED strings: the master on
`i2c-1` address `0x76` and a slave on `i2c-0` address `0x76` (the driver mirrors
its writes to both).  With the backlight on, the microphones pick up a group of
steady tones, which is what the "electrical noise" in the capture is:

| frequency | gain with the backlight on |
|---|---|
| 3483.4 / 3723.6 / 3843.8 / 3963.9 Hz | +15 … +19 dB |
| 9369 / 9407 / 9952 / 9969 / 9984 Hz | +14 … +16 dB |
| 11481 / 12012 / 13213 Hz | +14 … +16 dB |

Measured back-to-back, seconds apart, in a quiet room (a 5 s recording each way):

| | 3.5-4 kHz, per 0.5 s window |
|---|---|
| panel dark | 2.8 2.1 2.6 2.7 3.0 2.8 2.9 2.4 3.3 % |
| panel lit | 12.1 11.6 12.3 11.6 10.7 11.8 10.6 11.8 11.7 % |

Steady in every window, so this is a tone and not room noise.  The difference
spectrum puts it at 2642, 2762, 3002, 3123, 3603, 3720, 3840 and 3884 Hz, plus
10810 and 13213 Hz, about 20 dB above the noise floor.

The tones are **coupled to the panel refresh rate**.  The same measurement run
at 120 Hz refresh shows peaks spaced 120 Hz apart, and at 60 Hz refresh the peaks
are twice as dense, spaced 60 Hz:

| refresh | peaks in 1.5-5.5 kHz | spacing |
|---|---|---|
| 120 Hz | 2281, 2521, 3483, 3604, 3722, 3842 Hz | 120 Hz |
| 60 Hz | 1982 … 2943, 3483, 3543, 3604, 3664, 3724, 3784, 3844, 3904, 4024 Hz | 60 Hz |
| 144 Hz | 2448, 2736, 2880, 3601, 3744 Hz | 144 Hz |

Three refresh rates, three spacings, all equal to the frame rate: the sidebands are
the panel refresh modulating a carrier that sits around 3.6 kHz.  Choosing a
refresh rate therefore chooses the note: 120 Hz gives the fewest components (six
above the threshold), 60 Hz the most.

The carriers (3483, 3604, 3724, 3844 Hz) do not move, only the sideband grid, so
the LED driver's switching is frame-synchronised.  `docs/images/backlight-comb-60-120-144.png` shows the three spectrograms, one per
refresh rate.

An earlier attempt at this comparison found nothing because the panel was in
fact dark during the "lit" recording: the experiments above had left the dimming
mode at analogue with the brightness registers at zero.  Back-to-back recordings
in the same session, checking that the panel is really lit, are the only ones
that count.

One oddity worth knowing: the brightness registers read back as 0x00/0x00 on both
chips even with the panel at full brightness and `/sys/class/backlight/.../
brightness` reporting 4095, so brightness must reach the panel through another
path than CFG4/CFG5.  The register map below is from the driver source, not from
watching a working brightness update.

The low group is spaced 120 Hz apart, i.e. sidebands from the panel's
120 Hz refresh around a carrier near 3.9 kHz.  Nothing of the sort is present
with the backlight off, so this is not the codec, not the SoundWire link and not
"noise" in the random sense.

## Registers

`BUS=1` is the master, `BUS=0` the slave; both at `0x76`.

| reg | field | notes |
|---|---|---|
| 0x00 | dim mode, bits[1:0] | 1 = PWM (default), 0 = analogue |
| 0x01 | switch frequency, bits[3:0] | index into the table below |
| 0x01 | switch current limit, bits[5:4] | 0 = 1.5 A, 1 = 2 A, 2 = 2.5 A, 3 = 3 A |
| 0x02 | LED current limit, bits[6:0] | 20 mA steps from 10 mA |
| 0x02 | UVLO select, bit 7 | 0 = 2.2 V, 1 = 5.0 V |
| 0x04 | brightness[11:8], bits[3:0] | |
| 0x05 | brightness[7:0] | 12 bit, 4095 = max |
| 0x06 | ramp control, bits[7:6] | |
| 0x10 | enable, bit 7 | |
| 0x11 | chip id | 0x07 |

Switch frequency table (index → Hz): 0-3 reserved, 4 = 300 k, 5 = 400 k,
6 = 500 k, 7 = 600 k, 8 = 660 k, 9 = 750 k (default), 10 = 850 k, 11 = 1 M,
12 = 1.2 M, 13 = 1.33 M, 14 = 1.5 M, 15 = 1.7 M.

## Usefully safe read-modify-write

Writing a register wholesale clobbers the other fields in it, so change only the
bits you care about:

```sh
# set_field BUS REG SHIFT WIDTH VALUE
set_field() {
	cur=$(i2cget -y -f "$1" 0x76 "$2")
	new=$(( (cur & ~(( (1 << $4) - 1 ) << $3)) | (($5 & ((1 << $4) - 1)) << $3) ))
	i2cset -y -f "$1" 0x76 "$2" "$(printf 0x%02x $new)"
	i2cget -y -f "$1" 0x76 "$2"
}

set_field 1 0x01 0 4 15	  # master: switch frequency -> 1.7 MHz
set_field 1 0x00 0 2 0	  # master: analogue dimming
set_field 1 0x01 4 2 3	  # master: 3 A switch current limit
```

Brightness, bypassing the driver (it overwrites these on its next update):

```sh
# 12 bit value, e.g. 2000
i2cset -y -f 1 0x76 0x04 $(( (2000 >> 8) & 0x0f ))
i2cset -y -f 1 0x76 0x05 $(( 2000 & 0xff ))
```

## What was already tried

Neither the dimming mode (PWM → analogue) nor the boost switching frequency
(750 k → 1 M/1.33 M/1.7 M) changed the level of the 3.5-4 kHz group in short
measurements, on the master chip.  The slave has not been tried yet, and the
measurement window matters: a few seconds of capture is dominated by whatever
else is going on in the room, so compare 20 s recordings (see
`scripts/mic-spectrum.py`).

## Notching the tones out of the capture (implemented)

`scripts/pipewire/50-mic-notch.conf` installs a PipeWire filter chain that pulls
from the real microphone and exposes a second source with ten notches per channel
(Q = 25) at exactly the measured frequencies: 2642, 2762, 3002, 3123, 3603, 3720,
3840, 3884, 10810 and 13212 Hz.
The builtin biquads are mono, so the graph has one chain of eight per channel.

```sh
sudo cp scripts/pipewire/50-mic-notch.conf /etc/pipewire/pipewire.conf.d/
systemctl --user restart pipewire wireplumber
```

Two sources then exist:

| source | node name | use |
|---|---|---|
| `Mic (notched)` | `mic_notched.output` | recordings, calls |
| `Internal microphones (AMIC1 + AMIC4)` | `alsa_input.platform-sound.HiFi__Mic__source` | raw, for comparing |

Measured on the same subject with the panel lit:

| band | raw | notched |
|---|---|---|
| 3.5–4 kHz | 3.8 % | **0.4 %** |
| 4–12 kHz | 30.1 % | 25.7 % |
| 300–1000 Hz | 5.6 % | 6.9 % |
| 1–3 kHz | 13.0 % | 13.7 % |

The individual tones drop by 33-47 dB while the speech band is unchanged, which
is the point of notching rather than turning the capture gain down.

To make it the default microphone:

```sh
wpctl status | grep -i notched        # find its id
wpctl set-default <id>
```

## The quiet state, and how to get back to it

The comb is present in some panel states and absent in others, at the *same*
brightness.  Measured in one 60 s recording while the display was switched and
then the brightness nudged:

| time | 3.5-4 kHz | what happened |
|---|---|---|
| 0-9 s | 9-11 % | normal, comb present |
| 9.5-13.5 s | 2.5-9 % | output blanked and restored |
| 13.5-26 s | ~3 % | quiet, comb gone, brightness unchanged |
| 26-27.5 s | 9-11 % | brightness written again |
| 27.5 s on | ~3 % | |

So the tones are re-armed by *writing the brightness* and dropped by a
blank/restore cycle.  Dumping every AW99706 register in both states leaves only
one unexplained difference, 0x12 = 0x3f (present) against 0x00 (quiet), which the
LED-open flag register is documented to hold - it may simply have been cleared by
the first read, so treat it as a hint rather than a cause.

Two practical consequences:

* `scripts/backlight-quiet.sh` blanks and restores the output with its current
  mode, which is what silenced it in the measurement above.  Run it from the
  desktop session after a brightness change.
* On Plasma the *panel* brightness slider re-arms the comb on every step, while
  the brightness control in System Settings does not.  Prefer the latter.

Neither is a fix - the fix would be to make the AW99706 stop re-arming its
dimming per frame - but both make the microphone usable today.

## What it actually is: the DSI link, not the backlight

The final measurements point away from the backlight entirely.  With the picture
content as the only variable the interference follows the content: a static,
low-entropy image is the quietest, a detailed one is louder, and moving content
is the loudest.  That is the signature of the DSI link's *data* transitions, not
of a backlight driver.

The evidence that ruled the backlight out:

* the whole AW99706 register file (0x00-0x1F, both chips) is byte-identical
  between a noisy state (3.5-4 kHz at 10.4 % of the band energy) and a quiet one
  (4.1 %);
* the comb spacing equals the panel refresh rate at 60, 120 and 144 Hz, i.e. the
  interference repeats once per frame, which is how often the display stream is
  gated;
* enabling spread spectrum on the DSI PLL (`drivers/gpu/drm/msm/dsi/phy/
  dsi_phy_7nm.c`, the vendor enables it too) changes very little, because SSC
  smears the clock, not the data pattern;
* lowering the refresh rate helps only slightly, with the same content:

| refresh | 3.5-4 kHz | 4-12 kHz |
|---|---|---|
| 60 Hz | 8.7 % | 23.1 % |
| 90 Hz | 9.1 % | 24.6 % |
| 120 Hz | 9.4 % | 28.2 % |
| 144 Hz | 9.2 % | 26.7 % |

So this is an EMC problem on the display-to-microphone path: shielding, the
grounds on the panel flex and the routing of the microphone traces are the things
to look at.  Software can only trim the peaks, which is what the notch chain in
`scripts/pipewire/50-mic-notch.conf` does; it is worth regenerating its
frequencies for the refresh rate actually in use, since they are harmonics of the
frame rate.

## The fix: keep the DSI clock lane running

`MIPI_DSI_CLOCK_NON_CONTINUOUS` parks the clock lane in low power during every
blanking interval, which gates the DSI link once per frame.  That gating is what
was audible: measured on the 2.4-4 kHz envelope of a 60 s capture, the capture
had 4.45 interference bursts per second with 22 gaps of exactly one second; after
removing the flag it has 0.10 bursts per second, the 3.5-4 kHz band drops from
10.4 % to 3.2 % of the energy, and the spectral autocorrelation at 120 Hz falls
from 0.023 to 0.003.

The vendor configuration for this panel does the same thing in effect: it uses
burst mode with `bllp-power-mode`/`bllp-eof-power-mode`, i.e. it parks the *data*
lanes during blanking and leaves the clock alone.

What is left after the fix is a burst per *screen update* rather than per frame:
with the output disabled the count drops from 18 bursts in 8 s to 3, and anything
that repaints once per second (a clock with seconds, the text console) shows up as
a 1 Hz periodicity in the envelope.  That residual is the hardware coupling - the
DSI burst radiations reaching the microphone preamp - and the only cures are
shielding, or not updating the screen; the band-pass in
`scripts/pipewire/50-mic-band.conf` hides its high-frequency part if the band-pass
is acceptable for the application.
