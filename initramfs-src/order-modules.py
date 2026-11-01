#!/usr/bin/env python3
"""Turn depmod's modules.dep into the order the initramfs should load in.

The init script used to insmod the tree in guessed order and retry until the
dependencies happened to be satisfied, which cost a dmesg full of
"Unknown symbol ..." lines on every boot.  depmod already knows the real
dependency graph, so the order is computed here, at build time, and stored as
`load-order` next to the modules:

    <phase> <TAB> <path relative to the module directory>

The phases exist because some modules have to be loaded at a specific moment,
not because of their dependencies:

    1  everything the WCN7860 needs: its MHI boot must finish before the rest
       of the system takes over PCIe (runtime PM / ASPM)
    2  the ADSP remoteproc/glink stack
    3  PMIC glink and the battery manager (needs the glink up first)
    4  the rest of the top level
    5  the audio modules, which must wait for the ADSP to be running

Dependencies are always emitted before the module that needs them, and a
dependency is pulled into the phase of the module that asked for it, so a phase
can be loaded on its own.
"""

import sys
import os

# Modules that have to be loaded early; names are matched with '-' and '_'
# treated as the same character.
PHASES = {
    1: """rfkill cfg80211 mac80211 qrtr qrtr-mhi mhi-pci-generic
          ath12k ath12k-wifi7 pwrseq-qcom-wcn phy-qcom-qmp-pcie""",
    2: """qcom_q6v5 qcom_sysmon qcom_pil_info qcom_common qcom_glink_smem
          mdt_loader qcom_q6v5_pas""",
    3: """qmi_helpers qcom_pdr_msg pdr_interface pmic_glink qcom_battmgr""",
}

AUDIO_PHASE = 5
REST_PHASE = 4


def norm(name):
    return name.replace("-", "_")


def read_dep(moddir):
    path = os.path.join(moddir, "modules.dep")
    deps = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or ":" not in line:
                continue
            mod, _, rest = line.partition(":")
            deps[mod] = rest.split()
    return deps


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: order-modules.py <lib/modules/VER>")
    moddir = sys.argv[1]
    deps = read_dep(moddir)

    by_name = {}
    for mod in deps:
        by_name.setdefault(norm(os.path.basename(mod)[:-3]), mod)

    # module path -> phase
    phase = {}
    order = []          # (phase, path) in emission order
    emitted = set()

    def emit(mod, ph, seen):
        if mod in emitted or mod in seen:
            return
        seen = seen | {mod}
        for dep in deps.get(mod, []):
            emit(dep, ph, seen)
        emitted.add(mod)
        phase[mod] = ph
        order.append((ph, mod))

    for ph in sorted(PHASES):
        for want in PHASES[ph].split():
            mod = by_name.get(norm(want))
            if mod is None:
                print("order-modules: no module named %s" % want,
                      file=sys.stderr)
                continue
            emit(mod, ph, frozenset())

    for mod in sorted(deps):
        if mod in emitted:
            continue
        ph = AUDIO_PHASE if mod.startswith("audio/") else REST_PHASE
        emit(mod, ph, frozenset())

    # A phase-4 module that depends on an audio module drags it into phase 4,
    # i.e. before the ADSP is up.  Nothing should need that: flag it, because
    # it usually means a module is filed in the wrong place.
    early_audio = [m for m in emitted
                   if m.startswith("audio/") and phase[m] != AUDIO_PHASE]
    for mod in early_audio:
        print("order-modules: warning: %s is pulled in before the ADSP "
              "because a non-audio module depends on it" % mod,
              file=sys.stderr)

    for ph, mod in order:
        print("%d\t%s" % (ph, mod))


if __name__ == "__main__":
    main()
