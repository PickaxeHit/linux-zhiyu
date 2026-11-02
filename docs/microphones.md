# Built-in microphones on the Lenovo TB378FC (zhiyu)

Status: **the DMIC path pursued first is not this board's signal path**.  The
built-in microphones are *analog* mics inside the WCD939x codec, captured over
SoundWire through the TX macro; the LPI DMIC pins are not used here.

## The microphones are analog mics on the WCD939x

The reference port for this exact device (`linux/progt13-ubuntu` in this
workspace) has verified capture with real acoustic evidence, and its UCM
fragment (`port/audio/Mic75.conf`) shows the whole chain:

```
TX0 MODE   = ADC_LP          TX2 MODE   = ADC_LP
ADC1 MUX   = CH1_AMIC1       ADC3 MUX   = CH3_AMIC4      <- analog mics
ADC1 Switch / ADC1_MIXER Switch = 1
TX DEC0 MUX = SWR_MIC        TX DEC1 MUX = SWR_MIC       <- arrives over SoundWire
TX SMIC MUX0 = SWR_MIC4      TX SMIC MUX1 = SWR_MIC8
TX_AIF1_CAP Mixer DEC0/DEC1 = 1
MultiMedia3 Mixer TX_CODEC_DMA_TX_3 = 1                  <- same backend as ours
```

So the data path is:

```
AMIC1 / AMIC4 -> WCD939x ADC -> SoundWire TX (SWR_MIC4 / SWR_MIC8)
              -> TX macro SMIC -> DEC0/DEC1 -> TX AIF1 -> TX_CODEC_DMA_TX_3
```

The DMIC pin groups in the reference board DT (`dmic01-default-state`,
`dmic23-default-state`, LPI gpio6..gpio9) are defined but **never referenced**
by any node - dead boilerplate inherited from the vendor DT.  The
`dmic3`/`va-mic-*` entries in `mixer_paths_sun_mtp.xml` come from a SKU-wide
file and do not describe this board's routing.

## Blueprint from the reference project

Board DT (`kernel/board/sm8750-lenovo-tb378fc-final.dts`):

* `soundwire@7630000` - LPASS **TX** SoundWire master: `label = "TX"`,
  `qcom,din-ports = <4>`, `qcom,dout-ports = <0>`, the `qcom,ports-*` tables,
  and a child `codec@0,3` with `compatible = "sdw20217010e00"` and
  `qcom,tx-port-mapping = <3 4 3 4>`.  Pinctrl `tx-swr-active-state`: LPI
  gpio0 = `swr_tx_clk`, gpio1/gpio2/gpio14 = `swr_tx_data`.
* `soundwire@6ad0000` - LPASS **RX** SoundWire master (`label = "RX"`),
  `qcom,din-ports = <1>`, `qcom,dout-ports = <11>`, child `codec@0,4` with
  `qcom,rx-port-mapping = <1 2 3 4 5 9>`.
* `tb378fc-wcd939x` - codec: `compatible = "qcom,wcd9390-codec"`,
  `qcom,tx-device`/`qcom,rx-device` pointing at the two SDW slaves,
  micbias1..4 = 1.8 V, `vdd-mic-bias-supply = <&vreg_bob1>`,
  `vdd-rxtx/vdd-buck/vdd-px/vdd-io-supply = <&vreg_l15b_usb_repeater>`,
  `reset-gpios` = TLMM gpio 101 active low with pinctrl state
  `tb378fc-wcd-reset71-state`.
* `sound/wcd-capture-dai-link`: `link-name = "WCD Capture"`,
  `convert-sample-format = "s16_le"`, `convert-channels = <2>`,
  `convert-rate = <48000>`; CPU DAI `q6apm-lpass-dais` index **120**
  (`TX_CODEC_DMA_TX_3`); codecs = wcd939x codec (DAI 1) + TX SDW slave +
  TX SoundWire master; platform = the `q6apm` bedais.

Driver side: `sound/soc/codecs/wcd939x-sdw.c` needs the board TX channel map
(`snapshots/patches/wcd939x-native-adc-map.patch` in the reference project):
ADC1/2 on `WCD939X_ADC_1_4_PORT` bits 0/1, ADC3/4 on
`WCD939X_ADC_DMIC_1_2_PORT` bits 0/1, plus `m_port_map[] = {.., 3, 4, 3, 4}`
so that `SWRM_TX2_CH1 -> master DP3 -> SWR_MIC4` and
`SWRM_TX3_CH1 -> master DP4 -> SWR_MIC8`.  The reference's
`live-microphone-capture71.c` shows the capture DAI links can be added to a
live DT instead of requiring a reboot.

Userspace: apply the `Mic75.conf` mixer values before capturing.

