#!/bin/bash
# build.sh — build the SM8750 audio topology (qcom/sm8750/sm8750-tplg.bin).
#
# Chain:  Zhiyu-vendorprops.m4  --m4-->  sm8750-tplg.conf  --alsatplg-->  sm8750-tplg.bin
#
# The top-level .m4 is ours; it includes the vendor base tree
# (audioreach/*.m4, util/*.m4) from the pinned linux-msm/audioreach-topology
# source recorded in deps/deps.json.
#
# output: <repo>/out/sm8750-tplg.bin  (ALSA topology, magic "CoSA")
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$(realpath -m "${OUT:-$root/out/sm8750-tplg.bin}")
mkdir -p "$(dirname "$out")"
entry=${ENTRY:-Zhiyu-vendorprops.m4}
M4=${M4:-m4}
ALSATPLG=${ALSATPLG:-alsatplg}
vendor=${AUDIOREACH_SRC:-$(python3 "$root/scripts/deps.py" path audioreach)}

die() { echo "tplg/build.sh: $*" >&2; exit 1; }
command -v "$ALSATPLG" >/dev/null || die "alsatplg not found (alsa-utils)"

cd "$here"
work=$(mktemp -d "$(dirname "$out")/.tplg.XXXXXX")
conf=$work/topology.conf
trap 'rm -rf "$work"' EXIT
echo "== m4 $entry =="
"$M4" -I . -I "$vendor" "$entry" > "$conf"
echo "   conf: $(stat -c %s "$conf") bytes"
echo "== alsatplg =="
"$ALSATPLG" -c "$conf" -o "$work/topology.bin" 2>&1 | sed 's/^/   /'
[ -s "$work/topology.bin" ] || die "alsatplg produced no output"
head -c 4 "$work/topology.bin" | grep -q CoSA || die "output is not an ALSA topology"
mv -f "$work/topology.bin" "$out"
echo "== $out: $(stat -c %s "$out") bytes, md5 $(md5sum "$out" | cut -d' ' -f1) =="
