# SPDX-License-Identifier: BSD-3-Clause
# Stream playback sub-graph with a DSP volume-control module.
#
# Chain: [WR_SH] -> [PCM DEC] -> [PCM CONV] -> [VOL] -> [LOG] ---kcontrol---
#
# Based on linux-msm/audioreach-topology audioreach/subgraph-stream-vol-playback.m4
# (Copyright Linaro Ltd, 2023), reduced to the modules this board's stream
# sub-graph uses: the format converter (MFC) lives in the device sub-graph, so
# there is none here.  The WR_SH output port stays 1, matching the plain
# subgraph-stream-playback.m4 variant used before: with port 0 the piano
# firmware rejected APM_CMD_GRAPH_OPEN.
#
# The VOL module is what Android's AudioReach graphs use for the stream volume.
# It exposes a "MultiMediaN Playback Volume" mixer control that the kernel maps
# to PARAM_ID_VOL_CTRL_MASTER_GAIN in Q14 (0x4000 = 0 dB, 0x2000 = -6 dB), so
# userspace volume changes are applied in the DSP instead of the amplifier.
include(`audioreach/audioreach.m4') dnl
include(`util/pcm.m4') dnl
include(`audioreach/subgraph.m4') dnl
include(`audioreach/container.m4') dnl
include(`audioreach/module_wrsh.m4') dnl
include(`audioreach/module_pcmdec.m4') dnl
include(`audioreach/module_pcmcnv.m4') dnl
include(`audioreach/module_vol_ctrl.m4') dnl
include(`audioreach/module_log.m4') dnl
include(`util/mixer.m4') dnl

undefine(`PCM_PERF_MODE') dnl
undefine(`PCM_DIRECTION') dnl
undefine(`CONT_SENARIO_ID') dnl
undefine(`CONT_CAP') dnl
undefine(`CONT_POSITION') dnl
undefine(`PCM_DOMAIN_ID') dnl
undefine(`CONT_STACK_SIZE') dnl

define(`PCM_PERF_MODE', APM_SG_PERF_MODE_LOW_LATENCY) dnl'
define(`PCM_DIRECTION', APM_SUB_GRAPH_DIRECTION_RX) dnl'
define(`CONT_SENARIO_ID', APM_SUB_GRAPH_SID_AUDIO_PLAYBACK) dnl'
define(`CONT_CAP', `ifelse(LPASS_VER_COMPAT, 110000, APM_CONTAINER_TYPE_ID_GC, APM_CONTAINER_CAP_ID_CD)') dnl'
define(`CONT_POSITION', APM_CONT_GRAPH_POS_STREAM) dnl'
define(`PCM_DOMAIN_ID', ifdef(`AR_SELECTED_PROC_DOMAIN_ID', `AR_SELECTED_PROC_DOMAIN_ID', `APM_PROC_DOMAIN_ID_ADSP')) dnl'
define(`CONT_STACK_SIZE', 8192) dnl'

define(`WRSH_MODULE_IID', MOD_IID_START) dnl
define(`PCMDEC_MODULE_IID', eval(MOD_IID_START + 1)) dnl
define(`PCMCNV_MODULE_IID', eval(MOD_IID_START + 2)) dnl
define(`VOLCTRL_MODULE_IID', eval(MOD_IID_START + 3)) dnl
define(`LOG_MODULE_IID', eval(MOD_IID_START + 4)) dnl
define(`SG_INDEX', 1) dnl
define(`CONTAINER_INDEX', 1) dnl
define(`MOD_INDEX', 1) dnl

dnl STREAM_PLAYBACK_ROUTE(stream-index)
define(`STREAM_PLAYBACK_ROUTE',
`'
`SectionGraph."NAME_PREFIX.$1 Graph" {'
`        index STR($1)'
`        lines ['
`                "NAME_PREFIX.pcm_decoder$1, , NAME_PREFIX.wrsh_ep$1"'
`                "NAME_PREFIX.pcm_converter$1, , NAME_PREFIX.pcm_decoder$1"'
`                "NAME_PREFIX.vol_ctrl$1, , NAME_PREFIX.pcm_converter$1"'
`                "NAME_PREFIX.logger$1, , NAME_PREFIX.vol_ctrl$1"'
`        ]'
`}')

dnl
AR_PCM_PLAYBACK(PCM_DAI_ID, PCM_FORMAT, PCM_MIN_RATE, PCM_MAX_RATE, PCM_MIN_CHANNELS, PCM_MAX_CHANNELS)

AR_SUBGRAPH(SG_INDEX, PCM_DAI_ID, SG_IID_START, PCM_PERF_MODE, PCM_DIRECTION, CONT_SENARIO_ID)

AR_CONTAINER(CONTAINER_INDEX, CONT_IID_START, CONT_CAP, CONT_STACK_SIZE, APM_CONT_GRAPH_POS_STREAM, PCM_DOMAIN_ID)

AR_MODULE_WRSH(MOD_INDEX, SG_INDEX, CONTAINER_INDEX,	WRSH_MODULE_IID,  0, 1, 1, 2, PCM_DAI_ID, PCMDEC_MODULE_IID)
AR_MODULE_PCMDEC(MOD_INDEX, SG_INDEX, CONTAINER_INDEX,	PCMDEC_MODULE_IID, 1, 1, 1, 2, PCM_INTERLEAVED, PCMCNV_MODULE_IID)
AR_MODULE_PCMCNV(MOD_INDEX, SG_INDEX, CONTAINER_INDEX,	PCMCNV_MODULE_IID, 1, 1, 1, 2, PCM_DEINTERLEAVED_UNPACKED, VOLCTRL_MODULE_IID)
AR_MODULE_VOL_CTRL(MOD_INDEX, SG_INDEX, CONTAINER_INDEX, VOLCTRL_MODULE_IID, 1, 1, 1, 2, LOG_MODULE_IID)
AR_MODULE_LOG(MOD_INDEX,    SG_INDEX, CONTAINER_INDEX, 	LOG_MODULE_IID,    1, 1, 1, 2, 0x000019af, 1, 0, NONE_IID)
STREAM_PLAYBACK_MIXER(PCM_DAI_ID, SG_INDEX)
STREAM_PLAYBACK_ROUTE(MOD_INDEX)
