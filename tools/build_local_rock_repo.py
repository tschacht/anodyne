#!/usr/bin/env python3
"""Build and validate the verified, network-free LuaRocks repository."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile


DERIVED = {
    ("lua-term", "0.8-1"): "lua-term-0.08.tar.gz",
    ("mediator_lua", "1.1.2-0"): "mediator_lua-v1.1.2-0.tar.gz",
}


def load_manifest(path: Path) -> list[dict[str, str]]:
    records = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) != 6:
            raise SystemExit(f"invalid artifact manifest line {line_number}")
        records.append(dict(zip(("name", "version", "type", "filename", "url", "sha256"), fields)))
    return records


def verify(path: Path, expected: str) -> None:
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"SHA-256 mismatch: {path}")


def source_block(contents: str) -> str:
    match = re.search(r"\bsource\s*=\s*\{(?P<body>.*?)\n\}", contents, re.DOTALL)
    if not match:
        raise SystemExit("rockspec has no simple source block")
    return match.group("body")


def derive_rockspec(original: Path, source: Path, destination: Path) -> None:
    contents = original.read_text()
    block = source_block(contents)
    rewritten, replacements = re.subn(
        r"(?P<prefix>\burl\s*=\s*)(?P<quote>['\"])(?P<url>https://[^'\"]+)(?P=quote)",
        lambda match: match.group("prefix") + '"' + source.resolve().as_uri() + '"',
        block,
        count=1,
    )
    if replacements != 1:
        raise SystemExit(f"expected one HTTPS source URL in {original}")
    contents = contents.replace(block, rewritten, 1)
    if re.search(r"(?:https?|git(?:\+https)?):", source_block(contents)):
        raise SystemExit(f"derived rockspec retains a network source URL: {original}")
    destination.write_text(contents)


def embedded_rockspec(rock: Path) -> str:
    with zipfile.ZipFile(rock) as archive:
        names = [name for name in archive.namelist() if name.endswith(".rockspec")]
        if len(names) != 1:
            raise SystemExit(f"expected one embedded rockspec in {rock}")
        return archive.read(names[0]).decode()


def check_repo(records: list[dict[str, str]], inputs: Path, repository: Path) -> None:
    for record in records:
        verify(inputs / record["filename"], record["sha256"])
    expected = {f"{record['name']}-{record['version']}.src.rock" for record in records if record["type"] == "src.rock"}
    expected.update(f"{name}-{version}.src.rock" for name, version in DERIVED)
    actual = {path.name for path in repository.glob("*.src.rock")}
    if actual != expected:
        raise SystemExit(f"local rock set mismatch: expected {sorted(expected)}, found {sorted(actual)}")
    for record in records:
        if record["type"] == "src.rock":
            verify(repository / record["filename"], record["sha256"])
    for (name, version), _ in DERIVED.items():
        contents = embedded_rockspec(repository / f"{name}-{version}.src.rock")
        block = source_block(contents)
        if re.search(r"(?:https?|git(?:\+https)?):", block):
            raise SystemExit(f"derived {name} rock retains a network source URL")
        if "file://" not in block:
            raise SystemExit(f"derived {name} rock does not use a local source URL")
    for manifest_name in ("manifest", "manifest-5.4"):
        if not (repository / manifest_name).is_file():
            raise SystemExit(f"local LuaRocks repository {manifest_name} is missing")


def build(records: list[dict[str, str]], inputs: Path, repository: Path, luarocks: Path, admin: Path) -> None:
    for record in records:
        artifact = inputs / record["filename"]
        if not artifact.is_file():
            raise SystemExit(f"verified artifact is missing: {artifact}")
        verify(artifact, record["sha256"])

    repository.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".luarocks-repo-build-", dir=repository.parent) as temporary:
        staging = Path(temporary)
        for record in records:
            if record["type"] == "src.rock":
                shutil.copyfile(inputs / record["filename"], staging / record["filename"])

        derived_dir = staging / "derived-rockspecs"
        derived_dir.mkdir()
        by_key_type = {(record["name"], record["version"], record["type"]): record for record in records}
        for (name, version), source_filename in DERIVED.items():
            rockspec_record = by_key_type[(name, version, "rockspec")]
            source_record = by_key_type[(name, version, "source")]
            if source_record["filename"] != source_filename:
                raise SystemExit(f"unexpected verified source archive for {name}")
            derived = derived_dir / f"{name}-{version}.rockspec"
            derive_rockspec(inputs / rockspec_record["filename"], inputs / source_filename, derived)
            subprocess.run([str(luarocks), "pack", str(derived)], cwd=staging, check=True)

        subprocess.run([str(admin), "make_manifest", str(staging)], check=True)
        check_repo(records, inputs, staging)
        if repository.exists():
            shutil.rmtree(repository)
        os.rename(staging, repository)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("build", "check"))
    parser.add_argument("manifest", type=Path)
    parser.add_argument("inputs", type=Path)
    parser.add_argument("repository", type=Path)
    parser.add_argument("luarocks", nargs="?", type=Path)
    parser.add_argument("luarocks_admin", nargs="?", type=Path)
    args = parser.parse_args()
    records = load_manifest(args.manifest)
    if args.mode == "build":
        if not args.luarocks or not args.luarocks_admin:
            parser.error("build requires LuaRocks and LuaRocks-admin paths")
        build(records, args.inputs, args.repository, args.luarocks.resolve(), args.luarocks_admin.resolve())
    else:
        check_repo(records, args.inputs, args.repository)


if __name__ == "__main__":
    main()