## Why the DMIC work was a dead end (kept for the record)

The vendor Android configuration (`vendtmp/vroot/etc/audio/sku_sun/`) maps
`PAL_DEVICE_IN_HANDSET_MIC` to `CODEC_DMA-LPAIF_RXTX-TX-3`, and its
`snd_device_name` leads to the `handset-mic` mixer path, which selects
`TX_AIF1_CAP Mixer DEC2` with `TX DMIC MUX2 = DMIC2`.  Following that lead we
built a complete TX-macro DMIC capture path (topology, machine driver, DSP
graph) and established several things that remain valid:

* the DSP accepts a codec-DMA capture graph only with **S16_LE**; with S32_LE
  `APM_CMD_GRAPH_START` is refused with `0x01001002` status 1;
* the LPASS bedais OF node - not the `q6apm-lpass-dais` name - has to be handed
  to the DPCM backend link, otherwise the card defers forever;
* every read-done carries `size 0`, i.e. the LPAIF produces no frames at all,
  which is exactly what an unclocked DMIC decimator looks like.

That last observation is what proved the path wrong: the mics are not DMICs, so
no DMIC clock register work could ever produce frames.  Reverse engineering of
the vendor modules (`lpass_cdc_tx_macro_dlkm.ko`, `lpass_cdc_dlkm.ko`) located
the DMIC clock generator (`0x3084..0x3094`, decoded by `__lpass_cdc_reg_read()`
as `readl(base[reg >> 16] + (reg & 0xffff))`, i.e. VA-macro registers
`0x84..0x94`) - consistent with the DMIC clock being a VA-macro feature this
board never uses.

## Implementation status (Linux side is done)

The capture path is now fully implemented in this tree and verified end to end
on the Linux side:

* DT: `audio-codec` (`qcom,wcd9390-codec`, five supplies, reset GPIO 101,
  1.8 V mic bias, MBHC thresholds), the two SoundWire masters with their
  `sdw20217010e00` slaves (`qcom,tx-port-mapping = <3 4 3 4>`), and a `bob1`
  regulator in the PM8550 set that provides `vreg_bob1`.
* machine driver: "WCD Capture" link (CPU `TX_CODEC_DMA_TX_3`, codecs = the
  codec, the TX SoundWire master and the TX macro), the SoundWire stream
  helpers (`qcom_snd_sdw_startup/prepare/hw_free/shutdown`, indexed by the CPU
  DAI id - `TX_CODEC_DMA_TX_3` is 120, so the table must span the whole id
  space) and the DAPM routes `AMIC1<-MIC BIAS1`, `AMIC4<-MIC BIAS4`,
  `TX SWR_INPUT4<-ADC1_OUTPUT`, `TX SWR_INPUT8<-ADC3_OUTPUT`.
* initramfs: `soundwire-bus/qcom`, `regmap-sdw`, the WCD939x codecs, the RX
  macro and `snd-soc-qcom-sdw` load in the audio group in dependency order.

Verified on the device: card plus `MultiMedia1 Playback` and `MultiMedia3
Capture` at boot, both SoundWire slaves `Attached`, `vreg_bob1` enabled at
3032 mV, codec registers readable over SoundWire, and during a capture the
whole DAPM chain is on (`ADC1`, `AMIC1`, `MIC BIAS1`, `TX SWR_INPUT4`,
`TX_AIF1 CAP`).  The machine driver's prepare hook runs and reports the
SoundWire stream as prepared, i.e. `sdw_prepare_stream()` and
`sdw_enable_stream()` did run.

## The reference port's capture path, decoded

`linux/progt13-ubuntu` reaches the microphones with the same AudioReach device
sub-graph (`TX_CODEC_DMA_TX_3`, `S16_LE`, `LPAIF_INTF_TYPE_RXTX`,
`CODEC_INTF_IDX_TX3`, iids `0x4008/0x4008/0x6080`), so the topology was not
the difference.  Its board data and its code patches are:

* **Channel layout** (`snapshots/patches/wcd939x-native-adc-map.patch`).  The
  stock device tree describes the codec's TX ports with
  `qcom,tx_swr_ch_map`; decoding the runtime FDT dump
  (`dts/stock-runtime-fdt.dts`, 5 cells per channel: slave port, channel id,
  channel mask, 0, hw port) gives

  | channel | slave data port (0-based) | mask |
  |---|---|---|
  | ADC1, ADC2 | 0 (`WCD939X_ADC_1_4_PORT`) | 0x1, 0x2 |
  | ADC3, ADC4 | 1 (`WCD939X_ADC_DMIC_1_2_PORT`) | 0x1, 0x2 |
  | DMIC0, DMIC1, MBHC, DMIC2, DMIC3 | 2 | 0x1, 0x2, 0x4, 0x4, 0x8 |
  | DMIC4..DMIC7 | 3 | 0x1, 0x2, 0x4, 0x8 |

  So ADC3 does **not** sit on channels 2/3 of the first port, which is what
  mainline's `wcd939x_sdw_tx_ch_info` assumes.  Our tree now reads that layout
  from `qcom,tx-ch-map` instead of hard-coding it.
