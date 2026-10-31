# SPDX-License-Identifier: BSD-3-Clause
include(`util/util.m4') dnl
dnl MODULE_ID_SPLITTER is 0x07001011 in the vendor's ACDB graph description of
dnl the microphone capture device sub-graph (graph key 7, DeviceTX_Speaker_Mic:
dnl codec-DMA -> logger -> splitter, splitter with one input and 23 outputs).
define(`MODULE_ID_SPLITTER', `0x07001011') dnl
dnl AR_MODULE_SPLITTER(index, sgidx, container-idx, iid, maxip-ports, max-op-ports,
dnl                    src-port, dst-port, dst-iid)
define(`AR_MODULE_SPLITTER',
`'
`SectionVendorTuples."NAME_PREFIX.splitter$1_tuples" {'
`        tokens "audioreach_tokens"'
`'
`        tuples."word.u32_data" {'
`                AR_TKN_U32_MODULE_INSTANCE_ID STR($4)'
`                AR_TKN_U32_MODULE_ID STR(MODULE_ID_SPLITTER)'
`                AR_TKN_U32_MODULE_MAX_IP_PORTS STR($5)'
`                AR_TKN_U32_MODULE_MAX_OP_PORTS STR($6)'
`                AR_TKN_U32_MODULE_SRC_OP_PORT_ID STR($7)'
`                AR_TKN_U32_MODULE_DST_IN_PORT_ID STR($8)'
`                AR_TKN_U32_MODULE_SRC_INSTANCE_ID STR($4)'
`                AR_TKN_U32_MODULE_DST_INSTANCE_ID STR($9)'
`        }'
`}'
`'
`SectionData."NAME_PREFIX.splitter$1_data" {'
`        tuples "NAME_PREFIX.splitter$1_tuples"'
`}'
`'
`SectionWidget."NAME_PREFIX.splitter$1" {'
`        index STR($1)'
`        type "buffer"'
`        no_pm "true"'
`        subseq "10"'
`        data ['
`                "NAME_PREFIX.sub_graph$2_data"'
`                "NAME_PREFIX.container$3_data"'
`                "NAME_PREFIX.splitter$1_data"'
`        ]'
`}') dnl
