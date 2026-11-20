#!/usr/bin/env python3
"""Resolve the build dependencies declared in deps/deps.json.

The manifest is the single place where an external tag, revision, archive
URL or checksum is recorded.  Build scripts ask this helper for a source directory
instead of carrying their own URL/version/commit constants.

Commands:
  list                 print the dependency names, one per line
  check [--locked]     validate the manifest (no network access)
  lock [--missing] [--from-cache] [NAME...] resolve tags and atomically write full revisions
  path NAME            fetch NAME if needed, then print its source directory
  fetch NAME           fetch NAME and print its source directory
  fetch-all            fetch every git/tarball dependency
  url NAME             print the upstream URL recorded for NAME
  rev NAME             print the revision recorded for NAME

Environment:
  DEPS_DIR             source directory (default: <repo>/.sources)
  DEPS_CACHE           download cache (default: <repo>/.cache/downloads)

Only the Python standard library is used.  Downloads with curl and extracts
with tar, so both honour the usual proxy environment variables.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "deps" / "deps.json"
SOURCES = Path(os.environ.get("DEPS_DIR", ROOT / ".sources")).resolve()
CACHE = Path(os.environ.get("DEPS_CACHE", ROOT / ".cache" / "downloads")).resolve()

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def die(message: str) -> "NoReturn":
    print(f"deps: {message}", file=sys.stderr)
    raise SystemExit(1)


def note(message: str) -> None:
    print(f"deps: {message}", file=sys.stderr)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, check=True, **kwargs)
    except FileNotFoundError:
        die(f"{cmd[0]} not found")
    except subprocess.CalledProcessError as exc:
        die(f"command failed ({exc.returncode}): {' '.join(cmd)}")


def load() -> dict:
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"manifest not found: {MANIFEST}")
    except json.JSONDecodeError as exc:
        die(f"{MANIFEST}: {exc}")
    if not isinstance(data, dict):
        die(f"{MANIFEST}: top level must be an object")
    return data


def require_string(name: str, meta: dict, key: str) -> str:
    value = meta.get(key)
    if not isinstance(value, str) or not value:
        die(f"{name}: '{key}' must be a non-empty string")
    return value


def validate(data: dict) -> dict:
    for name, meta in data.items():
        if not isinstance(meta, dict):
            die(f"{name}: entry must be an object")
        kind = meta.get("type")
        if kind == "git":
            require_string(name, meta, "url")
            if "rev" in meta:
                rev = require_string(name, meta, "rev")
                if not re.fullmatch(r"[0-9a-f]{40}", rev):
                    die(f"{name}: rev must be a full lowercase commit SHA")
            if "tag" in meta:
                require_string(name, meta, "tag")
            if not meta.get("rev") and not meta.get("tag"):
                die(f"{name}: git entry needs 'rev' or 'tag'")
        elif kind == "tarball":
            require_string(name, meta, "version")
            require_string(name, meta, "url")
            checksum = require_string(name, meta, "sha256")
            if not SHA256_RE.match(checksum):
                die(f"{name}: 'sha256' must be 64 lowercase hex characters")
        else:
            die(f"{name}: unknown type {kind!r} (expected git or tarball)")
    return data


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_head(destination: Path) -> str | None:
    if not (destination / ".git").exists():
        return None
    result = subprocess.run(
        ["git", "-C", str(destination), "rev-parse", "HEAD"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def git_pin(meta: dict) -> tuple[str, str]:
    """Return ("rev", sha) or ("tag", tag); rev wins when both are present."""
    if meta.get("rev"):
        return "rev", meta["rev"]
    return "tag", meta["tag"]


def prepare_git(destination: Path, url: str) -> None:
    if destination.exists() and not (destination / ".git").exists():
        die(f"{destination} exists but is not a git checkout; remove it")
    SOURCES.mkdir(parents=True, exist_ok=True)
    if not (destination / ".git").exists():
        run(["git", "init", "-q", str(destination)])
    remotes = subprocess.run(
        ["git", "-C", str(destination), "remote"],
        stdout=subprocess.PIPE,
        text=True,
        check=True,
    ).stdout.split()
    if "origin" in remotes:
        run(["git", "-C", str(destination), "remote", "set-url", "origin", url])
    else:
        run(["git", "-C", str(destination), "remote", "add", "origin", url])


def fetch_git(name: str, meta: dict) -> Path:
    url = meta["url"]
    kind, pin = git_pin(meta)
    destination = SOURCES / name
    stamp = SOURCES / ".stamps" / f"{name}.tag"
    cached_sha = None
    if kind == "tag" and stamp.is_file():
        fields = stamp.read_text(encoding="utf-8").strip().split("\t")
        if len(fields) == 2 and fields[0] == pin:
            cached_sha = fields[1].strip()
    expected = pin if kind == "rev" else cached_sha
    if expected and git_head(destination) == expected:
        # Source cache is read-only to consumers. Repair prior in-tree builds.
        run(["git", "-C", str(destination), "reset", "--hard", "-q", expected])
        run(["git", "-C", str(destination), "clean", "-xffdq"])
        return destination

    prepare_git(destination, url)
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    if kind == "rev":
        note(f"fetching {name} at {pin[:12]} from {url}")
        run(
            [
                "git",
                "-C",
                str(destination),
                "fetch",
                "--quiet",
                "--depth",
                "1",
                "origin",
                pin,
            ],
            env=env,
        )
        resolved = pin
    else:
        note(f"fetching {name} tag {pin} from {url}")
        run(
            [
                "git",
                "-C",
                str(destination),
                "fetch",
                "--quiet",
                "--depth",
                "1",
                "origin",
                f"refs/tags/{pin}",
            ],
            env=env,
        )
        # A tag can be lightweight or annotated; FETCH_HEAD^{commit} works for
        # both and gives the commit that is actually checked out.
        resolved = run(
            [
                "git",
                "-C",
                str(destination),
                "rev-parse",
                "--verify",
                "FETCH_HEAD^{commit}",
            ],
            env=env,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.strip()
        if not resolved:
            die(f"{name}: cannot resolve tag {pin}")
    run(["git", "-C", str(destination), "checkout", "--quiet", "-f", "--detach", resolved])
    # A new revision must not inherit build artifacts (BusyBox .config, an
    # autotools-generated configure, ...) from the previous checkout.
    run(["git", "-C", str(destination), "clean", "-xffdq"])
    head = git_head(destination)
    if head != resolved:
        die(f"{name}: checked out {head or 'nothing'}, expected {resolved}")
    if kind == "tag":
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(f"{pin}\t{resolved}\n", encoding="utf-8")
    return destination


def download(url: str, archive: Path, checksum: str) -> None:
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.is_file() and sha256_file(archive) == checksum:
        return
    note(f"downloading {url}")
    temporary = archive.with_suffix(archive.suffix + ".part")
    run(
        [
            "curl",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--retry",
            "3",
            "--happy-eyeballs-timeout-ms",
            "200",
            "--connect-timeout",
            "30",
            "--output",
            str(temporary),
            url,
        ]
    )
    actual = sha256_file(temporary)
    if actual != checksum:
        temporary.unlink(missing_ok=True)
        die(f"{archive.name}: SHA256 {actual}, expected {checksum}")
    temporary.replace(archive)


def fetch_tarball(name: str, meta: dict) -> Path:
    version = meta["version"]
    safe_version = re.sub(r"[^A-Za-z0-9._-]+", "_", version)
    destination = SOURCES / f"{name}-{safe_version}"
    stamp = SOURCES / ".stamps" / f"{name}-{safe_version}"
    if destination.is_dir() and stamp.is_file() and stamp.read_text().strip() == meta["sha256"]:
        return destination

    url = meta["url"]
    archive = CACHE / name / os.path.basename(url)
    download(url, archive, meta["sha256"])

    note(f"extracting {name} {version}")
    SOURCES.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{name}-", dir=SOURCES))
    try:
        run(["tar", "-xf", str(archive), "-C", str(temporary), "--strip-components=1"])
        if destination.exists():
            shutil.rmtree(destination)
        temporary.replace(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(meta["sha256"] + "\n", encoding="utf-8")
    return destination


def fetch(name: str, data: dict) -> Path:
    meta = data[name]
    kind = meta["type"]
    if kind == "git":
        return fetch_git(name, meta)
    if kind == "tarball":
        return fetch_tarball(name, meta)
    die(f"{name}: type {kind!r} has no downloadable source")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("list", help="list dependency names")
    check = subparsers.add_parser("check", help="validate the manifest")
    check.add_argument("--locked", action="store_true", help="require every Git dependency to have a full revision")
    lock = subparsers.add_parser("lock", help="resolve upstream tags to full commit SHAs; write only after all succeed")
    lock.add_argument("names", nargs="*", help="dependency names (default: all Git entries)")
    lock.add_argument("--missing", action="store_true", help="leave existing commit pins unchanged")
    lock.add_argument("--from-cache", action="store_true", help="pin already fetched tags without contacting upstream")
    subparsers.add_parser("fetch-all", help="fetch every git/tarball dependency")

    for command, help_text in (
        ("path", "fetch if needed and print the source directory"),
        ("fetch", "fetch the dependency"),
        ("url", "print the upstream URL"),
        ("rev", "print the pinned or tag-resolved commit"),
    ):
        child = subparsers.add_parser(command, help=help_text)
        child.add_argument("name")

    args = parser.parse_args()
    data = validate(load())

    if args.command == "list":
        for name in data:
            print(name)
        return 0
    if args.command == "lock":
        names = args.names or [n for n, m in data.items() if m["type"] == "git"]
        for name in names:
            if name not in data or data[name]["type"] != "git":
                die(f"{name}: not a Git dependency")
            meta = data[name]
            if (args.missing and meta.get("rev")) or not meta.get("tag"):
                continue
            ref = f"refs/tags/{meta['tag']}"
            if args.from_cache:
                stamp = SOURCES / ".stamps" / f"{name}.tag"
                fields = stamp.read_text().strip().split("\t") if stamp.is_file() else []
                if len(fields) != 2 or fields[0] != meta['tag'] or git_head(SOURCES/name) != fields[1]:
                    die(f"{name}: matching cached tag checkout not found; use online lock or omit this name")
                remote = run(["git", "-C", str(SOURCES/name), "remote", "get-url", "origin"],
                             stdout=subprocess.PIPE, text=True).stdout.strip()
                if remote != meta['url']:
                    die(f"{name}: cached checkout origin does not match manifest")
                sha = fields[1]
            else:
                result = run(["git", "ls-remote", "--exit-code", meta["url"], ref, ref + "^{}"],
                             stdout=subprocess.PIPE, text=True,
                             env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
                refs = {line.split()[1]: line.split()[0] for line in result.stdout.splitlines()}
                sha = refs.get(ref + "^{}", refs.get(ref, ""))
            if not re.fullmatch(r"[0-9a-f]{40}", sha):
                die(f"{name}: could not resolve {ref}")
            meta["rev"] = sha
            note(f"{name}: {meta['tag']} -> {sha}")
        validate(data)
        tmp = MANIFEST.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        tmp.replace(MANIFEST)
        return 0
    if args.command == "check":
        missing = [n for n, m in data.items() if m["type"] == "git" and not m.get("rev")]
        if missing:
            note("tag-only dependencies: " + ", ".join(missing))
            if args.locked:
                die("run deps.py lock --missing and commit the manifest")
        note(f"{len(data)} dependencies OK")
        return 0
    if args.command == "fetch-all":
        for name, meta in data.items():
            if meta["type"] in ("git", "tarball"):
                fetch(name, data)
        return 0

    name = args.name
    if name not in data:
        die(f"unknown dependency {name!r}; known: {', '.join(data)}")
    meta = data[name]

    if args.command in ("path", "fetch"):
        print(fetch(name, data))
        return 0
    if args.command == "url":
        print(meta["url"])
        return 0
    if args.command == "rev":
        if "rev" in meta:
            print(meta["rev"])
        elif "tag" in meta:
            path = fetch(name, data)
            head = git_head(path)
            if not head:
                die(f"{name}: cannot resolve tag {meta['tag']}")
            print(head)
        else:
            die(f"{name} has no revision (type {meta['type']})")
        return 0
    die(f"unknown command {args.command!r}")


if __name__ == "__main__":
    raise SystemExit(main())
