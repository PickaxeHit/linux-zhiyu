#!/usr/bin/env python3
"""Stage a Nix runtime closure or publish a signed cache on GitHub Releases."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import urlopen

OFFICIAL = "https://cache.nixos.org"
INDEX_TAG = "nix-cache-index"
STORE_PATH = re.compile(r"/nix/store/([0-9a-z]{32})-[^/\s]+")
CACHE_ASSET = re.compile(r"nar/[0-9a-z]+\.nar(?:\.[a-z0-9]+)?")
IMAGES = re.compile(r"-zhiyu-(?:boot|vendor-boot|init-boot|vbmeta|images)$")


def run(*args, input=None, cwd=None):
    return subprocess.run(args, check=True, text=True, input=input, cwd=cwd,
                          stdout=subprocess.PIPE).stdout


def require(condition, message):
    if not condition:
        raise ValueError(message)


def store_hash(path):
    match = STORE_PATH.fullmatch(path)
    require(match, f"Invalid store path: {path}")
    return match[1]


def fields(contents):
    return dict(line.split(": ", 1) for line in contents.splitlines() if ": " in line)


def official_info(path, base):
    # An outage is different from a cache miss. Fail the staging job before
    # exporting a potentially large set of packages that are already public.
    for attempt in range(4):
        try:
            url = f"{base}/{store_hash(path)}.narinfo"
            with urlopen(url, timeout=20) as response:
                body = response.read(64 * 1024).decode()
            require(fields(body).get("StorePath") == path, f"Wrong store object from {url}")
            return body
        except HTTPError as error:
            if error.code == 404:
                return None
            if error.code not in (429, 500, 502, 503, 504) or attempt == 3:
                raise
        except (URLError, TimeoutError):
            if attempt == 3:
                raise
        time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def prepare(directory, official=OFFICIAL):
    roots = sorted(set(sys.stdin.read().split()))
    require(roots, "Pass cache root store paths on standard input")
    require(not directory.exists(), f"Cache directory already exists: {directory}")
    for path in roots:
        store_hash(path)
        require(not IMAGES.search(path), f"Boot images belong outside the Nix cache: {path}")
    closure = sorted(set(run("nix", "path-info", "--recursive", *roots).splitlines()))
    for path in closure:
        require(not IMAGES.search(path), f"Boot image escaped into the cache closure: {path}")

    with ThreadPoolExecutor(max_workers=16) as pool:
        checked = dict(zip(closure, pool.map(lambda p: official_info(p, official), closure), strict=True))
    missing = [p for p, info in checked.items() if info is None]
    directory.mkdir(parents=True)
    cache = directory.as_uri() + "?compression=xz"
    # Prime the local cache index with upstream metadata so nix copy can
    # validate references without writing their official NARs to the artifact.
    seeded = []
    for path, body in checked.items():
        if body is not None:
            index = directory / f"{store_hash(path)}.narinfo"
            index.write_text(body)
            seeded.append(index)
    try:
        if missing:
            run("nix", "copy", "--to", cache, "--stdin", input="\n".join(missing) + "\n")
    finally:
        for index in seeded:
            index.unlink()
    (directory / "nix-cache-info").write_text("StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 40\n")
    print(f"Cache payload contains {len(missing)} of {len(closure)} paths ({len(roots)} roots).")


def inspect(directory):
    entries = []
    for info in sorted(directory.glob("*.narinfo")):
        contents = info.read_text()
        meta = fields(contents)
        require(info.stem == store_hash(meta["StorePath"]), f"Invalid index filename: {info}")
        require(CACHE_ASSET.fullmatch(meta["URL"]), f"Invalid NAR URL in {info}")
        nar = directory / meta["URL"]
        require(nar.is_file() and nar.stat().st_size == int(meta["FileSize"]), f"Missing or truncated NAR: {nar}")
        entries.append((info, meta, nar))
    return entries


def gh_api_pages(endpoint):
    pages = json.loads(run("gh", "api", "--paginate", "--slurp", endpoint + "?per_page=100"))
    return [record for page in pages for record in page]


def file_digest(path):
    with path.open("rb") as file:
        return "sha256:" + hashlib.file_digest(file, "sha256").hexdigest()


def uploaded_assets(repository):
    releases = gh_api_pages(f"repos/{repository}/releases")
    assets = {}
    for release in releases:
        if release["draft"] or not release["tag_name"].startswith("nix-cache-"):
            continue
        for asset in gh_api_pages(f"repos/{repository}/releases/{release['id']}/assets"):
            if asset["state"] == "uploaded":
                assets.setdefault(asset["name"], []).append(asset)
    return assets


def matches(asset, nar, digest):
    if asset["size"] != nar.stat().st_size:
        return False
    if asset.get("digest"):
        return asset["digest"] == digest
    # Older releases may lack digests. Download and verify those assets
    # before reusing them. API/network errors deliberately stop publication.
    with urlopen(asset["browser_download_url"], timeout=60) as response:
        return "sha256:" + hashlib.file_digest(response, "sha256").hexdigest() == digest


def publish(directory, repository, tag, secret):
    entries = inspect(directory)
    if not entries:
        print("No non-upstream store paths to publish.")
        return
    with TemporaryDirectory(prefix="zhiyu-cache-sign-") as temp:
        key = Path(temp) / "key"
        fd = os.open(key, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w") as file:
            file.write(secret.rstrip() + "\n")
        key_name = secret.split(":", 1)[0]
        paths = "\n".join(meta["StorePath"] for _, meta, _ in entries)
        run("nix", "store", "sign", "--store", directory.as_uri(), "--key-file", str(key),
            "--stdin", input=paths + "\n")
    for info, _, _ in entries:
        require(any(line.startswith(f"Sig: {key_name}:") for line in info.read_text().splitlines()),
                f"Nix did not sign {info.name}")

    existing = uploaded_assets(repository)
    nar_urls = {}
    pending = []
    for nar in sorted({nar for _, _, nar in entries}):
        digest = file_digest(nar)
        match = next((item for item in existing.get(nar.name, []) if matches(item, nar, digest)), None)
        if match:
            nar_urls[nar.name] = match["browser_download_url"]
        else:
            pending.append((nar, digest))
    if pending:
        if not any(release["tag_name"] == tag for release in gh_api_pages(f"repos/{repository}/releases")):
            create_release(repository, tag, f"Zhiyu Nix binary cache objects ({tag})")
        for nar, _ in pending:
            run("gh", "release", "upload", tag, str(nar), "--repo", repository)
        release = json.loads(run("gh", "api", f"repos/{repository}/releases/tags/{quote(tag)}"))
        assets = {a["name"]: a for a in gh_api_pages(f"repos/{repository}/releases/{release['id']}/assets")}
        for nar, digest in pending:
            asset = assets.get(nar.name)
            require(asset and asset["state"] == "uploaded" and matches(asset, nar, digest),
                    f"Upload verification failed: {nar.name}")
            nar_urls[nar.name] = asset["browser_download_url"]

    publish_index(directory, repository, entries, nar_urls)


def publish_index(directory, repository, entries, nar_urls):
    releases = gh_api_pages(f"repos/{repository}/releases")
    release = next((item for item in releases if item["tag_name"] == INDEX_TAG), None)
    existing = {}
    if release:
        require(not release["draft"], "The Nix cache index Release must be public")
        assets = gh_api_pages(f"repos/{repository}/releases/{release['id']}/assets")
        existing = {a["name"]: a for a in assets if a["state"] == "uploaded"}

    with TemporaryDirectory(prefix="zhiyu-cache-index-") as temp:
        target = Path(temp)
        changed = []
        for info, meta, nar in entries:
            contents, count = re.subn(r"^URL: .*?$", "URL: " + nar_urls[nar.name],
                                      info.read_text(), flags=re.M)
            require(count == 1, f"Invalid URL in {info.name}")
            if info.name in existing:
                asset = existing[info.name]
                with urlopen(asset["browser_download_url"], timeout=60) as response:
                    previous = response.read(64 * 1024).decode()
                old = fields(previous)
                for field in ("StorePath", "NarHash", "NarSize", "References"):
                    require(old.get(field) == meta.get(field), f"Conflicting {field} for {info.name}")
                signatures = {line for line in contents.splitlines() if line.startswith("Sig: ")}
                for line in previous.splitlines():
                    if line.startswith("Sig: ") and line not in signatures:
                        contents += line + "\n"
                if previous == contents:
                    continue
            dest = target / info.name
            dest.write_text(contents)
            changed.append(dest)

        config = directory / "nix-cache-info"
        if config.name not in existing or not matches(existing[config.name], config, file_digest(config)):
            changed.append(config)
        if not release:
            create_release(repository, INDEX_TAG, "Zhiyu Nix binary cache index", *changed)
        elif changed:
            require(len(set(existing) | {p.name for p in changed}) <= 1000,
                    "The Nix cache index Release reached GitHub's 1000-asset limit")
            run("gh", "release", "upload", INDEX_TAG, *(str(p) for p in changed),
                "--clobber", "--repo", repository)
    print(f"Substituter: https://github.com/{repository}/releases/download/{INDEX_TAG}/")


def create_release(repository, tag, title, *files):
    repo = json.loads(run("gh", "api", f"repos/{repository}"))
    run("gh", "release", "create", tag, *(str(p) for p in files),
        "--repo", repository, "--target", repo["default_branch"],
        "--title", title, "--prerelease", "--latest=false",
        "--notes", "Lenovo TB378FC signed Nix binary cache. Use the nix-cache-index Release download URL as the substituter.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("prepare").add_argument("directory", type=Path)
    publication = commands.add_parser("publish")
    publication.add_argument("directory", type=Path)
    publication.add_argument("--repository", required=True)
    publication.add_argument("--tag", required=True)
    args = parser.parse_args()
    directory = args.directory.resolve()
    try:
        if args.operation == "prepare":
            prepare(directory)
        else:
            secret = os.environ.pop("NIX_CACHE_SIGNING_KEY", None)
            require(secret, "NIX_CACHE_SIGNING_KEY is required to publish a signed cache")
            require(re.fullmatch(r"nix-cache-[A-Za-z0-9.-]+", args.tag), "Invalid cache release tag")
            publish(directory, args.repository, args.tag, secret)
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"nix-cache: {error}")


if __name__ == "__main__":
    main()
