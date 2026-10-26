# SPDX-License-Identifier: BSD-3-Clause
# Zhiyu TB378FC topology with the container/subgraph properties taken from the
# GRAPH_OPEN payload captured out of the stock Android HAL:
#   subgraph : perf_mode=2, direction=2, scenario=0xffffffff
#   container: capability=0x0b001001, graph_pos=4 (GLOBAL_DEV), stack=0x1000,
#              proc_domain=2, heap_id=1, parent=0xffffffff
include(`audioreach/audioreach.m4')
include(`audioreach/stream-subgraph.m4')
include(`audioreach/device-subgraph.m4')
include(`util/route.m4')
include(`util/mixer.m4')
include(`audioreach/tokens.m4')

define(`TDM_SYNC_SRC', `1') dnl
define(`TDM_DATA_OUT_ENABLE', `1') dnl
define(`TDM_SLOT_MASK', `0xF') dnl
define(`TDM_NSLOTS', `4') dnl
define(`TDM_SLOT_WIDTH', `32') dnl
define(`TDM_SYNC_MODE', `0') dnl
define(`TDM_INVERT_SYNC', `0') dnl
dnl AW882XX 4PA TDM reference config uses 1 BCK cycle of data delay and
dnl short-sync-bit mode; the PA's ACF is tuned for exactly that.
dnl The AW882xx ACF sets I2SCTRL1.I2SMD = 1 (MSB justified): the MSB is
dnl valid on the first BCK of the frame, i.e. no data delay.
define(`TDM_DATA_DELAY', `0') dnl
dnl The four AW882xx PAs hang off the second TDM data line (gpio124 / SD1).
dnl Driving SD0 leaves the clock running but no data reaches the amps, and
dnl enabling both lanes makes GRAPH_START fail on this firmware.
define(`TDM_ACTIVE_LANE', `2') dnl

dnl Stream sub-graph carries the AudioReach volume module so the mixer control
dnl maps to PARAM_ID_VOL_CTRL_MASTER_GAIN in the DSP (Android's stream volume).
STREAM_SG_PCM_ADD(piano/subgraph-stream-vol-playback.m4, FRONTEND_DAI_MULTIMEDIA1,
    `S32_LE', 48000, 48000, 1, 4,
    0x00004001, 0x00004001, 0x00006001, `110000')

dnl Single-graph layout: the device sub-graph (a STREAM-position container, as in
dnl upstream linux-msm) joins the frontend graph, which is what the vendor ADSP
dnl expects - one GRAPH_OPEN/GRAPH_START covering stream + device.
define(`FORCE_DEVICE_GRAPH_ID', `0') dnl
DEVICE_SG_ADD(piano/subgraph-device-tdm-playback.m4, `Secondary TDM0', SECONDARY_TDM_RX_0,
    `S32_LE', 48000, 48000, 4, 4,
    LPAIF_INTF_TYPE_LPAIF, 1, 0, DATA_FORMAT_FIXED_POINT,
    0x00004005, 0x00004005, 0x00006050, `SECONDARY_TDM_RX_0')

STREAM_DEVICE_PLAYBACK_MIXER(SECONDARY_TDM_RX_0, ``SECONDARY_TDM_RX_0'', ``MultiMedia1'')
STREAM_DEVICE_PLAYBACK_ROUTE(SECONDARY_TDM_RX_0, ``SECONDARY_TDM_RX_0 Audio Mixer'', ``MultiMedia1, stream0.logger1'')
