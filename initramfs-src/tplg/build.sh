#!/bin/bash
# build.sh — build the SM8750 audio topology (qcom/sm8750/sm8750-tplg.bin).
#
# Chain:  Zhiyu-vendorprops.m4  --m4-->  sm8750-tplg.conf  --alsatplg-->  sm8750-tplg.bin
#
# The top-level .m4 is ours; it includes the vendor base tree
# (audioreach/*.m4, util/*.m4) which is vendored under vendor-audioreach/
# (linux-msm/audioreach-topology, BSD-3-Clause, commit in VENDOR-COMMIT.txt).
#
# output: ./sm8750-tplg.bin  (ALSA topology, magic "CoSA")
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$here/sm8750-tplg.bin}
entry=${ENTRY:-Zhiyu-vendorprops.m4}
M4=${M4:-m4}
ALSATPLG=${ALSATPLG:-alsatplg}

die() { echo "tplg/build.sh: $*" >&2; exit 1; }
[ -d "$here/vendor-audioreach/audioreach" ] || die "vendor m4 base missing (vendor-audioreach/)"
command -v "$ALSATPLG" >/dev/null || die "alsatplg not found (alsa-utils)"

cd "$here"
conf=$(mktemp "$here/.tplg.XXXXXX.conf")
trap 'rm -f "$conf"' EXIT
echo "== m4 $entry =="
"$M4" -I . -I vendor-audioreach "$entry" > "$conf"
echo "   conf: $(stat -c %s "$conf") bytes"
echo "== alsatplg =="
"$ALSATPLG" -c "$conf" -o "$out" 2>&1 | sed 's/^/   /' || true
[ -s "$out" ] || die "alsatplg produced no output"
head -c 4 "$out" | grep -q CoSA || die "output is not an ALSA topology"
echo "== $out: $(stat -c %s "$out") bytes, md5 $(md5sum "$out" | cut -d' ' -f1) =="