* **Decoder packing.** The ADSP's codec-DMA configuration takes mask `0b11`,
  i.e. decimators 0 and 1 only.  The reference therefore repacks the native
  ADC1/ADC3 -> `SWR_MIC4`/`SWR_MIC8` wiring into `DEC0`/`DEC1`
  (`Mic75.conf`), which is what our machine driver does.
* **SoundWire master port timing.** Upstream's MTP defaults
  (`offset1 = 0 0 1 1`, `lane-control = 1 2 0 0`) do not match this board.
  The working board values are `offset1 = 0 0 0 2` with
  `lane-control = 1 2 1 0`, i.e. the first ADC port is received at lane 1 /
  offset 0 and the second at lane 0 / offset 2.  The reference first proved
  this with a runtime module (`port/swr-timing75.c`, which asserts the running
  values were `off1 = 1` for both ports) and then put it into the board DTS.
* **Mic bias.** The reference routes `AMIC4 -> MIC BIAS3`, but the stock FDT
  routes `AMIC4 -> MIC BIAS4`, and stock wins; our routing is unchanged.
* Everything else it does (vendor-style machine driver with a `convert` DAI,
  runtime DT overlay, UCM) is architecture, not hardware.

Because the controller only exposes four data ports and the allocator used to
reject port 4, the two ADC streams are carried on master DP3 and DP2 here
(identical lane/offset pairs), and `drivers/soundwire/qcom.c` now accepts the
last port for future use.

## Remaining problem: the DSP delivers no frames

Everything on the Linux side is now verified end to end, during a capture:

