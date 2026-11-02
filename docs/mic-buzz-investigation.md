# The microphone "hiss": what it is, measured

The capture has two different problems, and it took a while to separate them.

## 1. Fixed: the DSI clock lane gated the link every frame

`MIPI_DSI_CLOCK_NON_CONTINUOUS` parks the DSI clock lane in low power during every
blanking interval, i.e. it gates the link once per frame.  On this board that
gating couples into the microphone preamp: with the flag the capture had 4.45
interference bursts per second and 22 gaps of exactly one second in 60 s; without
it, 0.10 bursts per second and the 3.5-4 kHz band drops from 10.4 % to 3.2 % of
the energy.  The vendor configuration parks only the data lanes
(`bllp-power-mode`), and the change was later reverted at the user's request while
the rest of the investigation continued.

## 2. The residual buzz is a light-load artefact, gated by a regulator

Measured as the 2-4 kHz band energy of a 6 s capture (case fitted, same position,
`DEC0/DEC1 MODE = ADC_HIGH_PERF`, capture gain 0 dB unless stated):

| state | rms | 2-4 kHz | peak |
|---|---|---|---|
| static desktop | 214 | 75.2 dB | 1819 Hz |
| video decoding, not displayed (`--vo=null`) | 214 | 75.6 dB | 2402 Hz |
| video displayed, GPU rendering, fullscreen | 216 | **87.1 dB** | **3724 Hz** |
| video displayed in a 64x64 window | 240 | 89.2 dB | 3724 Hz |
| video, direct scanout (`--vo=dmabuf-wayland`) | 243 | 87.8 dB | 3844 Hz |
| video at a 440x274 resolution, scaled up | 223 | 87.4 dB | 3844 Hz |
| video at 60 Hz instead of 120 Hz | 219 | 84.4 dB | 3844 Hz |
| **video + 2 cores stressed** | 181 | **73.9 dB** | 2402 Hz |
| static desktop + 2 cores stressed | 190 | 71.7 dB | 1813 Hz |

What that says:

* decoding alone, GPU load, window size, framebuffer resolution and refresh rate
  are all irrelevant; only **the screen actually updating** raises the buzz by
  12-14 dB, at ~3.7 kHz;
* **stressing two cores removes it**, during video playback too (13 dB, the 3.7
  kHz peak disappears) - so the regulator's light-load mode is the gate, the
  display's per-frame current steps are the excitation;
* a **timer interrupt storm** (14 253 arch_timer interrupts/s created from
  userspace) *lowers* the buzz, like any other load, so timer rate is not the
  excitation;
* removing the **plastic case** removes almost all of it: the case has a cavity
  in front of the microphone that amplifies the sound.  The source is mechanical.

Interrupt rates for reference (all CPUs): static 119/s, decode-only 936/s,
video displayed 1917/s; the GPU IRQ goes from 0 to 147/s.  Neither scales with the
buzz.

## What cannot be changed from Linux

The CPU/CX/MX/GFX rails are voted through RPMh (`qcom,rpmh-arc-regulator` in the
vendor tree), which mainline does not implement, and the main PMICs on this
platform are not owned by the Linux SPMI stack, so their registers cannot even be
read.  There is no mode/PFM knob to force PWM from userspace; the only lever is
current draw.

## Practical outcome

* keeping one or two little cores busy makes the capture usable (that is the
  `quiet-mic` service idea, at the cost of ~1 W);
* the case cavity is the amplifier: a different case, or filling the cavity, fixes
  the audibility without any power cost;
* the notch/band-pass filters in this repository hide the rest, and the
  vendor-matching band-pass is `scripts/pipewire/50-mic-band.conf`.

## Why Android is quiet: it is never idle

The PMIC modes cannot be read from either system (Android exposes only an address
map under `/sys/kernel/debug/spmi0`, mainline exposes nothing), so the comparison
had to be indirect.  Android's own numbers settle it:

```
800%cpu  59%user  7%nice  44%sys  678%idle     -> ~1.2 cores busy, all the time
loadavg 7.70
```

A sustained ~1.2 cores of load is exactly the condition measured on mainline that
forces the regulator into PWM and drops the buzz from 87.0 dB to 74.7 dB.  So the
difference is not a wrong setting in mainline - mainline simply idles much deeper
than Android does (loadavg 0.1-1 against 7.7), the PMIC falls into PFM, and the
display's per-frame current steps are then translated into the ~3.7 kHz tone.

The load ladder with the video playing confirms that it is a threshold, not a
gradient:

| CPU load (video playing) | 2-4 kHz band |
|---|---|
| 0 % | 87.8 dB |
| 25 % of one core | 87.2 dB |
| 50 % of one core | 87.0 dB |
| 100 % of one core | **74.7 dB** |
| two cores | 74.9 dB |

25 % and 50 % change nothing; one saturated core is enough.  That is the
regulator crossing from PFM into PWM, which is also what Android's background load
keeps it in.

## Correction: it is not "Linux idles too deeply"

A recording captured on the stock firmware with the screen off (Dozing, CPU 99.3 %
idle, loadavg 9 of which almost all is D state, big cluster at its minimum
frequency) measures 19 rms, 51-54 dB in the 2-4 kHz band, and a peak at ~1.9 kHz:
there is no 3.7 kHz component at all.  Android is quiet while almost completely
idle, so the earlier "Android never idles, mainline idles too deeply" reading is
wrong - the difference is in the regulators' operating mode itself.

That mode cannot be read or set from either userspace: the PMIC registers are not
reachable (Android exposes only an address map under `/sys/kernel/debug/spmi0`,
mainline exposes nothing) and the CPU/CX/MX/GFX rails are voted through
`qcom,rpmh-arc-regulator`, which mainline does not implement.  Keeping a core busy
therefore stays a workaround (it pushes the regulator out of PFM), not a fix.

## Tried and rejected: forbidding low power mode on the mic bias rail

The vendor's codec device tree forbids LPM on the microphone bias supply
(`cdc-vdd-mic-bias ... lpm 0` in the stock dmesg) while allowing it on the codec's
other supplies, so `regulator-allowed-modes = <RPMH_REGULATOR_MODE_HPM>` was added
to `vreg_bob1`.  Measured over three repeats of 6 s each, with the change active:

| state | 2-4 kHz band (three runs) | median | before |
|---|---|---|---|
| idle | 77.5 / 77.3 / 79.7 dB | 77.5 | 75.2 dB |
| video | 82.0 / 83.9 / 86.2 dB | 83.9 | 87.1 dB |

The spread between repeats is 4 dB, so the ~3 dB apparent improvement on video is
not measurable.  The change is kept because it matches the vendor's constraint,
but it does not fix the buzz.  With variance this size, any further A/B needs
either many more repeats or a much louder stimulus.
