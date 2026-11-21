#!/usr/bin/env python3
"""Generate fixed-output Nix source locks from the staged Git tree and deps.json."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import subprocess
import sys

import deps

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "deps/nix-sources.json"
NIX = ["nix", "--extra-experimental-features", "nix-command flakes fetch-tree"]


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def sources():
    manifest = deps.validate(deps.load())
    result = {}
    for name, entry in manifest.items():
        if not entry.get("nix", True):
            continue
        if entry["type"] == "git":
            if "rev" not in entry:
                raise ValueError(f"{name}: run scripts/deps.py lock --missing")
            result[name] = {key: entry[key] for key in ("url", "rev")}
        else:
            result[name] = {key: entry[key] for key in ("url", "sha256")}
    modules = {}
    for entry in run("git", "config", "-z", "-f", ".gitmodules", "--get-regexp",
                     r"^submodule\..*\.path$").rstrip("\0").split("\0"):
        key, path = entry.split("\n", 1)
        modules[path] = key.removesuffix(".path") + ".url"
    for line in run("git", "ls-files", "--stage", "-z").rstrip("\0").split("\0"):
        record, path = line.split("\t", 1)
        mode, rev, stage = record.split()
        if mode != "160000":
            continue
        if stage != "0":
            raise ValueError(f"resolve unmerged gitlink {path}")
        if path not in modules:
            raise ValueError(f"{path}: missing .gitmodules entry")
        result[path] = {
            "url": run("git", "config", "-f", ".gitmodules", "--get", modules[path]),
            "rev": rev,
        }
    for spec in result.values():
        if "sha256" in spec:
            spec["fetcher"] = "archive"
            continue
        github = re.fullmatch(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?", spec["url"])
        if github:
            owner, repo = github.groups()
            spec["fetcher"] = "unpacked"
            spec["archive"] = f"https://codeload.github.com/{owner}/{repo}/tar.gz/{spec['rev']}"
        else:
            spec["fetcher"] = "git"
    return result


def version(name, tree):
    if name == "kernel-source":
        makefile = (tree / "Makefile").read_text()
        fields = [re.search(rf"^{key}\s*=([^\n]*)", makefile, re.M)[1].strip()
                  for key in ("VERSION", "PATCHLEVEL", "SUBLEVEL", "EXTRAVERSION")]
        return ".".join(fields[:3]) + fields[3]
    if name.startswith("libcamera/"):
        return re.search(r"\bversion\s*:\s*'([^']+)'", (tree / "meson.build").read_text())[1]
    return None


def prefetch(name, spec):
    kind = spec["fetcher"]
    if kind == "archive":
        # Flat checksum of the compressed bytes, already declared in deps.json.
        return spec | {"hash": "sha256-" + base64.b64encode(bytes.fromhex(spec["sha256"])).decode()}
    if kind == "unpacked":
        # Recursive hash of the unpacked tree with the top-level directory stripped.
        obj = json.loads(run(*NIX, "store", "prefetch-file", "--json", "--unpack", spec["archive"]))
        digest, tree = obj["hash"], obj["storePath"]
    else:
        # NAR hash of the exported Git tree. Evaluation uses the same fetcher.
        fetch = {"type": "git", "url": spec["url"], "rev": spec["rev"], "shallow": True}
        expr = f"let tree = builtins.fetchTree (builtins.fromJSON {json.dumps(json.dumps(fetch))}); in [ tree.narHash tree.outPath ]"
        digest, tree = json.loads(run(*NIX, "eval", "--impure", "--json", "--expr", expr))
    result = spec | {"hash": digest}
    v = version(name, Path(tree))
    if v:
        result["version"] = v
    print(f"{name}: {digest}", file=sys.stderr)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check input pins and lock format offline")
    parser.add_argument("--verify-hashes", action="store_true", help="recompute every hash and verify the lock")
    args = parser.parse_args()
    old = json.loads(LOCK.read_text()) if LOCK.exists() else {}
    inputs = sources()
    result = {}
    with ThreadPoolExecutor(max_workers=6) as pool:
        pending = {}
        for name, spec in inputs.items():
            entry = old.get(name, {})
            valid = (
                set(entry) == set(spec) | {"hash"} | (
                    {"version"} if name == "kernel-source" or name.startswith("libcamera/") else set()
                )
                and all(entry.get(key) == value for key, value in spec.items())
                and re.fullmatch(r"sha256-[A-Za-z0-9+/]{43}=", entry.get("hash", ""))
                and (not (name == "kernel-source" or name.startswith("libcamera/")) or entry.get("version"))
            )
            if valid and not args.verify_hashes:
                result[name] = entry
            elif args.check and not args.verify_hashes:
                raise ValueError(f"{name}: source lock missing or stale")
            else:
                pending[name] = pool.submit(prefetch, name, spec)
        result.update({name: future.result() for name, future in pending.items()})
    if args.check or args.verify_hashes:
        if old != result:
            raise ValueError("source lock differs from its inputs")
    else:
        temporary = LOCK.with_suffix(".tmp")
        temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        temporary.replace(LOCK)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"gen-nix-sources: {error}")