| stage | evidence |
|---|---|
| PCM | `hw_params` succeeds, period 40..340 ms, S16_LE 2ch |
| SWR stream | master ports allocated, `sdw_prepare_stream`/`enable` run |
| DAPM (measured 0.35 s into a capture, before ALSA's timeout) | `ADC1`, `ADC3`, `AMIC1`, `AMIC4`, `MIC BIAS1`, `MIC BIAS4`, `TX SWR_INPUT4`, `TX SWR_INPUT8`, `TX_AIF1 CAP`, `TX_CODEC_DMA_TX_3 Capture` all **On** |
| graphs | `graph_open id=120 -> found`, `graph_open id=2 -> found`, both `ar-graph-start ... ret 0` |
| modules | device graph = `CODEC_DMA_SOURCE 0x7001024` + `DATA_LOGGING 0x700101a`; stream graph = `RD_SHARED_MEM_EP`, `PCM_CNV`, `PCM_ENC`, `MFC`, `DATA_LOGGING` |
| DSP data | `ar-rd: graph 2 token 0..3 st 0 size 0 off 0` |

ALSA then reports `pcm_read: read error: Input/output error`, which is
`sound/core/pcm_lib.c:wait_for_avail()` timing out - i.e. the same "no data"
seen as `size 0`, not a separate fault.

So the LPAIF RXTX-TX3 interface produces nothing.  Ruled out this round:
`bit_width` mismatch (the FE was telling the DSP 32 bit for an S16_LE graph -
fixed, no change), decoder packing, channel map, master port timing, DAPM.

## What the hardware itself says during a capture

Power, reset and clocks were verified to be fine: `vreg_l15b_1p8` at 1800 mV
(5 users), `vreg_l2i_1p2` at 1200 mV, `vreg_bob1` at 3032 mV with all five
`audio-codec-vdd-*` consumers registered, codec reset TLMM gpio101 `out high`
(deasserted), and `LPASS_HW_DCODEC`, `LPASS_HW_MACRO`, `LPASS_CLK_ID_TX_CORE_MCLK`
(19.2 MHz), `fsgen` (19.2 MHz) and `lpass-tx-mclk` (9.6 MHz) all enabled.

The SoundWire master is programmed the way the board needs, read back from its
registers during a capture:

| register | value | meaning |
|---|---|---|
| `0x1324` (DP3 port ctrl) | `0x03000003` | offset1 = 0, sample interval 3 |
| `0x1328` (DP3 lane ctrl) | `0x01` | lane 1 |
| `0x1224` (DP2 port ctrl) | `0x03000203` | offset1 = 2, sample interval 3 |
| `0x1228` (DP2 lane ctrl) | `0x00` | lane 0 |

and the codec reports `hw_params dir 1 (capture) ch 4, bps 1, rate 48000,
ports 2`, i.e. two channels on each of its two TX data ports.

**The bus clock does not appear to run, though.** Sampling the pads through
`/sys/kernel/debug/gpio` while a stream is open (validated against a known
good bus in the same boot: the TDM bit clock on TLMM gpio121 reads 39 low /
41 high during a silent playback) gives:

| pad | idle | capture |
|---|---|---|
| LPI gpio0 `swr_tx_clk` | statically high | statically high |
| LPI gpio1/2/14 `swr_tx_data` | statically high | statically high |

while the master's own registers claim the opposite - `SWRM_V2_0_CLK_CTRL`
(0x5060) reads `0x01` and `SWRM_V2_0_LINK_STATUS` (0x5064) reads `0x2081`
(framegen enabled) in both states, the frame shape is programmed (`0x101c` =
`0x0f` for 16 columns x 50 rows), and `runtime_status` of the master and both
slaves is `active` during the capture.  The two readings disagree, so either
the LPI pad read is not live for function-muxed pins (adding `input-enable`
did not change it; it has been reverted) or the LPASS gates the SWR clock
outside the master's register file.

The DSP timeline of one capture is now unambiguous:

```
zy-wcd: hw_params dir 1 ch 4 bps 1 rate 48000 ports 2 tx
ar-graph-start: graph 2 ret 0
ar-graph-start: graph 120 ret 0
   ... 590 ms of nothing ...
ar-rd: graph 2 token 0..3 st 0 size 0 off 0
```

The read responses only arrive when ALSA has already given up (its capture
read timeout is `buffer_size * 1100 / rate`, 570 ms for a 4 x 6240 frame
buffer), which is also where `pcm_read: Input/output error` comes from
(`wait_for_avail()` timing out).  So the codec-DMA never fills a period.

Also fixed on the way: `wcd939x_sdw_hw_params()` counted one channel too many
(it started at 1 and added one per enabled bit), so a two-port stream told the
SoundWire core it had five channels; it now reports four.

## The LPAIF interface clock vote, and what is still missing

The working speaker path explains itself in the machine driver: the TDM
backend only puts clocks and data on the pins - and the DSP only starts the
backend sub-graph - after the application processor votes the LPAIF interface
clock through PRM:

```c
bclk = params_rate(params) * SM8750_TDM_SLOTS * SM8750_TDM_SLOT_WIDTH;
snd_soc_dai_set_sysclk(cpu_dai, LPAIF_MI2S_BCLK, bclk, SND_SOC_CLOCK_IN);
```

with the clock itself coming from the device tree, one child per backend DAI:

```
bedais {
	dai@28 { reg = <40>; clocks = <&q6prmcc LPASS_CLK_ID_SEC_TDM_IBIT ...>; clock-names = "bclk"; };
};
```

None of that existed for the codec-DMA backends: `q6dma_ops` had no
`set_sysclk`, `of_q6apm_parse_dai_data()` skipped their ids, the capture link
never voted anything, and there was no clock on the node.  That is now wired
up (BE DAI clock parsing for every id that declares one, `set_sysclk` on the
codec-DMA ops, and a vote from the capture `hw_params`).

Measured on the device, the vote currently does nothing:

```
ar-clk: set_sysclk dai_id=120 clk_id=2 freq=1536000 sysclk=NULL
```

because the clock referenced by the new `dai@120` node is the LPASS internal
digital codec core clock, and `q6prm-clocks.c` does not expose it.  Exposing it
needs the ADSP-side clock id (`Q6PRM_LPASS_CLK_ID_*`); the header's numbering is
not derivable (TDM group 0x200.., MCLK group 0x305..0x318 with gaps at
0x309..0x30b), so it has to come from vendor plumbing rather than a guess.
Until then the codec-DMA backend keeps returning `size 0`.

## How the reference port actually wires capture (pinned source)

`linux/progt13-ubuntu` pins kernel `yzddmr6/linux-sm8750-erhai` @ `958a2b46`,
a mainline 7.2 fork.  Its audio stack is plain mainline plus the board patch,
and the board patch only touches `q6apm`/`q6apm-dai` for SPF readiness
(`q6apm_is_adsp_ready()` gating and logging) - no audio clock code at all,
and its `microphone.config` only enables the WCD939x, WCD-classh/MBHC, the
three macros and the SoundWire bus as modules.

The capture link in its board DT is the interesting part:

```
wcd-capture-dai-link {
	convert-rate = <48000>;
	convert-channels = <2>;
	convert-sample-format = "s16_le";
	cpu      { sound-dai = <&bedais 120>; };        /* TX_CODEC_DMA_TX_3 */
	codec    { sound-dai = <&wcd939x 1>, <&swr_tx 0>, <&tx_macro 0>; };
	platform { sound-dai = <&q6apm>; };             /* the APM service node */
};
```

and its machine driver is mainline's **sm8450** one (in `sc8280xp.c`), which
builds links from DT (`qcom_snd_parse_of()`): a link with codecs and a
`platform` child becomes a DPCM backend and gets

* `be_hw_params_fixup = sc8280xp_be_hw_params_fixup()`, which pins the backend
  to 48000 Hz / S16_LE / 2 channels (1 channel minimum for `TX_CODEC_DMA_TX_*`)
  and then applies the `convert-*` properties,
* `ops` with `qcom_snd_sdw_startup/shutdown/prepare/hw_free` plus a
  `hw_params` that only acts on MI2S/TDM ids,
* `init = sc8280xp_snd_init()`.

So the reference does **not** vote a codec-DMA clock either (its
`q6apm-lpass-dais.c` has the `set_sysclk` plumbing for codec-DMA ids, but the
sm8450 machine driver only calls it for MI2S/TDM).  Two things differ from this
port instead:

1. the capture link's platform is the **`q6apm` APM service node**, not
   `q6apm-lpass-dais`, so the PCM that owns the shared-memory endpoint and the
   codec-DMA DAI are driven by the same component;
2. the capture backend gets an explicit format fixup (S16_LE, 2 channels,
   48 kHz) instead of inheriting the frontend's parameters.

That is the next thing to reproduce here: either give this port's capture
backend the same format fixup, or drop the separate frontend and declare the
capture PCM as one link with `TX_CODEC_DMA_TX_3` as CPU DAI and `q6apm-dai` as
platform (this port previously tried a "single graph" variant and reverted it,
but without these two details).

### Reproducing the reference's link shape: both attempts negative

Two of the reference's differences were cheap enough to try directly:

1. **Backend format fixup** - pin the capture backend to 48000 Hz / S16_LE /
   2 channels instead of inheriting the frontend's parameters
   (`sm8750_capture_be_fixup()`, matching `sc8280xp_be_hw_params_fixup()`).
   Deployed and measured: identical trace, still `size 0`.
2. **Platform = the APM service node** - bind the capture backend's platform to
   `/soc@0/remoteproc@6800000/glink-edge/gpr/service@1` (what the reference's DT
   points at) rather than the `bedais` node.  Card still probes, capture still
   returns `size 0`, so for a `no_pcm` backend this choice makes no difference.

Since the reference's stack has no audio clock code at all, the remaining
difference has to be in the graph/link details rather than in a missing clock
vote.  The most direct way to find it is the same one that produced this
port's playback payload: capture the stock HAL's `GRAPH_OPEN` payload for the
**capture** device graph with the same instrumentation `q6apm.c` already
carries for playback (`dump_gpr_rsp`, `vendor_replay`,
`vendor_dev_graph_payload`) and compare its module list and parameters with
what the topology here emits.  The two stock topology blobs on disk only carry
the TDM playback device graph, so this has to come from the vendor HAL at
runtime.

## The vendor's own capture graph, from ACDB (no frida needed)

The stock calibration database is on disk
(`stock-dump/vendor/etc/acdbdata/sun_qrd_sku2/QRD_sun_sku2_acdb_cal.acdb`) and
the older port left a working decoder for it
(`linux/incoming/acdb-tools/acdb-src/acdb_decode.py`, which also documents the
ACDB chunk layout and the GKV lookup chain).  In AudioReach the ACDB holds the
*graph description* (subgraphs, containers, module lists, connections) while
the topology carries the module parameters, so the ACDB is the authoritative
description of what the vendor DSP runs.

The internal microphones are the graph key `7 DeviceTX_Speaker_Mic`
(subgraph `0xb0000003`):

```
SG 0xb0000003  perf 0x2, direction TX, scenario 0xffffffff
CONT 0xe0000003  type 0x1, graph pos 0x4, stack 0x800, proc domain 0x2
MOD 0x0700101a DATA_LOGGING        iid 0x400a  ports 1 -> 1
MOD 0x07001011 SPLITTER            iid 0x4168  ports 1 -> 23
MOD 0x07001024 CODEC_DMA_SOURCE    iid 0x43ad  ports 0 -> 1
CONN 0x43ad port 1 -> 0x400a port 2      (codec dma -> logger)
CONN 0x400a port 1 -> 0x4168 port 2      (logger -> splitter)
```

and the complete capture use case `25 DeviceTX_Speaker_Mic_StreamTX_RAW_Record`
adds the stream subgraph `0xb00000ce`:

```
CONT 0xe0000116, nmods 6: 0x07001003 (PCM_CNV), 0x07001004 (PCM_ENC),
                          0x0700101a (logger), 0x07001001 (RD_SHARED_MEM_EP),
                          0x0700101a (logger), 0x0700101b
CONT 0xe0000117, nmods 1: 0x07001015 (MFC)
CONN 0x4544->0x4545->0x4546->0x4547   (cnv -> enc -> logger -> rd ep)
CONN 0x4549->0x4548->0x4033->0x4544   (mfc -> logger -> 0x4033 -> cnv)
CONN 0x4168 port 0x17 -> 0x4549 port 0x2   (cross-graph: device splitter -> stream MFC)
```

Compared with what this port's topology emits for the same use case:

| item | vendor | this port |
|---|---|---|
| device subgraph | codec-DMA -> logger -> **splitter (1 in / 23 out)** | codec-DMA -> logger |
| cross-graph connection | splitter output **port 23** -> MFC input 2 | device logger -> stream mixer route |
| stream subgraph | 7 modules, MFC in its own container | 5 modules, no second logger, no `0x0700101b` |
| device container | stack 0x800 | stack 0x2000 |

The decoder can also emit the vendor's exact SPF graph-open payloads offline,
which is what an earlier round obtained from the vendor HAL with frida for
playback:

```sh
acdb_decode.py QRD_sun_sku2_acdb_cal.acdb 25 --bin out/ --driver
# -> out/g25.spf.bin (1152 B), out/g25.conn.bin (40 B), out/g25.driver.txt
```

So the next topology step is to reproduce the splitter in the device subgraph
and connect its output port 23 to the stream graph's MFC, matching the vendor
description above.

### The device sub-graph now matches the vendor's structure (still size 0)

The splitter from the ACDB description is in the topology now
(`piano/module_splitter.m4`, module `0x07001011`, one input, one output; the
vendor's 23 outputs exist because one device sub-graph serves every capture use
case, while ours belongs to a single one).  The graph-open payload reads:

```
ar-conn: 0x6080:1 -> 0x6081:2 (mid 0x7001024)    codec-DMA -> logger
ar-conn: 0x6081:1 -> 0x6082:2 (mid 0x700101a)    logger    -> splitter
ar-conn: 0x6020:1 -> 0x6021:2 (mid 0x700101a)    stream: logger -> MFC
ar-conn: 0x6021:1 -> 0x6022:2 (mid 0x7001015)    MFC -> PCM converter
ar-conn: 0x6022:1 -> 0x6023:2 (mid 0x7001003)    converter -> PCM encoder
ar-conn: 0x6023:1 -> 0x6024:2 (mid 0x7001004)    encoder -> read endpoint
```

which is the vendor's chain, and both graphs still start with `ret 0`, but the
codec-DMA backend keeps returning `size 0`.

**A stale copy of the topology on the root file system was shadowing every
initramfs update**: `/lib/firmware/qcom/sm8750/sm8750-tplg.bin` there dated from
an earlier experiment and is what the card actually loaded, so the splitter
never appeared until that copy was replaced.  Any topology change has to be
installed in both places (the deploy helper now does this) - earlier topology
experiments in this document may therefore have run with an older topology
than intended.

The init script also enables the topology/q6apm/audioreach parser traces right
after `snd-q6apm` loads, because those parsers run at card probe and only log
at debug level.

### ACDB calibration, and what was tried with it

The ACDB decoder only reproduces the graph description, so the vendor's module
calibration was pulled out of the raw table chunks by hand.  The chunks are
`MTKT` (tag data key table: `u32 count`, then `{subgraph_id, tag_id, offset}`),
`MTLU` (per-tag key/entry table, entries `{keys..., def_offset, dot_offset}`),
`MTDE` (definitions: `u32 n`, then `{module_iid, param_id}` per parameter) and
`MTDO`/`POOL` (payload offsets and bytes).

For the microphone device sub-graph (`0xb0000003`) there is exactly one tag
(`0xc0000005`) and it resolves to a single parameter for the codec-DMA module
(iid `0x43ad`):

```
param_id 0x08001063, param_size 12, payload {1, 4, mask}
mask: 0x04 (1 ch), 0x06 (2 ch), 0x0e (3 ch), 0x1e (4 ch)
```

which is the "which channels of the LPAIF interface does this stream carry"
parameter, and matches the "DMA mask" the reference port mentions.  Nothing in
the ALSA topology format can carry a module parameter (the q6apm parser only
knows structural tokens), so the tree gained a raw parameter sender
(`audioreach_send_raw_param()`) and a helper that finds the codec-DMA module
and sends `{1, 4, GENMASK(channels, 1)}` before the device graph starts.

Both of the remaining structural items from the vendor description were also
reproduced: the device sub-graph gets the source-first start order (the DSP
wants the source sub-graph running before the sink one, and DPCM prepares
backends before starting the frontend) and the splitter.

Measured after all of it: device graph starts first (`graph 120` then `graph
2`), the parameter is accepted, both graphs report `ret 0` - and the codec-DMA
backend still returns `size 0`, so neither the graph structure nor that
parameter is the blocker.

## Solved: both microphones capture

Two independent faults, both fixed.

### 1. The capture device sub-graph has to live in the frontend graph

The DSP accepted both graphs of the two-graph layout (frontend `graph 2`,
codec-DMA device sub-graph `graph 120`), started both with `ret 0`, and then
never produced a frame.  The reason is the cross-sub-graph connection: the
device sub-graph's `MODULE_CONN` list names the *stream* logger
(`0x6082:1 -> 0x6020:2`), and that module is part of the frontend graph, which
is opened later, so the DSP dropped the connection while opening the device
graph.  The vendor's own ACDB use case (graph key 25) is a single `GRAPH_OPEN`
payload that carries both sub-graphs - its cross-sub-graph connection
(`splitter 0x4168 port 0x17 -> MFC 0x4549 port 2`) then refers to a module in
the same graph.

The topology now sets `FORCE_DEVICE_GRAPH_ID` to the frontend DAI index
(`FRONTEND_DAI_MULTIMEDIA3`, i.e. 2), the same way the working TDM playback
device sub-graph joins the playback frontend graph (id 0), and the codec-DMA
backend only pushes its module configuration through that graph:

* `capture_be_graph_id` (new module parameter of `q6apm-lpass-dais`, `-1` keeps
  the old per-DAI graph) tells the backend which graph to configure; the init
  script sets it to `2` after loading the module.
* In that mode `q6apm_lpass_dai_prepare()` opens the shared graph (which is what
  sends `GRAPH_OPEN`, with both sub-graphs in the payload), sends
  `q6apm_graph_media_format_device()` - which is what carries
  `PARAM_ID_CODEC_DMA_INTF_CFG`, so the separate channel-mask helper is no
  longer needed on this path - and leaves `GRAPH_PREPARE`/`GRAPH_START` to the
  frontend.

Result: one `GRAPH_OPEN` of 864 bytes holding sub-graphs `0x4008` (codec DMA,
logger, splitter) and `0x4003` (logger, MFC, PCM converter, PCM encoder, read
endpoint), the connection `0x6082:1 -> 0x6020:2` inside it, and
`ar-rd: ... size 24960` on every period instead of `size 0`.

### 2. The codec's TX channel layout is one data port, four channels

With frames flowing, only one channel carried audio.  Scanning every SMIC input
(`TX SMIC MUX1` = `SWR_MIC0`..`SWR_MIC11`, analysed on fresh samples only)
showed a live signal on `SWR_MIC4` and digital zeros everywhere else, and
gating each ADC proved which ADC feeds which channel:

| ADC1 Switch | ADC3 Switch | ch0 (rms) | ch1 (rms) |
|---|---|---|---|
| on | on | 13.2 | 12.1 |
| **off** | on | 0.0 | 11.2 |
| on | **off** | 12.2 | 0.0 |

The previous device tree declared the vendor's runtime layout (ADC1/ADC2 on
codec data port 1, ADC3/ADC4 on port 2, taken from the stock `qcom,tx_swr_ch_map`
and the `ADCn ChMap` mixer controls).  That layout only exists after the
vendor's HAL programs `ADCn ChMap`; mainline never touches the codec's TX
channel map, so the codec keeps its reset map, which puts ADC1..ADC4 on **data
port 1 as channels 1..4**.  Declaring ADC3 on a second port therefore asked the
bus for channels the codec never sends, and that second port carried nothing.

