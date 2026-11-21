"""Compare Kconfig settings as symbols, ignoring compiler capability probes."""
import re
import sys

PROBES = re.compile(
    r"(?:CC_(?:VERSION_TEXT|IS_.*|HAS_.*|CAN_LINK|OPT_INLINE_MEMSET)"
    r"|(?:GCC|CLANG|AS|LD|LLD|PAHOLE|RUSTC|RUSTC_LLVM|RUSTC_LLVM_MAJOR)_VERSION"
    r"|(?:AS|LD)_IS_.*|(?:AS|LD|GCC|CLANG)_HAS_.*|LD_CAN_USE_KEEP_IN_OVERLAY"
    r"|RUSTC_(?:HAS|SUPPORTS)_.*|TOOLS_SUPPORT_RELR)"
)


def read_config(path):
    result = {}
    with open(path) as file:
        for line in file:
            enabled = re.fullmatch(r"CONFIG_(\w+)=(.*)\n", line)
            disabled = re.fullmatch(r"# CONFIG_(\w+) is not set\n", line)
            match = enabled or disabled
            if match and not PROBES.fullmatch(match[1]):
                result[match[1]] = enabled[2] if enabled else "n"
    return result


expected, actual = map(read_config, sys.argv[1:])
changes = []
for symbol in sorted(expected.keys() | actual.keys()):
    before, after = expected.get(symbol, "n"), actual.get(symbol, "n")
    if before != after:
        changes.append(f"CONFIG_{symbol}: {before} -> {after}")
if changes:
    sys.exit("Unexpected Kconfig changes:\n" + "\n".join(changes))
