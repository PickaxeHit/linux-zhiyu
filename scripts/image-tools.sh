# Source this file to use manifest-managed AOSP tools unless explicitly overridden.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -z ${MKBOOTIMG:-} || -z ${UNPACK:-} ]]; then
    mkboot_src=$(python3 "$root/scripts/deps.py" path mkbootimg)
    export MKBOOTIMG=${MKBOOTIMG:-$mkboot_src/mkbootimg.py}
    export UNPACK=${UNPACK:-$mkboot_src/unpack_bootimg.py}
fi
if [[ -z ${AVBTOOL:-} ]]; then
    avb_src=$(python3 "$root/scripts/deps.py" path avb)
    export AVBTOOL=$avb_src/avbtool.py
fi
# Accept executable paths or names supplied by the caller. Source scripts
# without executable bits are invoked through an explicit Python wrapper.
for var in MKBOOTIMG UNPACK AVBTOOL; do
    tool=${!var}
    if [[ ! -x "$tool" && -f "$tool" && "$tool" == *.py ]]; then
        mkdir -p "$root/out/tools"
        wrapper=$root/out/tools/$var
        printf '#!/bin/bash\nexec python3 %q "$@"\n' "$tool" > "$wrapper"
        chmod +x "$wrapper"
        printf -v "$var" '%s' "$wrapper"
    elif [[ ! -x "$tool" ]]; then
        resolved=$(command -v "$tool") || { echo "Missing executable: $tool" >&2; return 1; }
        printf -v "$var" '%s' "$resolved"
    fi
    export "$var"
done