The TX macro numbers its twelve SoundWire inputs four per data port, and the
first data port it can see is port 2 (`SWR_MIC0..3` = port 2, `SWR_MIC4..7` =
port 3, `SWR_MIC8..11` = port 4), so with the codec's port 1 on master DP3:

* ADC1 (channel 1) -> `SWR_MIC4`, DEC0
* ADC3 (channel 3) -> `SWR_MIC6`, DEC1

`qcom,tx-ch-map` now declares all four ADCs on port 1 with masks 1/2/4/8,
`qcom,tx-port-mapping` is `<3 4 3 4>`, the DAPM route for the second microphone
is `TX SWR_INPUT6 <- ADC3_OUTPUT`, and the machine driver pins
`TX SMIC MUX0 = SWR_MIC4`, `TX SMIC MUX1 = SWR_MIC6` and `TX0`/`TX1 MODE =
ADC_LP` (the old list still set `TX2 MODE`, which is a decimator this path does
not use).

Verified on a silent night: both channels show a live analog noise floor
(about -68 dBFS, ~90 distinct sample values per two seconds), each channel is
gated only by its own ADC, and `arecord -D hw:0,2 -f S16_LE -r 48000 -c 2`
completes normally.  Playback is unaffected.

### Verification method that actually works here

The two-graph capture wedged `arecord` in an uninterruptible wait, and a
one-second recording is mostly *stale* ring-buffer content, which is what made
earlier measurements confusing (`ch1` appearing to burst for a second and then
go to zero).  Only the tail of a >= 3 s capture reflects DSP output; every
measurement in this section uses the last two seconds.

### Desktop integration (ALSA UCM2)

PipeWire only builds a card profile from an ALSA UCM profile, and alsa-ucm
looks one up by the card **id**, which is `sm8750` here (`model` in the sound
node).  Without it the card has no profile and neither the speakers nor the
microphones reach the desktop.

The profile lives in the build repo under `scripts/alsa-ucm2/` and is installed
as `/usr/share/alsa/ucm2/conf.d/sm8750/sm8750.conf` plus
`/usr/share/alsa/ucm2/sm8750/HiFi.conf`.  It declares "Speakers" (`hw:0,0`,
4 channels) and "Mic" (`hw:0,2`, 2 channels, 48 kHz); the Mic EnableSequence
repeats the handful of controls that decide *which* microphones are recorded
(ADC1/ADC3 muxes and switches, `TX SMIC MUX0/1`, `TX DEC0/1 MUX`, decimator
gain, AIF1 capture mixers), so a client can restore its own state without
breaking the routing.

Verified on the device: `alsaucm -c hw:0 set _verb HiFi list _devices` reports
`Speaker` and `Mic`, `set _enadev Mic` applies the sequence (the muxes read back
`SWR_MIC4`/`SWR_MIC6`, `TX_DEC1 Volume` 102, `ADC3 MUX` CH3_AMIC4), and capture
still runs afterwards.

## Next steps
## What a clean boot looks like (no UCM, no saved mixer state)

Removing `/usr/share/alsa/ucm2/conf.d/sm8750/` and `/var/lib/alsa/asound.state`
and rebooting shows what the board does without any configuration:

| | clean boot | with our UCM |
|---|---|---|
| playback device | `Built-in Audio Stereo` (raw PCM) | `Speakers` |
| capture device | **none** | `Internal microphones (AMIC1 + AMIC4)` |
| `TX_DEC0/1 Volume` | 102 (+18 dB, driver default) | 84 (0 dB) |
| `ADC1 MUX` | AMIC5 (driver default) | AMIC1 |
| `arecord -D hw:0,2` | RMS 226, buzz at 223/286 Hz | RMS 24 |

So PipeWire does find the sound card and a playback PCM without UCM - that is
the ALSA fallback, and it is what makes it look as if nothing is needed.  What
is missing is the *capture* side: without a use case, PipeWire cannot tell which
PCM is a microphone nor which mixer state makes it work, so no source appears.
Direct ALSA capture still "works" in that state, but through the driver's
defaults: the decimator at +18 dB and ADC1 wired to AMIC5, which is exactly the
buzz the unconfigured board is known for.  The UCM is what names the devices and
puts the routing and gains right.

## The capture path has no I2S/TDM bit alignment to get wrong

The microphones reach the DSP over **SoundWire**: the WCD939x is an SDW codec
(`wcd939x-sdw.c`), its TX macro publishes the ADCs on the SoundWire data port,
and the AudioReach codec-DMA backend reads them.  SoundWire is a framed, clocked
bus with its own protocol - there is no separate bit clock and frame sync whose
edge could be picked wrongly, which is what `SND_SOC_DAIFMT_DSP_A` versus
`DSP_B` describes.

The speaker path is the one that has a TDM wire format, and both ends are set to
`DSP_B | IB_NF` for it in `sm8750_tdm_be_hw_params()` (with a plain `I2S` case for
`SECONDARY_MI2S_RX`), so the two sides agree.

That the capture alignment is right is also visible in the data: with `ADC1/ADC3
Switch` off the capture is *exactly* zero, the DC offset is under two counts, and
the two channels carry independent signals.  A misaligned frame sync would show
up as a shifted, doubled or halved sample stream, a large DC offset, or swapped
channels - none of which is the case.

The noise that is left is analogue: mains hum through the microphone bias and
board coupling, amplified by the +18 dB decimator gain.
